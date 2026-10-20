import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../platform/app_paths.dart';
import 'stash_disk.dart';

/// The stash folder on this machine: `~/Caocode/Stash` by default.
class FileStashDisk implements StashDisk {
  FileStashDisk([String? root, @visibleForTesting this._watchFolder = _watchOf])
    : root = root ?? defaultRoot;

  static Stream<FileSystemEvent> _watchOf(Directory folder) => folder.watch();

  /// How the folder is watched: the system's, or a test's events.
  final Stream<FileSystemEvent> Function(Directory folder) _watchFolder;

  static String get defaultRoot =>
      p.join(AppPaths.home(Platform.environment), 'Caocode', 'Stash');

  @override
  final String root;

  static final _name = RegExp(r'^(\d+)\.md$');

  Future<Directory> _folder() => Directory(root).create(recursive: true);

  File _file(int id) => File(p.join(root, '$id.md'));

  Directory _assets(int id) => Directory(p.join(root, '$id'));

  @override
  Future<Map<int, DateTime>> list() async {
    final folder = await _folder();
    final found = <int, DateTime>{};
    await for (final entity in folder.list(followLinks: false)) {
      if (entity is! File) continue;
      final match = _name.firstMatch(p.basename(entity.path));
      if (match == null) continue;
      try {
        found[int.parse(match[1]!)] = await entity.lastModified();
      } on FileSystemException {
        // Gone meanwhile.
      }
    }
    return found;
  }

  @override
  Future<String?> read(int id) async {
    try {
      return await _file(id).readAsString();
    } on FileSystemException {
      return null;
    }
  }

  /// Each stash's write under way: the next waits for it, so the one asked
  /// for last is the one left (a typed save and an AI rewrite at once).
  final Map<int, Future<void>> _writing = {};

  /// Counts the temporary files written, for their names.
  int _written = 0;

  @override
  Future<void> write(int id, String text) {
    final previous = _writing[id] ?? Future<void>.value();
    final next = previous
        .catchError((Object _) {})
        .then((_) => _write(id, text));
    _writing[id] = next;
    return next.whenComplete(() {
      if (identical(_writing[id], next)) _writing.remove(id);
    });
  }

  Future<void> _write(int id, String text) async {
    await _folder();
    // Written whole, then moved in place: never half a file. A name of its
    // own, so another window (its own isolate, its own disk) writing the
    // same stash meanwhile does not write into it.
    final file = _file(id);
    final temporary = File(
      '${file.path}.$pid-${_written++}-'
      '${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(text, flush: true);
      _ownWrites.add(p.basename(file.path));
      await temporary.rename(file.path);
    } on Object {
      try {
        await temporary.delete();
      } on FileSystemException {
        // Moved in place, or never made.
      }
      rethrow;
    }
  }

  @override
  Future<void> delete(int id) async {
    try {
      await _file(id).delete();
    } on FileSystemException {
      // Already gone.
    }
    final assets = _assets(id);
    if (await assets.exists()) await assets.delete(recursive: true);
  }

  File get _metaFile => File(p.join(root, '.stash.json'));

  @override
  Future<Map<String, Object?>> readMeta() async {
    try {
      final json = jsonDecode(await _metaFile.readAsString());
      return json is Map<String, Object?> ? json : {};
    } on Object {
      return {};
    }
  }

  @override
  Future<void> writeMeta(Map<String, Object?> meta) async {
    await _folder();
    final temporary = File('${_metaFile.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(meta),
      flush: true,
    );
    await temporary.rename(_metaFile.path);
  }

  /// A lock older than this was left by an app that went.
  static const _staleLock = Duration(seconds: 10);

  Future<void> _inProcess = Future.value();

