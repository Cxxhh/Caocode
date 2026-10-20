@TestOn('vm')
library;

import 'dart:io';

import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/chat/review/change_review.dart';
import 'package:caocode/chat/review/review_store_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A project in a temporary folder, its checkpoints in another; Git only
/// for the merges of Undo.
void main() {
  final hasGit = () {
    try {
      return Process.runSync('git', ['--version']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }();

  late Directory temp;
  late String root;
  late String checkpoints;

  String path(String relative) => p.joinAll([root, ...relative.split('/')]);

  void write(String relative, String text) {
    final file = File(path(relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  String read(String relative) => File(path(relative)).readAsStringSync();

  bool exists(String relative) => File(path(relative)).existsSync();

  Future<LocalReviewStore> store() async =>
      (await LocalReviewStore.open(root, checkpoints: checkpoints))!;

  Future<ChangeReview> open({String session = 's'}) async {
    final review = ChangeReview(await store())..session = session;
    addTearDown(review.dispose);
    return review;
  }

  /// The agent writes [text] to [relative] (null deletes it), and reports
  /// it with what was there.
  Future<void> edit(ChangeReview review, String relative, String? text) async {
    final before = exists(relative) ? read(relative) : null;
    if (text == null) {
      File(path(relative)).deleteSync();
    } else {
      write(relative, text);
    }
    review.report(
      FileChange(path: path(relative), added: 1, removed: 1),
      original: OriginalText(before),
    );
    await review.refresh();
  }

  /// The pending changes, by path relative to the project.
  Map<String, FileChange> changesOf(ChangeReview review) => {
    for (final change in review.changes)
      p.split(p.relative(change.path, from: root)).join('/'): change,
  };

  /// What the sessions keep, by session.
  List<String> sessionsKept() {
    final project = Directory(p.join(checkpoints))
        .listSync()
        .whereType<Directory>();
    return [
      for (final folder in project)
        for (final session in folder.listSync().whereType<Directory>())
          p.basename(session.path),
    ]..sort();
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('caocode_review_');
    final resolved = await temp.resolveSymbolicLinks();
    root = p.join(resolved, 'project');
    checkpoints = p.join(resolved, 'checkpoints');
    write('a.txt', '1\n2\n3\n4\n5\n');
    write('lib/b.txt', 'b\n');
  });

  tearDown(() => temp.delete(recursive: true));

  test('lists the edits the agent reports, not what else changed', () async {
    final review = await open();
    await edit(review, 'a.txt', 'one\n2\n3\n4\n5\n6\n');
    await edit(review, 'lib/c.txt', 'c\nc\n');
    await edit(review, 'lib/b.txt', null);
    // A command's, or the user's: not reported.
    write('notes.txt', 'mine\n');

    final changes = changesOf(review);
    expect(changes.keys, unorderedEquals(['a.txt', 'lib/b.txt', 'lib/c.txt']));
    expect(changes['a.txt']!.kind, FileChangeKind.modified);
    expect((changes['a.txt']!.added, changes['a.txt']!.removed), (2, 1));
    expect(changes['lib/c.txt']!.kind, FileChangeKind.added);
    expect(changes['lib/c.txt']!.added, 2);
    expect(changes['lib/b.txt']!.kind, FileChangeKind.deleted);
    expect(changes['lib/b.txt']!.removed, 1);

    // Changed back by the agent: nothing pending.
    await edit(review, 'lib/c.txt', null);
    expect(changesOf(review).keys, unorderedEquals(['a.txt', 'lib/b.txt']));
  });

  test('keeps a change without touching the file', () async {
    final review = await open();
    await edit(review, 'a.txt', 'one\n');
    await edit(review, 'lib/b.txt', 'bee\n');

    await review.keep([path('a.txt')]);
    expect(changesOf(review).keys, ['lib/b.txt']);
    expect(read('a.txt'), 'one\n');

    // Changed again by the agent: listed against what was kept.
    await edit(review, 'a.txt', 'one\ntwo\n');
    expect(changesOf(review)['a.txt']!.added, 1);
    expect(changesOf(review)['a.txt']!.removed, 0);

    await review.keepAll();
    expect(review.changes, isEmpty);
  });

  test('undoes edits, creations and deletions', () async {
    final review = await open();
    await edit(review, 'a.txt', 'one\n');
    await edit(review, 'new/deep/c.txt', 'c\n');
    await edit(review, 'lib/b.txt', null);
    expect(review.changes, hasLength(3));

    await review.undoAll();
    expect(review.changes, isEmpty);
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');
    expect(read('lib/b.txt'), 'b\n');
    // The folders it made go with the file.
    expect(Directory(path('new')).existsSync(), isFalse);
  });

  test('undo keeps what changed since the agent, or leaves the file', () async {
    final review = await open();
    await edit(review, 'a.txt', 'one\n2\n3\n4\n5\n');
    await edit(review, 'lib/b.txt', 'bee\n');

    // The user, after the turn.
    write('a.txt', 'one\n2\n3\n4\nfive\n');
    write('lib/b.txt', 'B\n');
    await review.refresh();

    await review.undo([path('a.txt')]);
    expect(read('a.txt'), '1\n2\n3\n4\nfive\n');
    expect(changesOf(review).keys, ['lib/b.txt']);

    // The same line: left as it is, and marked.
    await review.undo([path('lib/b.txt')]);
    expect(read('lib/b.txt'), 'B\n');
    expect(changesOf(review)['lib/b.txt']!.conflict, isTrue);
  }, skip: !hasGit);

  test('a file put back since is no longer pending', () async {
    final review = await open();
    await edit(review, 'a.txt', 'one\n');
    write('a.txt', '1\n2\n3\n4\n5\n');
    await review.refresh();
    expect(review.changes, isEmpty);
  });

  test('keeps and undoes a change part by part', () async {
    final review = await open();
    await edit(review, 'a.txt', 'one\n2\n3\n4\nfive\n');
    final a = path('a.txt');
    final created = review.baseOf(a);
    expect(created, isNotNull);
    expect(await review.original(a)!(), '1\n2\n3\n4\n5\n');

    // The first line kept: held against what was there with it in.
    await review.keepPart(a, 'one\n2\n3\n4\n5\n');
    expect(review.baseOf(a), isNot(created));
    expect(await review.original(a)!(), 'one\n2\n3\n4\n5\n');
    expect(
      (changesOf(review)['a.txt']!.added, changesOf(review)['a.txt']!.removed),
      (1, 1),
    );
    expect(read('a.txt'), 'one\n2\n3\n4\nfive\n');

    // The last undone in the file, as the editor does it: nothing left.
    write('a.txt', 'one\n2\n3\n4\n5\n');
    await review.settle([a]);
    expect(review.changes, isEmpty);
    expect(review.baseOf(a), isNull);
  });

  test('keeping every part of a change keeps it', () async {
    final review = await open();
    await edit(review, 'a.txt', '1\n2\nthree\n4\n5\n');
    await review.keepPart(path('a.txt'), '1\n2\nthree\n4\n5\n');
    expect(review.changes, isEmpty);
    expect(read('a.txt'), '1\n2\nthree\n4\n5\n');
  });

  test('puts back line endings as they were', () async {
    File(path('crlf.txt')).writeAsBytesSync('x\r\ny\r\n'.codeUnits);
    final review = await open();
    await edit(review, 'crlf.txt', 'x\r\nz\r\n');
    await review.undoAll();
    expect(File(path('crlf.txt')).readAsBytesSync(), 'x\r\ny\r\n'.codeUnits);
  });

  test('takes a patch back out of the file for what it was', () async {
    final review = await open();
    write('a.txt', '1\nTWO\n3\n4\n5\nsix\n');
    review.report(
      FileChange(path: path('a.txt'), added: 2, removed: 1),
      original: const OriginalByPatch(
        '@@ -1,3 +1,3 @@\n 1\n-2\n+TWO\n 3\n@@ -5 +5,2 @@\n 5\n+six\n',
      ),
    );
    await review.refresh();
    expect(changesOf(review)['a.txt']!.tracked, isTrue);
    expect(await review.original(path('a.txt'))!(), '1\n2\n3\n4\n5\n');

    // One that does not fit: listed, not undone.
    write('lib/b.txt', 'other\n');
    review.report(
      FileChange(path: path('lib/b.txt'), added: 1, removed: 1),
      original: const OriginalByPatch('@@ -1 +1 @@\n-b\n+bee\n'),
    );
    await review.refresh();
    expect(changesOf(review)['lib/b.txt']!.tracked, isFalse);
  });

  test('lists the edits it cannot undo, to keep', () async {
    final review = await open();
    // What it was not told.
    write('out/gen.txt', 'g\n');
    review.report(FileChange(path: path('out/gen.txt'), added: 1, removed: 0));
    // Outside the project.
    final elsewhere = File(p.join(temp.path, 'elsewhere.txt'))
      ..writeAsStringSync('e\ne\n');
    review.report(FileChange(path: elsewhere.path, added: 2, removed: 0));
    await review.refresh();

    expect(changesOf(review)['out/gen.txt']!.tracked, isFalse);
    expect(review.changes.where((c) => !c.tracked), hasLength(2));
    await review.undoAll();
    expect(exists('out/gen.txt'), isTrue);

    // Gone since: nothing left of it to keep.
    elsewhere.deleteSync();
    await review.refresh();
    expect(changesOf(review).keys, ['out/gen.txt']);
    await review.keepAll();
    expect(review.changes, isEmpty);
  });

  test('carries on where the session left off', () async {
    final review = await open(session: 'session-1');
    await edit(review, 'a.txt', 'one\n');

    final reopened = await ChangeReview.resume(await store(), 'session-1');
    addTearDown(reopened.dispose);
    expect(changesOf(reopened).keys, ['a.txt']);
    await reopened.undoAll();
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');
  });

  test(
    'each session keeps its own, and nothing once none is pending',
    () async {
      final mine = await open(session: 'mine');
      final theirs = await open(session: 'theirs');
      await edit(mine, 'a.txt', 'one\n');
      await edit(theirs, 'lib/b.txt', 'bee\n');
      expect(changesOf(mine).keys, ['a.txt']);
      expect(changesOf(theirs).keys, ['lib/b.txt']);
      expect(sessionsKept(), ['mine', 'theirs']);

      await mine.keepAll();
      expect(sessionsKept(), ['theirs']);
      await theirs.undoAll();
      expect(sessionsKept(), isEmpty);
      // Nor the project's folder.
      expect(Directory(checkpoints).listSync().whereType<Directory>(), isEmpty);
    },
  );

  test('keeps only what it still needs', () async {
    final review = await open();
    await edit(review, 'a.txt', 'one\n');
    await edit(review, 'a.txt', 'one\ntwo\n');
    await edit(review, 'lib/b.txt', 'bee\n');
    final blobs = Directory(p.join((await store()).folder, 's', 'blobs'));
    // What a.txt and b.txt were, and are.
    expect(blobs.listSync(), hasLength(4));
    await review.keep([path('lib/b.txt')]);
    expect(blobs.listSync(), hasLength(2));
  });

  test('a session named anew takes what it kept along', () async {
    final review = await open(session: 'first');
    await edit(review, 'a.txt', 'one\n');
    review.session = 'second';
    await review.refresh();
    expect(sessionsKept(), ['second']);
    await review.undoAll();
    expect(read('a.txt'), '1\n2\n3\n4\n5\n');
  });

  test("drops an earlier build's repository of snapshots", () async {
    final repository = Directory(
      p.join(checkpoints, p.basename((await store()).folder)),
    )..createSync(recursive: true);
    File(p.join(repository.path, 'HEAD')).writeAsStringSync('ref: x\n');
    File(p.join(repository.path, 'index')).writeAsStringSync('big');
    await store();
    expect(File(p.join(repository.path, 'HEAD')).existsSync(), isFalse);
  });
}
