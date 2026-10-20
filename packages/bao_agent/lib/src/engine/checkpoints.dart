import 'dart:io';

import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'package:path/path.dart' as p;

import '../util/json.dart';
import 'session.dart';

/// What files were before each prompt's turn changed them, so that the
/// user can have them back (`rewind_files`): a copy of each file taken
/// before its first change in a turn, kept where Claude Code keeps its own
/// (`file-history/<session>`), and noted in the session's file.
class FileCheckpoints {
  FileCheckpoints(this.session);

  final AgentSession session;

  final List<_Snapshot> _snapshots = [];
  final Map<String, int> _versions = {};

  String get _dir => session.paths.fileHistoryDir(session.sessionId);

  /// Reads back the snapshots kept in the session's file.
  void load(Iterable<Map<String, Object?>> lines) {
    for (final line in lines) {
      if (line['type'] != 'file-history-snapshot') continue;
      final snapshot = asMap(line['snapshot']);
      final id = asString(line['messageId']) ?? asString(snapshot['messageId']);
      if (id == null) continue;
      final files = <String, String?>{};
      for (final MapEntry(key: path, value: raw) in asMap(
        snapshot['trackedFileBackups'],
      ).entries) {
        final backup = asMap(raw);
        files[path] = asString(backup['backupFileName']);
        final version = asInt(backup['version']) ?? 0;
        if (version > (_versions[path] ?? 0)) _versions[path] = version;
      }
      final existing = _snapshots.where((s) => s.messageId == id).firstOrNull;
      if (existing != null) {
        existing.files.addAll(files);
      } else {
        _snapshots.add(_Snapshot(id)..files.addAll(files));
      }
    }
  }

  /// A prompt's turn begins: what it changes is kept under [messageId].
  void begin(String messageId) {
    if (_snapshots.isNotEmpty && _snapshots.last.messageId == messageId) return;
    _snapshots.add(_Snapshot(messageId));
  }

  /// Keeps [path] as it is now, if this turn has not kept it yet: done
  /// before each change.
  Future<void> track(String path) async {
    if (_snapshots.isEmpty) return;
    final snapshot = _snapshots.last;
    if (snapshot.files.containsKey(path)) return;
    final file = File(path);
    String? backup;
    if (file.existsSync()) {
      final version = (_versions[path] ?? 0) + 1;
      _versions[path] = version;
      backup = '${_hash(path)}@v$version';
      final target = File(p.join(_dir, backup));
      target.parent.createSync(recursive: true);
      file.copySync(target.path);
    }
    snapshot.files[path] = backup;
    session.store.note({
      'type': 'file-history-snapshot',
      'messageId': snapshot.messageId,
      'snapshot': {
        'messageId': snapshot.messageId,
        'trackedFileBackups': {
          for (final MapEntry(key: tracked, value: name)
              in snapshot.files.entries)
            tracked: {
              'backupFileName': name,
              'version': _versions[tracked] ?? 0,
              'backupTime': DateTime.now().toUtc().toIso8601String(),
            },
        },
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      },
      'isSnapshotUpdate': snapshot.files.length > 1,
    });
  }

  static String _hash(String path) =>
      sha256.convert(utf8.encode(path)).toString().substring(0, 16);

  /// The files changed since [messageId]'s turn began, as they were then.
  Map<String, String?> _before(String messageId) {
    final at = _snapshots.indexWhere((s) => s.messageId == messageId);
    if (at < 0) return const {};
    final before = <String, String?>{};
    for (final snapshot in _snapshots.skip(at)) {
      for (final MapEntry(:key, :value) in snapshot.files.entries) {
        before.putIfAbsent(key, () => value);
      }
    }
    return before;
  }

  bool has(String messageId) => _snapshots.any((s) => s.messageId == messageId);

  /// Puts the files changed since [messageId]'s turn began back as they
  /// were then; returns those it changed. Null when there is no such turn.
  List<String>? rewind(String messageId, {bool dryRun = false}) {
    if (!has(messageId)) return null;
    final changed = <String>[];
    for (final MapEntry(key: path, value: backup) in _before(
      messageId,
    ).entries) {
      final file = File(path);
      if (backup == null) {
        if (file.existsSync()) {
          changed.add(path);
          if (!dryRun) file.deleteSync();
        }
        continue;
      }
      final saved = File(p.join(_dir, backup));
      if (!saved.existsSync()) continue;
      final now = file.existsSync() ? file.readAsBytesSync() : null;
      final then = saved.readAsBytesSync();
      if (now != null && _same(now, then)) continue;
      changed.add(path);
      if (!dryRun) {
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(then, flush: true);
      }
    }
    if (!dryRun) {
      // What the agent read of them is not what is there now.
      for (final path in changed) {
        session.forgetRead(path);
      }
    }
    return changed;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _Snapshot {
  _Snapshot(this.messageId);

  final String messageId;

  /// Each file changed, and the copy of it before (null: it was not
  /// there).
  final Map<String, String?> files = {};
}
