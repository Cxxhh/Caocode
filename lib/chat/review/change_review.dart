import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../remote/remote_location.dart';
import '../chat_models.dart';
import 'review_store.dart';
import 'unpatch.dart';

/// A file the agent changed: what it was before (kept, the file as it is
/// becomes that), what the agent left, and what is there now.
class _Entry {
  _Entry(this.base);

  ReviewBlob? base;
  ReviewBlob? after;
  ReviewBlob? current;
  bool conflict = false;

  /// Whether it differs from what was there before.
  bool get pending => switch ((base, current)) {
    (null, null) => false,
    (final base?, final current) => !base.sameContent(current),
    _ => true,
  };

  Map<String, Object?> toJson() => {
    'base': base?.toJson(),
    'after': after?.toJson(),
    'current': current?.toJson(),
    'conflict': conflict,
  };

  static _Entry fromJson(Map<String, Object?> json) =>
      _Entry(ReviewBlob.fromJson(json['base']))
        ..after = ReviewBlob.fromJson(json['after'])
        ..current = ReviewBlob.fromJson(json['current'])
        ..conflict = json['conflict'] == true;
}

/// What an agent changed in its project, held against what was there
/// before, for the user to keep or undo file by file: the review behind
/// Keep and Undo.
///
/// Only the edits the agent reports are in it, with what each file was
/// before as the agent tells ([FileOriginal]): what a command changes is
/// not. Each conversation keeps its own ([ReviewStore], a folder of its
/// session), and nothing of the rest of the project. Whatever changes a
/// file since the agent left it (the user, between turns) is carried over
/// by Undo (a three-way merge) rather than written over: where it cannot,
/// the file is left as it is and marked.
///
/// Kept, a change is only no longer listed: nothing is written, staged or
/// committed. Undone, the file is put back. Once none is pending, what
/// the session kept is gone.
class ChangeReview extends ChangeNotifier {
  /// Its files' paths spelled as [paths] has them: this machine's way
  /// when null.
  ChangeReview(this._store, {p.Context? paths}) : _paths = paths ?? p.context;

  /// The review of the project at [root], continuing what [session] left;
  /// null where there can be none (see [openReviewStore]).
  static Future<ChangeReview?> open(String root, {String? session}) async {
    final store = await openReviewStore(root);
    if (store == null) return null;
    // A remote project's paths are its host's (POSIX), whatever this
    // machine spells its own with.
    final paths = RemoteLocation.pathsOf(root);
    if (session == null) return ChangeReview(store, paths: paths);
    return resume(store, session, paths: paths);
  }

  /// The review over [store], with the changes [session] left pending.
  static Future<ChangeReview> resume(
    ReviewStore store,
    String session, {
    p.Context? paths,
  }) async {
    final review = ChangeReview(store, paths: paths);
    await review._load(session);
    return review;
  }

  final ReviewStore _store;
  final p.Context _paths;

  /// How its files' paths are spelled.
  p.Context get paths => _paths;

  String get root => _store.root;

  /// By path relative to [root].
  final Map<String, _Entry> _entries = {};

  /// Edits it cannot undo (what the file was is not known, or it is
  /// outside the project), by absolute path: listed, to be kept.
  final Map<String, FileChange> _unseen = {};

  List<FileChange> _changes = const [];

  /// The pending changes, one per file, with absolute paths.
  List<FileChange> get changes => _changes;

  /// Why it stopped: the store failed. Its changes are then no longer
  /// known.
  String? get failure => _failure;
  String? _failure;

  /// The session it is kept under, once known. Anew, what the one before
  /// kept moves to it.
  String? get session => _session;
  String? _session;
  set session(String? id) {
    if (id == null || id == _session) return;
    final before = _session;
    _session = id;
    unawaited(
      _enqueue(() async {
        // Nothing yet: nothing to keep.
        if (_entries.isEmpty && _unseen.isEmpty) return;
        if (before != null) await _move(before, id);
        await _persist();
      }),
    );
  }

  // --- Looking ----------------------------------------------------------------

  Future<void> _queue = Future.value();
  bool _disposed = false;

