import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'line_counts.dart';
import 'review_store.dart';

/// [ReviewStore] in folders of this machine, a session's
/// `checkpoints/<project>/<session>/`: its `review.json` and its blobs
/// (compressed, by hash).
/// Only what the agents edited is kept, never the rest of the project;
/// the project's `.git` (if it has one) is never read or written.
class LocalReviewStore implements ReviewStore {
  LocalReviewStore._(this.root, this.folder);

  /// The store for [root], its folder under [checkpoints]; null when
  /// [root] is not a folder. [checkpoints] is tidied from then on
  /// ([scheduleTidy]).
  static Future<LocalReviewStore?> open(
    String root, {
    required String checkpoints,
  }) async {
    root = p.normalize(p.absolute(root));
    checkpoints = p.normalize(p.absolute(checkpoints));
    if (!await Directory(root).exists()) return null;
    final folder = p.join(checkpoints, _folderName(root));
    try {
      await _dropRepository(folder);
    } on FileSystemException {
      // Tidied later.
    }
    scheduleTidy(checkpoints);
    return LocalReviewStore._(root, folder);
  }

  @override
  final String root;

  /// The project's folder: `checkpoints/<folder name>-<hash of its path>`.
  final String folder;

  /// Past this size a file is not kept: its edits are listed, not undone.
  static int maxFileBytes = 10 * 1024 * 1024;

  /// `<name>-<FNV-1a of the path>`: readable, and one per path.
  static String _folderName(String root) {
    // The offset basis in halves: one 64-bit literal is not a JS number, and
    // the web build must compile.
    var hash = 0xcbf29ce4 << 32 | 0x84222325;
    for (final byte in utf8.encode(root)) {
      hash ^= byte;
      hash *= 0x100000001b3;
    }
    // Ints are signed: the two halves, unsigned.
    String half(int bits) => bits.toRadixString(16).padLeft(8, '0');
    final name = p.basename(root).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '${name.isEmpty ? 'root' : name}-'
        '${half(hash >>> 32)}${half(hash & 0xFFFFFFFF)}';
  }

  /// A project's folder of an earlier build was a Git repository of
  /// snapshots of the whole project: it goes, out of the way at once and
  /// deleted after.
  static Future<void> _dropRepository(String folder) async {
    if (!await File(p.join(folder, 'HEAD')).exists()) return;
    final gone = '$folder.old-$pid-${DateTime.now().microsecondsSinceEpoch}';
    await Directory(folder).rename(gone);
    unawaited(
      Directory(gone).delete(recursive: true).then((_) {}, onError: (_) {}),
    );
  }

  // --- Sessions' folders --------------------------------------------------

  static final _safeName = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*$');

  String _sessionFolder(String session) {
    if (!_safeName.hasMatch(session) || session.startsWith('.')) {
      session = 'h${_folderName(session).split('-').last}';
    }
    final path = p.join(folder, session);
    _live.add(path);
    return path;
  }

  String _blobPath(String session, String oid) =>
      p.join(_sessionFolder(session), 'blobs', oid);

  /// The sessions' folders used in this process: never tidied away from
  /// under them.
  static final Set<String> _live = {};

  // --- Files ----------------------------------------------------------------

  String _full(String path) => p.join(root, path);

  @override
  Future<bool> exists(String path) async =>
      FileSystemEntity.typeSync(_full(path), followLinks: false) !=
      FileSystemEntityType.notFound;

  /// What is at [path]: its mode and bytes; null for nothing or a folder,
  /// or a file too large.
  Future<(String, Uint8List)?> _contentOf(String path) async {
    final full = _full(path);
    switch (FileSystemEntity.typeSync(full, followLinks: false)) {
      case FileSystemEntityType.notFound || FileSystemEntityType.directory:
        return null;
      case FileSystemEntityType.link:
        return ('120000', utf8.encode(await Link(full).target()));
      default:
        final file = File(full);
        final stat = await file.stat();
        if (stat.size > maxFileBytes) return null;
        final executable = !Platform.isWindows && stat.mode & 0x49 != 0;
        return (executable ? '100755' : '100644', await file.readAsBytes());
    }
  }