  @override
  Future<T> locked<T>(Future<T> Function() body) {
    final result = _inProcess.then((_) => _lockFile(body));
    _inProcess = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<T> _lockFile<T>(Future<T> Function() body) async {
    await _folder();
    final lock = File(p.join(root, '.stash.lock'));
    final deadline = DateTime.now().add(_staleLock);
    while (true) {
      try {
        await lock.create(exclusive: true);
        break;
      } on FileSystemException {
        DateTime? since;
        try {
          since = await lock.lastModified();
        } on FileSystemException {
          continue;
        }
        if (DateTime.now().difference(since) > _staleLock ||
            DateTime.now().isAfter(deadline)) {
          try {
            await lock.delete();
          } on FileSystemException {
            // Another took it first.
          }
          continue;
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
    try {
      return await body();
    } finally {
      try {
        await lock.delete();
      } on FileSystemException {
        // Already gone.
      }
    }
  }

  Future<Directory> _assetFolder(int id) => _assets(id).create(recursive: true);

  @override
  Future<String> writeAsset(int id, String name, Uint8List bytes) async {
    final folder = await _assetFolder(id);
    final free = freeAssetName(
      _safe(name),
      (n) => File(p.join(folder.path, n)).existsSync(),
    );
    await File(p.join(folder.path, free)).writeAsBytes(bytes, flush: true);
    return '$id/$free';
  }

  @override
  Future<String> copyAsset(int id, String source) async {
    final folder = await _assetFolder(id);
    final free = freeAssetName(
      _safe(p.basename(source)),
      (n) =>
          FileSystemEntity.typeSync(p.join(folder.path, n)) !=
          FileSystemEntityType.notFound,
    );
    await File(source).copy(p.join(folder.path, free));
    return '$id/$free';
  }

  /// A file name that needs no quoting in markdown: no spaces or brackets.
  static String _safe(String name) {
    final cleaned = name.replaceAll(RegExp(r'[\s()<>\[\]"#?%]+'), '-');
    return cleaned.isEmpty ? 'file' : cleaned;
  }

  @override
  Future<int?> sizeOf(String path) async {
    try {
      final stat = await File(stashAbsolute(root, path)).stat();
      return stat.type == FileSystemEntityType.notFound ? null : stat.size;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<Map<String, String>> moveAssets(int from, int to) async {
    final source = _assets(from);
    final moved = <String, String>{};
    if (!await source.exists()) return moved;
    final target = await _assetFolder(to);
    await for (final entity in source.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final free = freeAssetName(
        name,
        (n) =>
            FileSystemEntity.typeSync(p.join(target.path, n)) !=
            FileSystemEntityType.notFound,
      );
      await entity.rename(p.join(target.path, free));
      moved['$from/$name'] = '$to/$free';
    }
    await source.delete(recursive: true);
    return moved;
  }

  @override
  Future<Uint8List?> readAsset(String path) async {
    try {
      return await File(stashAbsolute(root, path)).readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// The files this app wrote itself, not told of as another's changes.
  final Set<String> _ownWrites = {};

  StreamController<void>? _changes;
  StreamSubscription<FileSystemEvent>? _watch;

  @override
  Stream<void> get changes {
    final controller = _changes ??= StreamController<void>.broadcast(
      onListen: _startWatching,
      onCancel: () {
        unawaited(_watch?.cancel());
        _watch = null;
      },
    );
    return controller.stream;
  }

  Timer? _settle;

  Future<void> _startWatching() async {
    final folder = await _folder();
    try {
      _watch = _watchFolder(folder).listen((event) {
        // A file written whole and moved in place (this app's writes, an
        // agent's) is, on Windows and Linux, one move: from the temporary
        // file to the stash's.
        var changed = false;
        for (final path in [
          event.path,
          if (event case FileSystemMoveEvent(:final destination?)) destination,
        ]) {
          final name = p.basename(path);
          if (_name.hasMatch(name) && !_ownWrites.remove(name)) changed = true;
        }
        if (!changed) return;
        // A burst of events (an editor's save) as one.
        _settle?.cancel();
        _settle = Timer(const Duration(milliseconds: 300), () {
          _changes?.add(null);
        });
      }, onError: (Object _) {});
    } on FileSystemException {
      // Not watchable: changes show when the app reads it again.
    }
  }
}
