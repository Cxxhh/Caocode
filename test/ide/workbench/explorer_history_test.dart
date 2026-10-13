import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:caocode/chat/composer/file_drop.dart';
import 'package:caocode/ide/ide_explorer.dart';

import 'fake_files.dart';

/// The explorer as VS Code's: a click below the rows selects none, what is
/// dragged onto a folder moves into it, and file operations are undone and
/// done again.
void main() {
  Future<(IdeExplorerController, TreeFiles)> pumpTree(
    WidgetTester tester,
  ) async {
    final files = TreeFiles({
      inRoot('lib/a.dart'): 'a',
      inRoot('README.md'): 'r',
    });
    final controller = IdeExplorerController(
      files: files,
      root: testRoot,
      watch: (_) => const Stream.empty(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: IdeExplorer(controller: controller, onOpen: (_, _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, files);
  }

  /// Drags the row [from] onto the row [onto], in steps.
  Future<void> dragOnto(WidgetTester tester, String from, String onto) async {
    final start = tester.getCenter(find.text(from));
    final end = tester.getCenter(find.text(onto));
    final gesture = await tester.startGesture(start);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(Offset.lerp(start, end, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  IdeExplorerState explorer(WidgetTester tester) =>
      tester.state<IdeExplorerState>(find.byType(IdeExplorer));

  testWidgets('a click below the rows selects none', (tester) async {
    final (controller, _) = await pumpTree(tester);
    await tester.tap(find.text('README.md'));
    await tester.pump();
    expect(controller.selected, inRoot('README.md'));

    await tester.tapAt(
      tester.getBottomLeft(find.byType(IdeExplorer)) + const Offset(40, -20),
    );
    await tester.pump();
    expect(controller.selected, isNull);
    expect(controller.selection, isEmpty);
  });

  testWidgets('a file dragged onto a folder moves into it; undone and done '
      'again', (tester) async {
    final (controller, files) = await pumpTree(tester);
    await dragOnto(tester, 'README.md', 'lib');
    expect(files.contents.keys, contains(inRoot('lib/README.md')));
    expect(files.contents.keys, isNot(contains(inRoot('README.md'))));
    expect(explorer(tester).canUndo, isTrue);

    await explorer(tester).undo();
    await tester.pumpAndSettle();
    expect(files.contents.keys, contains(inRoot('README.md')));
    expect(files.contents.keys, isNot(contains(inRoot('lib/README.md'))));
    expect(explorer(tester).canRedo, isTrue);

    await explorer(tester).redo();
    await tester.pumpAndSettle();
    expect(files.contents.keys, contains(inRoot('lib/README.md')));
    expect(controller.selected, inRoot('lib/README.md'));
  });

  testWidgets('a folder is not dropped into itself', (tester) async {
    final (_, files) = await pumpTree(tester);
    await tester.tap(find.text('lib'));
    await tester.pumpAndSettle();
    await tester.timedDrag(
      find.text('lib'),
      tester.getCenter(find.text('a.dart')) -
          tester.getCenter(find.text('lib')),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(files.contents.keys, contains(inRoot('lib/a.dart')));
    expect(explorer(tester).canUndo, isFalse);
  });

  testWidgets('a file made is deleted by Undo, made again by Redo', (
    tester,
  ) async {
    final (_, files) = await pumpTree(tester);
    await explorer(tester).startCreate(directory: false);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'notes/new.txt');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(files.contents[inRoot('notes/new.txt')], '');
    expect(files.folders, contains(inRoot('notes')));

    await explorer(tester).undo();
    await tester.pumpAndSettle();
    expect(files.contents.keys, isNot(contains(inRoot('notes/new.txt'))));
    expect(files.folders, isNot(contains(inRoot('notes'))));

    await explorer(tester).redo();
    await tester.pumpAndSettle();
    expect(files.contents[inRoot('notes/new.txt')], '');

    // Changed since: Undo asks before deleting it.
    files.contents[inRoot('notes/new.txt')] = 'kept';
    final undo = explorer(tester).undo();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await undo;
    expect(files.contents[inRoot('notes/new.txt')], 'kept');
  });

  testWidgets('a file deleted for good is made again by Undo', (tester) async {
    final (_, files) = await pumpTree(tester);
    await tester.tap(find.text('README.md'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(files.contents.keys, isNot(contains(inRoot('README.md'))));

    await explorer(tester).undo();
    await tester.pumpAndSettle();
    expect(utf8.decode(files.bytes[inRoot('README.md')]!), 'r');
    expect(find.text('README.md'), findsOneWidget);
  });

  testWidgets('a file dragged in from another app is copied into the folder '
      'it is let go on; Undo deletes the copy', (tester) async {
    final (_, files) = await pumpTree(tester);
    final outside = p.join(p.separator, 'elsewhere', 'shot.png');
    files.contents[outside] = 'png';
    final over = tester.getCenter(find.text('lib'));
    Future<Object?> send(String method) => FileDrops.handle(
      MethodCall(method, {
        'x': over.dx,
        'y': over.dy,
        'files': [
          {'path': outside},
        ],
      }),
    );

    expect(await send('dragUpdate'), isTrue);
    await tester.pump();
    final highlighted = find.descendant(
      of: find.byType(IdeExplorer),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.position == DecorationPosition.foreground,
      ),
    );
    expect(highlighted, findsOneWidget);

    expect(await send('drop'), isTrue);
    await tester.pumpAndSettle();
    expect(files.contents[inRoot('lib/shot.png')], 'png');
    expect(files.contents[outside], 'png');
    expect(highlighted, findsNothing);

    await explorer(tester).undo();
    await tester.pumpAndSettle();
    expect(files.contents.keys, isNot(contains(inRoot('lib/shot.png'))));
  });

  /// The window's channel, answering [answers] (by method; true for the
  /// rest): the calls made on it.
  List<MethodCall> windowCalls(
    WidgetTester tester, [
    Map<String, Object?> answers = const {},
  ]) {
    final calls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    const channel = MethodChannel('caocode/window');
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answers.containsKey(call.method) ? answers[call.method] : true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    return calls;
  }

  testWidgets('a file dragged is watched by the window, which drags it on '
      'itself once the pointer leaves it', (tester) async {
    final calls = windowCalls(tester);
    await pumpTree(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('README.md')),
    );
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(calls.single.method, 'armFileDrag');
    expect(calls.single.arguments, {
      'paths': [inRoot('README.md')],
    });
    // Out: the window began the system's drag, and says so.
    await FileDrops.handle(const MethodCall('dragOut', {'began': true}));
    await gesture.moveTo(const Offset(-30, 200));
    await tester.pump();
    expect([for (final call in calls) call.method], ['armFileDrag']);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls.last.method, 'disarmFileDrag');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('a file dragged out of a window that does not watch goes on as '
      'the system drags files', (tester) async {
    final calls = windowCalls(tester, {'armFileDrag': null});
    await pumpTree(tester);
    final start = tester.getCenter(find.text('README.md'));
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, 40));
    await tester.pump();
    // Still in the window: the app's own drag.
    expect(calls.where((call) => call.method == 'startFileDrag'), isEmpty);
    await gesture.moveTo(const Offset(-30, 200));
    await tester.pump();
    final drag = calls.singleWhere((call) => call.method == 'startFileDrag');
    expect(drag.arguments, {
      'paths': [inRoot('README.md')],
    });
    await gesture.up();
    await tester.pumpAndSettle();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a file from another app let go under the rows goes into the '
      "project's folder", (tester) async {
    final (_, files) = await pumpTree(tester);
    final outside = p.join(p.separator, 'elsewhere', 'notes.txt');
    files.contents[outside] = 'n';
    final under =
        tester.getBottomLeft(find.byType(IdeExplorer)) + const Offset(40, -20);
    final taken = await FileDrops.handle(
      MethodCall('drop', {
        'x': under.dx,
        'y': under.dy,
        'files': [
          {'path': outside},
        ],
      }),
    );
    expect(taken, isTrue);
    await tester.pumpAndSettle();
    expect(files.contents[inRoot('notes.txt')], 'n');
  });

  testWidgets('Cmd+Z in the tree undoes', (tester) async {
    final (_, files) = await pumpTree(tester);
    await tester.tap(find.text('README.md'));
    await tester.pump();
    final state = explorer(tester);
    await dragOnto(tester, 'README.md', 'lib');
    expect(state.canUndo, isTrue);

    await tester.tap(find.text('lib'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(files.contents.keys, contains(inRoot('README.md')));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
