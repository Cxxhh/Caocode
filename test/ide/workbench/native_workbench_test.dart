import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:caocode/ide/ide_editor.dart';
import 'package:caocode/ide/ide_find_widget.dart';

import 'fake_files.dart';

/// The workbench with the default painted Monaco surface, not the fallback.
void main() {
  Future<void> settleAssets(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
  }

  testWidgets('palette editor commands run against the painted editor', (
    tester,
  ) async {
    final workspace = await pumpWorkbench(
      tester,
      {'lib/main.dart': 'void main() {\n  print(1);\n}\n'},
      open: ['lib/main.dart'],
      nativeEditor: true,
    );
    await settleAssets(tester);
    expect(find.byType(EditorSurface), findsOneWidget);
    final editor = tester.state<IdeEditorState>(find.byType(IdeEditor));
    // Two-space indentation is detected from the file for the status bar.
    expect(editor.indentationLabel, 'Spaces: 2');
    expect(find.text('Spaces: 2'), findsOneWidget);

    final commands = editor.editorCommands;
    final comment = commands.singleWhere(
      (command) => command.id == 'editor.action.commentLine',
    );
    expect(comment.category, 'Editor');
    tester
        .widget<EditorSurface>(find.byType(EditorSurface))
        .controller
        .select(0, 0);
    comment.run();
    await tester.pump();
    await tester.pump();
    expect(workspace.active!.text, startsWith('// void main() {'));
    // Retokenizing the edit may yield to the event loop when the machine is
    // busy; let it finish before the test ends.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('the line endings item changes the end of line sequence', (
    tester,
  ) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'one\ntwo\r\nthree\n'},
      open: ['a.txt'],
      nativeEditor: true,
    );
    await settleAssets(tester);
    final controller = tester
        .widget<EditorSurface>(find.byType(EditorSurface))
        .controller;
    // Line 3, column 2.
    controller.select(10, 10);
    await tester.pump();
    expect(find.text('Mixed'), findsOneWidget);
    expect(find.byTooltip('Select End of Line Sequence'), findsOneWidget);

    await tester.tap(find.text('Mixed'));
    await tester.pump();
    expect(find.text('Select End of Line Sequence'), findsWidgets);
    expect(find.text('LF'), findsOneWidget);
    await tester.tap(find.text('CRLF'));
    await tester.pump();
    await tester.pump();
    expect(workspace.active!.text, 'one\r\ntwo\r\nthree\r\n');
    expect(find.text('CRLF'), findsOneWidget);
    // Still line 3, column 2; one undo step.
    expect(controller.selections, [const TextSelection.collapsed(offset: 11)]);
    expect(workspace.active!.model.undo(), isTrue);
    expect(workspace.active!.text, 'one\ntwo\r\nthree\n');
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('typing rebuilds the editor and the status bar, not the '
      'workbench; the tab shows the document dirty and clean again', (
    tester,
  ) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'one\ntwo\n'},
      open: ['a.txt'],
      nativeEditor: true,
    );
    await settleAssets(tester);
    await tester.tap(find.byType(EditorSurface));
    await tester.pump();
    final controller = tester
        .widget<EditorSurface>(find.byType(EditorSurface))
        .controller;
    controller.select(3, 3);
    await tester.pump();
    expect(find.text('Ln 1, Col 4'), findsOneWidget);
    final dirty = find.byKey(const ValueKey('dirty'));
    expect(dirty, findsNothing);

    Future<void> typeV() async {
      final value = controller.value;
      final caret = value.selection.extentOffset;
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: value.text.replaceRange(caret, caret, 'v'),
          selection: TextSelection.collapsed(offset: caret + 1),
        ),
      );
      await tester.pump();
    }

    // The first edit makes the document dirty: the tab shows it.
    await typeV();
    expect(dirty, findsOneWidget);
    expect(find.text('Ln 1, Col 5'), findsOneWidget);

    final rebuilt = <String>{};
    debugOnRebuildDirtyWidget = (element, _) =>
        rebuilt.add('${element.widget.runtimeType}');
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (var i = 0; i < 3; i++) {
      await typeV();
    }
    debugOnRebuildDirtyWidget = null;
    expect(workspace.active!.text, 'onevvvv\ntwo\n');
    // The status bar follows in the frame the edit is drawn in.
    expect(find.text('Ln 1, Col 8'), findsOneWidget);
    expect(rebuilt, containsAll(['EditorSurface', 'IdeStatusBar']));
    // The rest of the workbench (its tabs among them) stays as it was.
    expect(rebuilt, isNot(contains('IdeTabBar')));

    // Saved, it is clean; edited again, dirty again.
    await tester.runAsync(() => workspace.save(workspace.active!));
    await tester.pump();
    expect(dirty, findsNothing);
    await typeV();
    expect(dirty, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('find matches are painted as surface decorations', (
    tester,
  ) async {
    await pumpWorkbench(
      tester,
      {'a.txt': 'one two one two one'},
      open: ['a.txt'],
      nativeEditor: true,
    );
    await settleAssets(tester);
    final editor = tester.state<IdeEditorState>(find.byType(IdeEditor));
    editor.openFind();
    await tester.pump();
    await tester.enterText(
      find
          .descendant(
            of: find.byType(IdeFindWidget),
            matching: find.byType(TextField),
          )
          .first,
      'one',
    );
    await tester.pump();
    final surface = tester.widget<EditorSurface>(find.byType(EditorSurface));
    expect(surface.decorations, hasLength(3));
    expect(surface.decorations.map((d) => d.start), [0, 8, 16]);
  });
}
