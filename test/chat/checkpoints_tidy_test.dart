@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:caocode/chat/review/review_store_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late String root;
  late String checkpoints;
  final long = DateTime.now().subtract(const Duration(days: 60));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('caocode_tidy_');
    final resolved = await temp.resolveSymbolicLinks();
    root = p.join(resolved, 'project');
    checkpoints = p.join(resolved, 'checkpoints');
    await Directory(root).create();
  });

  tearDown(() => temp.delete(recursive: true));

  /// Session [name] of a project, saved [long] ago by another run of the
  /// app.
  Future<String> savedLongAgo(String project, String name) async {
    final folder = Directory(p.join(checkpoints, project, name));
    await Directory(p.join(folder.path, 'blobs')).create(recursive: true);
    final data = File(p.join(folder.path, 'review.json'))
      ..writeAsStringSync('{}');
    await data.setLastModified(long);
    return folder.path;
  }

  test('drops the sessions not saved for a month, keeps the others, and runs '
      'once a day', () async {
    final store = (await LocalReviewStore.open(
      root,
      checkpoints: checkpoints,
    ))!;
    await store.save('recent', '{}', blobs: const []);
    final project = p.basename(store.folder);
    final old = await savedLongAgo(project, 'old');

    await LocalReviewStore.tidy(checkpoints);
    expect(Directory(old).existsSync(), isFalse);
    expect(await store.load('recent'), '{}');

    // Not again the same day.
    final older = await savedLongAgo(project, 'older');
    await LocalReviewStore.tidy(checkpoints);
    expect(Directory(older).existsSync(), isTrue);
    await LocalReviewStore.tidy(
      checkpoints,
      now: DateTime.now().add(const Duration(days: 1, minutes: 1)),
    );
    expect(Directory(older).existsSync(), isFalse);
  });

  test("deletes a project's folder with no session left, and the "
      "repositories of an earlier build", () async {
    final gone = await savedLongAgo('gone-0000000000000000', 'old');
    final repository = Directory(p.join(checkpoints, 'repo-1111111111111111'))
      ..createSync(recursive: true);
    File(p.join(repository.path, 'HEAD')).writeAsStringSync('ref: x\n');
    final movedAside = Directory(
      p.join(checkpoints, 'repo-2222222222222222.old-1-2'),
    )..createSync(recursive: true);

    await LocalReviewStore.tidy(checkpoints);
    expect(Directory(p.dirname(gone)).existsSync(), isFalse);
    expect(repository.existsSync(), isFalse);
    expect(movedAside.existsSync(), isFalse);
  });

  test('a session used in this process is left be', () async {
    final store = (await LocalReviewStore.open(
      root,
      checkpoints: checkpoints,
    ))!;
    await store.store('open', Uint8List.fromList([1, 2]), mode: '100644');
    await store.save('open', '{}', blobs: const []);
    await File(p.join(store.folder, 'open', 'review.json'))
        .setLastModified(long);
    await LocalReviewStore.tidy(checkpoints);
    expect(await store.load('open'), '{}');
  });

  test('a missing folder is left be', () async {
    await LocalReviewStore.tidy(p.join(temp.path, 'none'));
    expect(Directory(p.join(temp.path, 'none')).existsSync(), isFalse);
  });
}