  /// Runs [operation] after those before it; a failure stops the review.
  Future<void> _enqueue(Future<void> Function() operation) =>
      _queue = _queue.then((_) async {
        if (_disposed || _failure != null) return;
        try {
          await operation();
        } on Object catch (error) {
          abandon('$error');
        }
      });

  /// Stops it for [reason]: its changes are no longer known.
  void abandon(String reason) {
    if (_failure != null) return;
    _failure = reason;
    _changes = const [];
    if (!_disposed) notifyListeners();
  }

  /// Looks at its files again (before a turn, as one ends): one put back
  /// as it was since is no longer pending.
  Future<void> refresh() => _enqueue(() => _look(_entries.keys.toList()));

  /// The agent edited [change]'s file, which was [original] before.
  /// Without [original], or outside the project, the edit is listed, to
  /// be kept and not undone.
  void report(FileChange change, {FileOriginal? original}) {
    final path = _relative(change.path);
    if (path == null) {
      // Outside the project.
      _unsee(change);
      unawaited(_enqueue(_refresh));
      return;
    }
    unawaited(_enqueue(() => _take(path, change, original)));
  }

  void _unsee(FileChange change) {
    final absolute = _absolute(change.path);
    _unseen[absolute] = _merged(_unseen[absolute], change, absolute);
  }

  static FileChange _merged(
    FileChange? before,
    FileChange change,
    String path,
  ) => FileChange(
    path: path,
    added: (before?.added ?? 0) + change.added,
    removed: (before?.removed ?? 0) + change.removed,
    tracked: false,
  );

  Future<void> _take(
    String path,
    FileChange change,
    FileOriginal? original,
  ) async {
    final session = _session;
    final absolute = _absolute(path);
    if (session == null || _unseen.containsKey(absolute)) {
      _unsee(change);
      return _refresh();
    }
    final after = await _store.take(session, path);
    var entry = _entries[path];
    if (entry == null) {
      final (known, base) = await _baseOf(session, path, original, after);
      if (!known) {
        _unsee(change);
        return _refresh();
      }
      entry = _entries[path] = _Entry(base);
    }
    entry
      ..after = after
      ..current = after
      ..conflict = false;
    _entries.removeWhere((_, entry) => !entry.pending);
    await _refresh();
    await _persist();
  }

  /// What [path] was before the agent's edit: whether it is known, and
  /// its blob (null where there was no file).
  Future<(bool, ReviewBlob?)> _baseOf(
    String session,
    String path,
    FileOriginal? original,
    ReviewBlob? after,
  ) async {
    final mode = switch (after?.mode) {
      final mode? when mode != '120000' => mode,
      _ => '100644',
    };
    switch (original) {
      case OriginalText(text: null):
        return (true, null);
      case OriginalText(:final text?):
        return (
          true,
          await _store.store(session, utf8.encode(text), mode: mode),
        );
      case OriginalByPatch(:final diff) when after != null && !after.isLink:
        final now = utf8.decode(
          await _store.read(session, after),
          allowMalformed: true,
        );
        final text = unpatch(now, diff);
        if (text == null) return (false, null);
        return (
          true,
          await _store.store(session, utf8.encode(text), mode: mode),
        );
      case _:
        return (false, null);
    }
  }

  /// [paths] (relative) as they are now: not the agent's.
  Future<void> _look(List<String> paths) async {
    for (final path in paths) {
      final entry = _entries[path];
      if (entry == null) continue;
      final now = await _store.current(path);
      if (now != entry.current) {
        entry
          ..current = now
          ..conflict = false;
      }
    }
    // Those it cannot undo that are gone since (a script the agent wrote
    // and deleted): nothing is left of them to keep.
    for (final path in [..._unseen.keys]) {
      if (!await _store.exists(path)) _unseen.remove(path);
    }
    _entries.removeWhere((_, entry) => !entry.pending);
    await _refresh();
    await _persist();
  }

