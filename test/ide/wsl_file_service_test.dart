@TestOn('linux')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:caocode/chat/side_panel/file_link.dart';
import 'package:caocode/ide/file_service.dart';
import 'package:caocode/ide/ide_explorer.dart';
import 'package:caocode/ide/wsl_file_service.dart';
import 'package:caocode/kernel/codex/codex_host.dart';
import 'package:bao_remote/search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../remote/remote_harness.dart';

void main() {
  late RemoteHarness harness;
  late Directory directory;
  late WslIdeFileService files;
  late String root;

  setUp(() async {
    harness = await RemoteHarness.start();
    directory = Directory.systemTemp.createTempSync('caocode-wsl-files-');
    root = p.windows.normalize(
      wslWindowsPath('//wsl.localhost/Ubuntu${directory.path}'),
    );
    expect(wslProject(root), isNotNull, reason: root);
    files = WslIdeFileService(
      root,
      <T>(operation) => operation(harness.client),
    );
  });
  tearDown(() async {
    await harness.close();
    directory.deleteSync(recursive: true);
  });

  String at(String name) => p.windows.normalize(p.windows.join(root, name));

  test('native save preserves conflict detection, case and UTF-8', () async {
    final file = File('${directory.path}/你好.txt')..writeAsStringSync('first\n');
    expect(await files.read(at('你好.txt')), 'first\n');
    await files.write(at('你好.txt'), '第二行\n', expectedText: 'first\n');
    expect(file.readAsStringSync(), '第二行\n');
    file.writeAsStringSync('changed externally\n');
    await expectLater(
      files.write(at('你好.txt'), 'overwrite'),
      throwsA(isA<IdeFileConflictException>()),
    );
    await files.create(at('A.txt'));
    await files.create(at('a.txt'));
    expect(
      (await files.list(root)).map((entry) => entry.name),
      containsAll(['A.txt', 'a.txt', '你好.txt']),
    );
  });

  test(
    'CRUD, previews and downloads use native files with UNC results',
    () async {
      expect(filesAvailableToSystem(files), isTrue);
      await files.create(at('folder'), directory: true);
      await files.writeBytes(
        at('folder/image.bin'),
        Uint8List.fromList([0, 1, 255]),
      );
      final entry = (await files.list(at('folder'))).single;
      expect(entry.path, at('folder/image.bin'));
      expect(await readBytesThrough(files, entry.path), [0, 1, 255]);
      expect(await byteSizeThrough(files, entry.path), 3);
      expect((await files.readRange(entry.path, 1, 2)).bytes, [1, 255]);
      await files.copy(at('folder'), at('copy'));
      await files.rename(at('copy/image.bin'), at('copy/moved.bin'));
      await files.delete(at('folder'));
      expect(File('${directory.path}/copy/moved.bin').readAsBytesSync(), [
        0,
        1,
        255,
      ]);
      await expectLater(files.delete(root), throwsA(anything));
      expect(directory.existsSync(), isTrue);
    },
  );

  test(
    'index and search execute on Linux and return openable UNC paths',
    () async {
      File('${directory.path}/match.txt').writeAsStringSync('unique needle\n');
      Directory('${directory.path}/node_modules').createSync();
      File('${directory.path}/node_modules/hidden.txt')
          .writeAsStringSync('needle');
      final listing = await listProjectFiles(files, root);
      expect(listing.paths, [at('match.txt')]);
      final results = await files
          .searchText(root, const IdeTextQuery('needle'))
          .toList();
      expect(results.whereType<IdeFileMatches>().single.path, at('match.txt'));
      expect(
        await files.read(results.whereType<IdeFileMatches>().single.path),
        'unique needle\n',
      );
    },
  );

  test('native watcher notices external writes', () async {
    final event = Completer<void>();
    final watch = files.watchDirectory(root).listen((_) {
      if (!event.isCompleted) event.complete();
    });
    try {
      await until(() => harness.sent.any((line) => line.contains('fs/watch')));
      // Ensure the server has installed its native watcher.
      await harness.client.list(directory.path, directory.path);
      File('${directory.path}/external.txt').writeAsStringSync('agent change');
      await event.future.timeout(const Duration(seconds: 3));
    } finally {
      await watch.cancel();
    }
  });

  test('UNC aliases and extended paths select the same WSL environment', () {
    expect(
      wslProject(r'\\?\UNC\wsl.localhost\Ubuntu\home\me')?.path,
      '/home/me',
    );
    expect(files.native(r'\\wsl$\Ubuntu\home\me\x.txt'), '/home/me/x.txt');
    expect(
      () => files.native(r'\\wsl.localhost\Debian\home\me'),
      throwsArgumentError,
    );
    expect(() => files.native(r'C:\Users\me\x.txt'), throwsArgumentError);
    expect(
      FileLink.resolvePath('${directory.path}/a.txt', root, paths: p.windows),
      at('a.txt'),
    );
    expect(
      FileLink.resolvePath('/outside/a.txt', root, paths: p.windows),
      isNull,
    );
    final sent = harness.sent.map(jsonDecode).whereType<Map>().toList();
    expect(sent.any((message) => message['method'] == 'initialize'), isTrue);
  });

  test('file tree shows loading and loads only expanded directories', () async {
    Directory('${directory.path}/nested').createSync();
    File('${directory.path}/nested/child.txt').writeAsStringSync('child');
    final gate = Completer<void>();
    final delayed = WslIdeFileService(root, <T>(operation) async {
      await gate.future;
      return operation(harness.client);
    });
    final tree = IdeExplorerController(
      files: delayed,
      root: root,
      paths: p.windows,
      watch: (_) => const Stream.empty(),
    );
    try {
      expect(tree.rows.single.loading, isTrue);
      gate.complete();
      await until(() => tree.rows.any((row) => row.name == 'nested'));
      expect(tree.rows.map((row) => row.name), ['nested']);
      await tree.expand(at('nested'));
      expect(tree.rows.map((row) => row.name), ['nested', 'child.txt']);
    } finally {
      tree.dispose();
    }
  });
}
