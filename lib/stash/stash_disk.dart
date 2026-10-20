import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'stash_disk_stub.dart'
    if (dart.library.io) 'stash_disk_io.dart'
    as platform;

/// What a file put into a stash came to: copied into its folder (by the
/// path its text gives it, relative to the stash folder), or, too big to
/// copy, only linked to where it is.
typedef StashFileAdded = ({String path, bool copied, int size});

/// Where stashes are kept: `<root>/<id>.md`, each one's pictures and files
/// in `<root>/<id>/`, and `<root>/.stash.json` (the next number, and where
/// a merged stash's number now leads).
abstract interface class StashDisk {
  /// `~/Caocode/Stash`, or [root] (none on the web).
  factory StashDisk.files([String? root]) = platform.FileStashDisk;

  /// The folder itself (absolute).
  String get root;

  /// The numbers of the stashes there, with when each was last written.
  Future<Map<int, DateTime>> list();

  Future<String?> read(int id);
  Future<void> write(int id, String text);

  /// The stash file and its folder.
  Future<void> delete(int id);

  /// `.stash.json`; empty when there is none.
  Future<Map<String, Object?>> readMeta();
  Future<void> writeMeta(Map<String, Object?> meta);

  /// Runs [body] while no other app writes the folder's numbers (a lock
  /// file, given up if it was left behind).
  Future<T> locked<T>(Future<T> Function() body);

  /// Writes [bytes] in [id]'s folder as [name] (another name if taken);
  /// the path the stash's text gives it.
  Future<String> writeAsset(int id, String name, Uint8List bytes);

  /// Copies the file at [source] (absolute) into [id]'s folder; the path
  /// the stash's text gives it.
  Future<String> copyAsset(int id, String source);

  /// The file's size, or null when there is none at [path].
  Future<int?> sizeOf(String path);

  /// [from]'s pictures and files into [to]'s folder: the paths they had
  /// (as the text gives them) and those they have now.
  Future<Map<String, String>> moveAssets(int from, int to);

  /// The bytes of what the text gives as [path].
  Future<Uint8List?> readAsset(String path);

  /// Something in the folder changed (another app wrote a stash).
  Stream<void> get changes;
}

/// [path] as the text gives it resolved against the stash folder [root].
String stashAbsolute(String root, String path) =>
    p.isAbsolute(path) ? path : p.normalize(p.join(root, path));

/// A free name for [name] among [taken]: `shot.png`, `shot-2.png`…
String freeAssetName(String name, bool Function(String name) taken) {
  if (!taken(name)) return name;
  final base = p.basenameWithoutExtension(name);
  final extension = p.extension(name);
  for (var i = 2; ; i++) {
    final candidate = '$base-$i$extension';
    if (!taken(candidate)) return candidate;
  }
}

/// Kept only while it lives, e.g. under test.
class MemoryStashDisk implements StashDisk {
  MemoryStashDisk({this.root = '/stash'});

  @override
  final String root;

  final Map<int, String> files = {};
  final Map<int, DateTime> modified = {};
  final Map<String, Uint8List> assets = {};
  final Map<String, int> sizes = {};
  Map<String, Object?> meta = {};
  final StreamController<void> _changes = StreamController.broadcast();

  /// Tells [changes] something changed, as another app's write would.
  void touch() => _changes.add(null);

  @override
  Future<Map<int, DateTime>> list() async => {
    for (final id in files.keys) id: modified[id] ?? DateTime(2026),
  };

  @override
  Future<String?> read(int id) async => files[id];

  @override
  Future<void> write(int id, String text) async {
    files[id] = text;
    modified[id] = DateTime.now();
  }

  @override
  Future<void> delete(int id) async {
    files.remove(id);
    modified.remove(id);
    assets.removeWhere((path, _) => path.startsWith('$id/'));
  }

  @override
  Future<Map<String, Object?>> readMeta() async =>
      jsonDecode(jsonEncode(meta)) as Map<String, Object?>;

  @override
  Future<void> writeMeta(Map<String, Object?> meta) async =>
      this.meta = jsonDecode(jsonEncode(meta)) as Map<String, Object?>;

  Future<void> _lock = Future.value();

  @override
  Future<T> locked<T>(Future<T> Function() body) {
    final result = _lock.then((_) => body());
    _lock = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  Future<String> writeAsset(int id, String name, Uint8List bytes) async {
    final free = freeAssetName(name, (n) => assets.containsKey('$id/$n'));
    assets['$id/$free'] = bytes;
    return '$id/$free';
  }

  @override
  Future<String> copyAsset(int id, String source) async {
    final free = freeAssetName(
      p.basename(source),
      (n) => assets.containsKey('$id/$n'),
    );
    assets['$id/$free'] = assets[source] ?? Uint8List(sizes[source] ?? 0);
    return '$id/$free';
  }

  @override
  Future<int?> sizeOf(String path) async => sizes[path] ?? assets[path]?.length;

  @override
  Future<Map<String, String>> moveAssets(int from, int to) async {
    final moved = <String, String>{};
    for (final path in [...assets.keys.where((k) => k.startsWith('$from/'))]) {
      final name = path.substring('$from/'.length);
      final free = freeAssetName(name, (n) => assets.containsKey('$to/$n'));
      assets['$to/$free'] = assets.remove(path)!;
      moved[path] = '$to/$free';
    }
    return moved;
  }

  @override
  Future<Uint8List?> readAsset(String path) async => assets[path];

  @override
  Stream<void> get changes => _changes.stream;
}