  /// [changes] anew, with their line counts.
  Future<void> _refresh() async {
    final session = _session;
    Map<String, ({int added, int removed})?> counts = const {};
    if (session != null && _entries.isNotEmpty) {
      try {
        counts = await _store.lineCounts(session, {
          for (final MapEntry(key: path, value: entry) in _entries.entries)
            path: entry.base,
        });
      } on Object {
        // Listed without their counts.
      }
    }
    final paths = _entries.keys.toList()..sort();
    _changes = [
      for (final path in paths)
        if (_entries[path] case final entry?)
          FileChange(
            path: _absolute(path),
            added: counts[path]?.added ?? 0,
            removed: counts[path]?.removed ?? 0,
            binary: counts.containsKey(path) && counts[path] == null,
            kind: entry.base == null
                ? FileChangeKind.added
                : entry.current == null
                ? FileChangeKind.deleted
                : FileChangeKind.modified,
            conflict: entry.conflict,
          ),
      ..._unseen.values,
    ];
    if (!_disposed) notifyListeners();
  }

  // --- Keep and Undo -----------------------------------------------------------

  /// Keeps the changes to [paths] (absolute): they are no longer listed.
  Future<void> keep(Iterable<String> paths) {
    final kept = paths.toList();
    return _enqueue(() async {
      for (final path in kept) {
        _unseen.remove(path);
        _entries.remove(_relative(path));
      }
      await _refresh();
      await _persist();
    });
  }

  Future<void> keepAll() => _enqueue(() async {
    _unseen.clear();
    _entries.clear();
    await _refresh();
    await _persist();
  });

  /// Puts the files at [paths] (absolute) back as they were before the
  /// agent changed them, keeping what changed since where it can (else the
  /// file stays, marked [FileChange.conflict]).
  Future<void> undo(Iterable<String> paths) {
    final wanted = paths.toList();
    return _enqueue(() async {
      final session = _session;
      if (session == null) return;
      final undone = <String>[];
      for (final absolute in wanted) {
        final path = _relative(absolute);
        final entry = path == null ? null : _entries[path];
        if (path == null || entry == null) continue;
        try {
          if (await _undo(session, path, entry)) {
            undone.add(path);
          } else {
            entry.conflict = true;
          }
        } on Object {
          entry.conflict = true;
        }
      }
      for (final path in undone) {
        _entries.remove(path);
      }
      await _refresh();
      await _persist();
    });
  }

  Future<void> undoAll() =>
      undo([for (final path in _entries.keys) _absolute(path)]);

  /// Whether [path] is back as it was.
  Future<bool> _undo(String session, String path, _Entry entry) async {
    final now = await _store.current(path);
    final base = entry.base;
    final after = entry.after;
    // Already back.
    if (base == null ? now == null : base.sameContent(now)) return true;
    // As the agent left it: put back what was.
    if (now == null ? after == null : now.sameContent(after)) {
      await _store.restore(session, path, base);
      return true;
    }
    // Changed since: the agent's change taken out of it.
    if (now != null && after != null && base != null && !now.isLink) {
      final merged = await _store.merge(session, path, after, base);
      if (merged == null) return false;
      await _store.write(path, merged);
      return true;
    }
    return false;
  }

  // --- Part of a file -----------------------------------------------------------

  /// Which text [path] (absolute) is held against: the blob of what was
  /// there before the agent changed it ('' for a file it created), anew as
  /// part of the change is kept; null when it has no change pending that
  /// can be undone.
  String? baseOf(String path) {
    final relative = _relative(path);
    final entry = relative == null ? null : _entries[relative];
    if (entry == null) return null;
    return entry.base?.oid ?? '';
  }

  /// Keeps part of the change to [path] (absolute): [base], what was there
  /// before with that part of the change in it, is what the rest is held
  /// against. Nothing is written. Fails (the review goes on) where the
  /// store cannot keep it.
  Future<void> keepPart(String path, String base) {
    final relative = _relative(path);
    final completer = Completer<void>();
    unawaited(
      _enqueue(() async {
        final session = _session;
        final entry = relative == null ? null : _entries[relative];
        if (entry == null || session == null) return completer.complete();
        try {
          final mode = entry.base?.mode ?? entry.current?.mode ?? '100644';
          entry.base = await _store.store(
            session,
            utf8.encode(base),
            mode: mode,
          );
        } on Object catch (error, stack) {
          return completer.completeError(error, stack);
        }
        entry.conflict = false;
        // The file as it is now (saved since the last look, it may be what
        // is kept): the change goes when nothing of it is left.
        await _look([relative!]);
        completer.complete();
      }).whenComplete(() {
        if (!completer.isCompleted) completer.complete();
      }),
    );
    return completer.future;
  }

