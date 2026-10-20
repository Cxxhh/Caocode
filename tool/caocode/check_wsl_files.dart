// Run with Windows Dart from the build copy:
// dart run tool/caocode/check_wsl_files.dart <distribution> <Linux project path>
// Uses a new scratch directory, removed afterwards; existing files are read only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/client.dart';
import 'package:bao_remote/search.dart';
import 'package:path/path.dart' as p;

import 'package:caocode/kernel/codex/codex_host.dart';
import 'package:caocode/remote/remote_location.dart';

class _Binaries implements RemoteServerBinaries {
  _Binaries(this.directory);
  final String directory;
  @override
  String get version =>
      File(p.join(directory, 'VERSION')).readAsStringSync().trim();
  @override
  Future<List<int>?> read(String platform) =>
      File(p.join(directory, 'caocode-server-$platform')).readAsBytes();
}

Future<void> main(List<String> arguments) async {
  if (!Platform.isWindows ||
      (arguments.length < 2 || arguments.length > 3) ||
      !arguments[1].startsWith('/')) {
    throw ArgumentError(
      '在 Windows 构建目录运行：dart run tool/caocode/check_wsl_files.dart <发行版> <Linux 项目绝对路径>',
    );
  }
  final metrics = <String, Object?>{};
  final mount = RemoteLocation.pathOf(
    '//wsl.localhost/${arguments[0]}${arguments[1]}',
  );
  if (wslProject(p.normalize(mount))?.path != arguments[1]) {
    throw StateError('WSL 项目路径在 Windows 规范化后失效：$mount');
  }
  metrics['uncPaths'] = 'passed';
  Future<T> timed<T>(String name, Future<T> Function() operation) async {
    final watch = Stopwatch()..start();
    final result = await operation();
    metrics['${name}Ms'] = watch.elapsedMilliseconds;
    return result;
  }

  final connection = await timed(
    'connect',
    () => WslConnection.start(
      arguments[0],
      _Binaries(
        arguments.length == 3
            ? arguments[2]
            : p.join(Directory.current.path, 'build', 'remote'),
      ),
    ),
  );
  final client = connection.client;
  final root = arguments[1];
  final scratch =
      '$root/.caocode-wsl-check-$pid-${DateTime.now().microsecondsSinceEpoch}';
  var created = false;
  try {
    metrics['entries'] = (await timed(
      'list',
      () => client.list(root, root),
    )).length;
    metrics['indexedFiles'] = (await timed(
      'index',
      () => client.walk(root),
    )).paths.length;
    final results = await timed(
      'search',
      () => client
          .searchText(
            root,
            const IdeTextQuery(
              'version:',
              includes: 'pubspec.yaml',
              maxResults: 25,
            ),
          )
          .toList(),
    );
    metrics['searchFiles'] = results.whereType<IdeFileMatches>().length;
    await client.create(scratch, scratch, directory: true);
    created = true;
    final path = '$scratch/你好.txt';
    await client.create(scratch, path);
    await client.read(scratch, path);
    await timed(
      'save',
      () => client.write(scratch, path, 'WSL native save\n', expectedText: ''),
    );
    if (await client.read(scratch, path) != 'WSL native save\n') {
      throw StateError('保存内容不一致');
    }
    await client.rename(scratch, path, '$scratch/renamed.txt');
    await client.copy(scratch, '$scratch/renamed.txt', '$scratch/copied.txt');
    if (await client.read(scratch, '$scratch/copied.txt') !=
        'WSL native save\n') {
      throw StateError('复制内容不一致');
    }
    await client.writeBytes(scratch, '$scratch/image.bin', [0, 255, 10]);
    if ((await client.readBytes('$scratch/image.bin')).join(',') !=
        '0,255,10') {
      throw StateError('二进制读取不一致');
    }
    final event = Completer<void>();
    final watch = client.watchDirectory(scratch).listen((_) {
      if (!event.isCompleted) event.complete();
    });
    try {
      await client.list(scratch, scratch);
      await client.create(scratch, '$scratch/watched.txt');
      await event.future.timeout(const Duration(seconds: 3));
    } finally {
      await watch.cancel();
    }
    metrics['crudAndWatcher'] = 'passed';
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(metrics));
  } finally {
    try {
      if (created) await client.delete(root, scratch);
    } finally {
      await connection.close();
    }
  }
}