  static String _hash(Uint8List bytes) => sha1.convert(bytes).toString();

  @override
  Future<ReviewBlob?> current(String path) async {
    final content = await _contentOf(path);
    if (content == null) return null;
    return ReviewBlob(content.$1, _hash(content.$2));
  }

  @override
  Future<ReviewBlob?> take(String session, String path) async {
    final content = await _contentOf(path);
    if (content == null) return null;
    return store(session, content.$2, mode: content.$1);
  }

  @override
  Future<ReviewBlob> store(
    String session,
    Uint8List bytes, {
    required String mode,
  }) async {
    final blob = ReviewBlob(mode, _hash(bytes));
    final file = File(_blobPath(session, blob.oid));
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      // Whole or not at all.
      final partial = File('${file.path}.$pid.part');
      await partial.writeAsBytes(zlib.encode(bytes), flush: true);
      await partial.rename(file.path);
    }
    return blob;
  }

  @override
  Future<Uint8List> read(String session, ReviewBlob blob) async {
    final file = File(_blobPath(session, blob.oid));
    try {
      return Uint8List.fromList(zlib.decode(await file.readAsBytes()));
    } on FileSystemException {
      throw ReviewUnavailable('What the session kept of a file is gone.');
    }
  }

  @override
  Future<void> restore(String session, String path, ReviewBlob? blob) async {
    final full = _full(path);
    final type = FileSystemEntity.typeSync(full, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      throw ReviewUnavailable('$path is a folder now.');
    }
    if (blob == null) {
      if (type != FileSystemEntityType.notFound) await File(full).delete();
      await _removeEmpty(p.dirname(full));
      return;
    }
    final bytes = await read(session, blob);
    if (type == FileSystemEntityType.link ||
        (blob.isLink && type != FileSystemEntityType.notFound)) {
      await File(full).delete();
    }
    await Directory(p.dirname(full)).create(recursive: true);
    if (blob.isLink) {
      await Link(full).create(utf8.decode(bytes, allowMalformed: true));
      return;
    }
    await File(full).writeAsBytes(bytes, flush: true);
    if (blob.mode == '100755' && !Platform.isWindows) {
      await Process.run('chmod', ['+x', full]);
    }
  }

  /// Deletes [directory] and those above it while empty, up to the root.
  Future<void> _removeEmpty(String directory) async {
    while (p.isWithin(root, directory)) {
      final folder = Directory(directory);
      try {
        if (!await folder.exists() || !await folder.list().isEmpty) return;
        await folder.delete();
      } on FileSystemException {
        return;
      }
      directory = p.dirname(directory);
    }
  }

  @override
  Future<Uint8List?> merge(
    String session,
    String path,
    ReviewBlob from,
    ReviewBlob to,
  ) async {
    final temp = await Directory.systemTemp.createTemp('caocode-review-');
    try {
      final ours = p.join(temp.path, 'current');
      final base = p.join(temp.path, 'base');
      final theirs = p.join(temp.path, 'other');
      await File(_full(path)).copy(ours);
      await File(base).writeAsBytes(await read(session, from));
      await File(theirs).writeAsBytes(await read(session, to));
      final merged = await Process.run('git', [
        'merge-file',
        '-p',
        '-q',
        ours,
        base,
        theirs,
      ], stdoutEncoding: null);
      // The number of conflicts, or an error (a binary file).
      return merged.exitCode == 0
          ? Uint8List.fromList(merged.stdout as List<int>)
          : null;
    } on ProcessException {
      // No Git.
      return null;
    } finally {
      await temp.delete(recursive: true);
    }
  }

  @override
  Future<void> write(String path, Uint8List bytes) =>
      File(_full(path)).writeAsBytes(bytes, flush: true);

  @override
  Future<Map<String, ({int added, int removed})?>> lineCounts(
    String session,
    Map<String, ReviewBlob?> bases,
  ) async => {
    for (final MapEntry(key: path, value: base) in bases.entries)
      path: countLines(
        base == null ? null : await read(session, base),
        (await _contentOf(path))?.$2,
      ),
  };

  // --- Sessions ---------------------------------------------------------------

  static const _dataFile = 'review.json';

  @override
  Future<String?> load(String session) async {
    final file = File(p.join(_sessionFolder(session), _dataFile));
    try {
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> save(
    String session,
    String data, {
    required Iterable<ReviewBlob> blobs,
  }) async {
    final folder = Directory(_sessionFolder(session));
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, _dataFile));
    final partial = File('${file.path}.$pid.part');
    await partial.writeAsString(data, flush: true);
    await partial.rename(file.path);
    // What it no longer needs (a change kept, a part of one).
    final kept = {for (final blob in blobs) blob.oid};
    final stored = Directory(p.join(folder.path, 'blobs'));
    if (!await stored.exists()) return;
    await for (final entry in stored.list(followLinks: false)) {
      final name = p.basename(entry.path);
      if (entry is File && !name.endsWith('.part') && !kept.contains(name)) {
        try {
          await entry.delete();
        } on FileSystemException {
          // Next time.
        }
      }
    }
  }

  @override
  Future<void> forget(String session) async {
    final folder = Directory(_sessionFolder(session));
    try {
      if (await folder.exists()) await folder.delete(recursive: true);
    } on FileSystemException {
      // Tidied later.
    }
    try {
      // The project's, with no session left.
      await Directory(this.folder).delete();
    } on FileSystemException {
      // Others there.
    }
  }

  // --- Tidying ---------------------------------------------------------------

  /// How long a session's edits are kept after it last saved them: past
  /// it, they can no longer be reviewed or undone.
  static Duration keepFor = const Duration(days: 30);

  /// Where [tidy] notes when it last ran, in the checkpoints folder.
  static const _tidiedFile = '.tidied';

  /// Clears out [checkpoints] (the folder [open] keeps the projects' in),
  /// at most once a [every]: the sessions not saved for [keepFor] go, and
  /// a project's folder with none left; the repositories of an earlier
  /// build go at once. Never throws; what it cannot read or delete is
  /// left.
  static Future<void> tidy(
    String checkpoints, {
    Duration every = const Duration(days: 1),
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();
    checkpoints = p.normalize(p.absolute(checkpoints));
    try {
      final folder = Directory(checkpoints);
      if (!await folder.exists()) return;
      final tidied = File(p.join(checkpoints, _tidiedFile));
      if (await tidied.exists() &&
          at.difference(await tidied.lastModified()) < every) {
        return;
      }
      await tidied.writeAsString('${at.toIso8601String()}\n');
      final cutoff = at.subtract(keepFor);
      await for (final project in folder.list(followLinks: false)) {
        if (project is! Directory) continue;
        try {
          await _tidyProject(project, cutoff);
        } on FileSystemException {
          // Next time.
        }
      }
    } on Object {
      // Tried again next time.
    }
  }

  static Future<void> _tidyProject(Directory project, DateTime cutoff) async {
    if (p.basename(project.path).contains('.old-')) {
      // One of an earlier build, out of the way.
      await project.delete(recursive: true);
      return;
    }
    if (await File(p.join(project.path, 'HEAD')).exists()) {
      await project.delete(recursive: true);
      return;
    }
    await for (final session in project.list(followLinks: false)) {
      if (session is! Directory || _live.contains(session.path)) continue;
      final data = File(p.join(session.path, _dataFile));
      final saved = await data.exists()
          ? await data.lastModified()
          : (await session.stat()).modified;
      if (saved.isBefore(cutoff)) await session.delete(recursive: true);
    }
    if (await project.list().isEmpty) await project.delete();
  }

  static final Map<String, Timer> _tidying = {};

  /// Has [tidy] run on [checkpoints] a minute from now, then every few
  /// hours (it does its work once a day), for as long as the process runs.
  static void scheduleTidy(String checkpoints) {
    checkpoints = p.normalize(p.absolute(checkpoints));
    if (_tidying.containsKey(checkpoints)) return;
    _tidying[checkpoints] = Timer(const Duration(minutes: 1), () {
      unawaited(tidy(checkpoints));
      _tidying[checkpoints] = Timer.periodic(
        const Duration(hours: 6),
        (_) => unawaited(tidy(checkpoints)),
      );
    });
  }
}
