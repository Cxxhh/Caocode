import 'dart:async';
import 'dart:typed_data';

import 'package:bao_remote/client.dart';
import 'package:bao_remote/search.dart';
import 'package:path/path.dart' as p;

import '../kernel/codex/codex_host.dart';
import 'file_service.dart';

typedef WslFileOperation = Future<T> Function<T>(
  Future<T> Function(RemoteClient client) operation,
);

/// Keep Windows UNC paths at the UI boundary, and perform every operation
/// inside Linux. In particular, Windows LockFile is unsupported by WSL's
/// UNC provider, while the native server can safely lock and save files.
class WslIdeFileService implements IdeMountedFiles, IdeRangeFiles {
  WslIdeFileService(String root, this.run) : project = wslProject(root)!;

  final WslProject project;
  final WslFileOperation run;

  String native(String path) {
    final target = wslProject(path);
    if (target != null) {
      if (target.distribution.toLowerCase() !=
          project.distribution.toLowerCase()) {
        throw ArgumentError('文件不属于 WSL · ${project.distribution}：$path');
      }
      return p.posix.normalize(target.path);
    }
    if (path.startsWith('/') && !path.startsWith('//')) {
      return p.posix.normalize(path);
    }
    if (p.windows.isAbsolute(path)) throw ArgumentError('不是 WSL 文件路径：$path');
    return p.posix.normalize(
      p.posix.join(project.path, path.replaceAll('\\', '/')),
    );
  }

  String clientPath(String path) =>
      p.windows.normalize(wslWindowsPath('${project.prefix}$path'));

  @override
  Future<List<IdeFile>> list(String directory) => run(
    (client) async => [
      for (final file in await client.list(project.path, native(directory)))
        IdeFile(
          p.windows.join(clientPath(native(directory)), file.name),
          file.name,
          isDirectory: file.isDirectory,
        ),
    ],
  );

  @override
  Future<String> read(String path, {bool force = false}) =>
      run((client) => client.read(project.path, native(path), force: force));

  @override
  Future<void> write(String path, String text, {String? expectedText}) => run(
    (client) => client.write(
      project.path,
      native(path),
      text,
      expectedText: expectedText,
    ),
  );

  @override
  Future<void> create(String path, {bool directory = false}) => run(
    (client) => client.create(project.path, native(path), directory: directory),
  );

  @override
  Future<void> rename(String from, String to) =>
      run((client) => client.rename(project.path, native(from), native(to)));

  @override
  Future<void> copy(String from, String to) =>
      run((client) => client.copy(project.path, native(from), native(to)));

  @override
  Future<void> delete(String path) =>
      run((client) => client.delete(project.path, native(path)));

  @override
  Future<void> writeBytes(String path, Uint8List bytes) =>
      run((client) => client.writeBytes(project.path, native(path), bytes));

  @override
  Future<Uint8List> readBytes(String path) =>
      run((client) => client.readBytes(native(path)));

  @override
  Future<({Uint8List bytes, int size})> readRange(
    String path,
    int offset,
    int length, {
    Future<void>? cancel,
  }) => run(
    (client) => client.readRange(native(path), offset, length, cancel: cancel),
  );

  @override
  Future<int> sizeOf(List<String> paths, {int? limit}) =>
      run((client) => client.sizeOf(paths.map(native).toList(), limit: limit));

  @override
  Future<IdeFileListing> listProject(String root, {int limit = 50000}) =>
      run((client) async {
        final listing = await client.walk(native(root), limit: limit);
        return IdeFileListing(
          listing.paths.map(clientPath).toList(),
          truncated: listing.truncated,
        );
      });

  @override
  Stream<void> watchDirectory(String directory) async* {
    while (true) {
      try {
        final client = await run((client) async => client);
        yield* client.watchDirectory(native(directory));
        return;
      } on RpcClosed {
        // Re-read after a disconnected watcher; retry only the watcher,
        // never an edit that may already have reached disk.
        yield null;
        await Future<void>.delayed(const Duration(seconds: 1));
      } on Object {
        // The directory listing reports startup/permission failures in
        // the tree. A background watcher must not raise an unhandled error.
        return;
      }
    }
  }

  @override
  Stream<Object> searchText(String root, IdeTextQuery query) async* {
    final client = await run((client) async => client);
    yield* client
        .searchText(native(root), query)
        .map(
          (event) => switch (event) {
            IdeFileMatches(:final path, :final matches) => IdeFileMatches(
              clientPath(path),
              matches,
            ),
            _ => event,
          },
        );
  }
}
