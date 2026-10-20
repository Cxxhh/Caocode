import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'turn_stats.dart';

/// The turns' records in [directory], one file per session
/// (`<session id>.jsonl`), a line per turn.
///
/// Only ever appended to, never read back and written over, and each line
/// under the file's lock: sessions ending turns at once cannot lose one
/// another's lines. Dart's append mode alone does not do: it seeks to the
/// end and writes there, and two writers at once write over each other.
/// The lock keeps another app out; within this one, every session writes
/// from the one isolate, a line at a time, in one go.
class TurnStatsFiles implements TurnStats {
  TurnStatsFiles(this.directory);

  final String directory;

  /// A session's file; null for an id that is no file name (Claude Code's
  /// are uuids).
  File? _fileOf(String sessionId) =>
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionId)
      ? File(p.join(directory, '$sessionId.jsonl'))
      : null;

  @override
  void write(String sessionId, String turnId, TurnRecord record) {
    final file = _fileOf(sessionId);
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      final open = file.openSync(mode: FileMode.append);
      try {
        open.lockSync(FileLock.blockingExclusive);
        // The end as it is now, another's line written meanwhile.
        open
          ..setPositionSync(open.lengthSync())
          ..writeStringSync('${TurnStats.encode(turnId, record)}\n')
          ..flushSync();
      } finally {
        // Unlocks it too.
        open.closeSync();
      }
    } on FileSystemException catch (error) {
      debugPrint('Turn not kept: $error');
    }
  }

  @override
  Future<Map<String, TurnRecord>> read(String sessionId) async {
    final file = _fileOf(sessionId);
    if (file == null) return const {};
    try {
      return TurnStats.decode(await file.readAsLines());
    } on FileSystemException {
      return const {};
    } on FormatException {
      // Not UTF-8: not ours.
      return const {};
    }
  }
}

/// The records kept in [directory].
TurnStats? turnStatsIn(String directory) => TurnStatsFiles(directory);