  /// Looks at [paths] (absolute) again after they were written outside the
  /// agent's turn (part of a change undone in the editor): not the agent's.
  Future<void> settle(Iterable<String> paths) {
    final relative = [for (final path in paths) ?_relative(path)];
    return _enqueue(() => _look(relative));
  }

  /// The text of [path] (absolute) before the agent changed it: empty for
  /// a file it created; null when it is not known.
  Future<String> Function()? original(String path) {
    final relative = _relative(path);
    if (relative == null || !_entries.containsKey(relative)) return null;
    return () async {
      final base = _entries[relative]?.base;
      final session = _session;
      if (base == null || session == null) return '';
      return utf8.decode(
        await _store.read(session, base),
        allowMalformed: true,
      );
    };
  }

  // --- Keeping it between runs ----------------------------------------------

  Iterable<ReviewBlob> get _blobs => [
    for (final entry in _entries.values) ...[?entry.base, ?entry.after],
  ];

  Future<void> _persist() async {
    final session = _session;
    if (session == null) return;
    if (_entries.isEmpty && _unseen.isEmpty) {
      await _store.forget(session);
      return;
    }
    await _store.save(
      session,
      jsonEncode({
        'version': 2,
        'entries': {
          for (final MapEntry(key: path, value: entry) in _entries.entries)
            path: entry.toJson(),
        },
        'unseen': [
          for (final change in _unseen.values)
            {
              'path': change.path,
              'added': change.added,
              'removed': change.removed,
            },
        ],
      }),
      blobs: _blobs,
    );
  }

  /// What [from] kept, kept for [to] instead.
  Future<void> _move(String from, String to) async {
    for (final blob in {..._blobs}) {
      await _store.store(to, await _store.read(from, blob), mode: blob.mode);
    }
    await _store.forget(from);
  }

  Future<void> _load(String session) async {
    _session = session;
    try {
      final data = await _store.load(session);
      if (data == null) return;
      final json = jsonDecode(data);
      // One of an earlier build (snapshots of the whole project) is not
      // read: what it listed is begun anew.
      if (json is! Map<String, Object?> || json['version'] != 2) return;
      if (json['entries'] case final Map<String, Object?> entries) {
        for (final MapEntry(key: path, value: entry) in entries.entries) {
          if (entry is Map<String, Object?>) {
            _entries[path] = _Entry.fromJson(entry);
          }
        }
      }
      if (json['unseen'] case final List<Object?> unseen) {
        for (final change in unseen) {
          if (change case {
            'path': final String path,
            'added': final int added,
            'removed': final int removed,
          }) {
            _unseen[path] = FileChange(
              path: path,
              added: added,
              removed: removed,
              tracked: false,
            );
          }
        }
      }
      await _refresh();
    } on Object {
      // Begun anew.
      _entries.clear();
      _unseen.clear();
    }
  }

  // --- Paths ------------------------------------------------------------------

  /// [path] (absolute, or relative to [root]) relative to [root], with
  /// `/`; null outside it.
  String? _relative(String path) {
    final absolute = _absolute(path);
    if (!_paths.isWithin(root, absolute)) return null;
    return _paths.split(_paths.relative(absolute, from: root)).join('/');
  }

  String _absolute(String path) => _paths.normalize(
    _paths.isAbsolute(path) ? path : _paths.joinAll([root, ...path.split('/')]),
  );

  /// Drops what it kept between runs, once what is under way is done: the
  /// conversation is gone.
  Future<void> discard() {
    final session = _session;
    _session = null;
    if (session == null) return Future.value();
    return _queue = _queue.then(
      (_) => _store.forget(session).catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
