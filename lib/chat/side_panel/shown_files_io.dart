import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';

/// How long one not shown again is kept: a paste may hold a key, and
/// nothing else ever removes them.
const shownKeptFor = Duration(days: 7);

/// [bytes] as `<data>/cache/shown/<their hash>/<name>`: written once, the
/// same again kept as it was (and kept for another [shownKeptFor]).
String? writeShown(List<int> bytes, String name) {
  final root = p.join(DataDirectory.current.cacheDir, 'shown');
  _pruned ??= pruneShown(root);
  final hash = sha256.convert(bytes).toString().substring(0, 16);
  final file = File(p.join(root, hash, name));
  try {
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes, flush: true);
    } else {
      file.setLastModifiedSync(DateTime.now());
    }
    return file.path;
  } on FileSystemException {
    return null;
  }
}

/// The first write's [pruneShown], once a run.
Future<void>? _pruned;

/// Removes from [root] the files shown last longer than [shownKeptFor] ago
/// (before [now]), and the folders left empty.
@visibleForTesting
Future<void> pruneShown(String root, {DateTime? now}) async {
  final before = (now ?? DateTime.now()).subtract(shownKeptFor);
  try {
    final folder = Directory(root);
    if (!await folder.exists()) return;
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! Directory) continue;
      var left = false;
      await for (final file in entry.list(followLinks: false)) {
        try {
          if (file is File && (await file.lastModified()).isBefore(before)) {
            await file.delete();
          } else {
            left = true;
          }
        } on FileSystemException {
          left = true;
        }
      }
      if (!left) {
        try {
          await entry.delete();
        } on FileSystemException {
          // Written into meanwhile.
        }
      }
    }
  } on FileSystemException {
    // Unreadable: kept, tried again next run.
  }
}
