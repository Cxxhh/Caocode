import 'dart:async';
import 'dart:io';

import 'package:caocode/stash/stash_disk_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('stash_disk'));
  tearDown(() => root.deleteSync(recursive: true));

  test('writes of one stash at once leave the last asked for, whole', () async {
    final disk = FileStashDisk(root.path);
    // Long enough that the writes would overlap.
    final texts = [
      for (var i = 0; i < 12; i++) '$i ${'x' * 200000}',
    ];
    await Future.wait([for (final text in texts) disk.write(7, text)]);
    expect(await disk.read(7), texts.last);
    // No temporary file left behind.
    expect(
      root.listSync().map((entity) => p.basename(entity.path)),
      ['7.md'],
    );
  });

  test('two disks on one folder (two windows) do not share a temporary '
      'file', () async {
    final one = FileStashDisk(root.path);
    final two = FileStashDisk(root.path);
    final a = 'a' * 300000;
    final b = 'b' * 300000;
    await Future.wait([one.write(3, a), two.write(3, b)]);
    // Either one, whole: never the two mixed.
    expect(await one.read(3), anyOf(a, b));
    expect(
      root.listSync().map((entity) => p.basename(entity.path)),
      ['3.md'],
    );
  });

  test('a write that fails leaves the next one to go on', () async {
    final disk = FileStashDisk(root.path);
    // A folder where the file goes: the move in place fails.
    Directory(p.join(root.path, '5.md')).createSync();
    await expectLater(disk.write(5, 'first'), throwsA(isA<FileSystemException>()));
    expect(
      root.listSync().where((entity) => entity.path.endsWith('.tmp')),
      isEmpty,
    );
    Directory(p.join(root.path, '5.md')).deleteSync();
    await disk.write(5, 'second');
    expect(await disk.read(5), 'second');
  });

  group('changes', () {
    late StreamController<FileSystemEvent> events;
    late FileStashDisk disk;
    late int told;

    setUp(() async {
      events = StreamController<FileSystemEvent>();
      disk = FileStashDisk(root.path, (_) => events.stream);
      told = 0;
      disk.changes.listen((_) => told++);
      await pumpEventQueue();
    });

    Future<void> settle() => Future<void>.delayed(
      const Duration(milliseconds: 400),
    );

    String at(String name) => p.join(root.path, name);

    test("another's file moved in place (an agent's write on Windows) is "
        'told of', () async {
      events.add(FileSystemMoveEvent(at('2.md.tmp.42.1'), false, at('2.md')));
      await settle();
      expect(told, 1);
    });

    test('its own write moved in place is not, and the next of '
        "another's is", () async {
      await disk.write(4, 'mine');
      events.add(
        FileSystemMoveEvent(at('4.md.1-0-1.tmp'), false, at('4.md')),
      );
      await settle();
      expect(told, 0);
      events.add(FileSystemModifyEvent(at('4.md'), false, true));
      await settle();
      expect(told, 1);
    });

    test('other files are not', () async {
      events
        ..add(FileSystemCreateEvent(at('.stash.json'), false))
        ..add(FileSystemMoveEvent(at('a.tmp'), false, at('notes.txt')));
      await settle();
      expect(told, 0);
    });
  });
}
