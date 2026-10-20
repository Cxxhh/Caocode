import 'dart:async';

import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/chat/widgets/code_citation.dart' show MarkdownCodeBlock;
import 'package:caocode/stash/stash_caret.dart';
import 'package:caocode/stash/stash_disk.dart';
import 'package:caocode/stash/stash_editor.dart';
import 'package:caocode/stash/stash_markdown.dart';
import 'package:caocode/theme/codicons.dart';
import 'package:caocode/stash/stash_store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/models/model_providers.dart';

void main() {
  testWidgets(
    'the bar\'s polish, clicked, keeps the bar and replaces the text',
    (tester) async {
      // Its model picked already: no menu first.
      final previous = ModelProviders.current;
      addTearDown(() => ModelProviders.current = previous);
      await (ModelProviders.current = ModelProviders.memory()).setActionsModel(
        ModelProviders.followAuxiliary,
      );
      final document = Document()..insert(0, '321321\n321\n3123');
      final controller = StashEditor.controllerFor(document);
      final focus = FocusNode();
      final answer = Completer<String?>();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            FlutterQuillLocalizations.delegate,
          ],
          home: Scaffold(
            body: StashEditor(
              controller: controller,
              store: StashStore(MemoryStashDisk()),
              ensureNote: () async => 1,
              focusNode: focus,
              autofocus: true,
              onPolish: (text) => answer.future,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      controller.updateSelection(
        TextSelection(baseOffset: 0, extentOffset: document.length - 1),
        ChangeSource.local,
      );
      await tester.pumpAndSettle();
      expect(find.text('Polish'), findsOneWidget);
      // Clicked with the mouse, hovered first: the bar stays, the editor
      // keeps its focus and selection.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Polish')));
      await tester.pump(const Duration(milliseconds: 700));
      await mouse.down(tester.getCenter(find.text('Polish')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      await mouse.up();
      await tester.pump();
      expect(find.text('Polishing…'), findsOneWidget);

      answer.complete('Better text');
      await tester.pumpAndSettle();
      expect(document.toPlainText(), 'Better text\n');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 11),
      );
      expect(find.text('Polish'), findsOneWidget);
      await mouse.removePointer();
      await tester.pumpAndSettle(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'the bar\'s model menu, open, keeps the bar where it stands',
    (tester) async {
      // None picked: the polish opens the menu that picks one.
      final previous = ModelProviders.current;
      addTearDown(() => ModelProviders.current = previous);
      ModelProviders.current = ModelProviders.memory();
      final document = Document()..insert(0, '321321\n321\n3123');
      final controller = StashEditor.controllerFor(document);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            FlutterQuillLocalizations.delegate,
          ],
          home: Scaffold(
            body: StashEditor(
              controller: controller,
              store: StashStore(MemoryStashDisk()),
              ensureNote: () async => 1,
              focusNode: focus,
              autofocus: true,
              onPolish: (text) async => 'POLISHED',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      controller.updateSelection(
        TextSelection(baseOffset: 0, extentOffset: document.length - 1),
        ChangeSource.local,
      );
      await tester.pumpAndSettle();
      expect(find.text('Polish'), findsOneWidget);

      // Polish, clicked with the mouse: no model picked yet, so the menu
      // that picks one opens. It takes the keyboard; the bar stays over
      // the selection all the same.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Polish')));
      await tester.pump(const Duration(milliseconds: 700));
      await mouse.down(tester.getCenter(find.text('Polish')));
      await tester.pump();
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text(englishLocalizations.aiModelFirst), findsOneWidget);
      expect(find.text('Polish'), findsOneWidget);

      // Picked from it: the polish goes on with the text selected, the bar
      // still there.
      await tester.tap(find.text(englishLocalizations.aiModelAuxiliary));
      await tester.pumpAndSettle();
      expect(
        ModelProviders.current.actionsModel,
        ModelProviders.followAuxiliary,
      );
      expect(document.toPlainText(), 'POLISHED\n');
      expect(find.text('Polish'), findsOneWidget);
      await mouse.removePointer();
      await tester.pumpAndSettle(const Duration(seconds: 1));
    },
  );

  testWidgets('text selected by a drag, the editor not focused before, is '
      'deleted by Backspace', (tester) async {
    final document = Document()..insert(0, 'hello world');
    final controller = StashEditor.controllerFor(document);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Scaffold(
          body: StashEditor(
            controller: controller,
            store: StashStore(MemoryStashDisk()),
            ensureNote: () async => 1,
            focusNode: focus,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isFalse);
    final text = find.byType(QuillEditor);
    final start = tester.getTopLeft(text) + const Offset(2, 10);
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    for (var x = 10.0; x <= 300; x += 10) {
      await mouse.moveTo(start + Offset(x, 0));
      await tester.pump();
    }
    await mouse.up();
    await tester.pumpAndSettle();
    expect(controller.selection.isCollapsed, isFalse);
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(document.toPlainText(), isNot(contains('hello')));
  });

  testWidgets('the color menu keeps focus and applies and clears both colors', (
    tester,
  ) async {
    final document = Document()..insert(0, 'hello world');
    final controller = StashEditor.controllerFor(document);
    final focus = await _edit(tester, controller);
    const selection = TextSelection(baseOffset: 1, extentOffset: 5);
    controller.updateSelection(selection, ChangeSource.local);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);

    Future<void> pick(Finder swatch) async {
      await tester.tap(find.byIcon(Codicons.symbolColor));
      await tester.pumpAndSettle();
      final position = tester.getCenter(swatch);
      await mouse.moveTo(position);
      await mouse.down(position);
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(controller.selection, selection);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('A'), findsNothing);
      expect(find.byIcon(Codicons.symbolColor), findsOneWidget);
    }

    await pick(find.text('A').first);
    expect(document.collectStyle(1, 4).attributes['color']?.value, 'red');
    expect(document.collectStyle(0, 1).attributes['color'], isNull);
    expect(document.collectStyle(5, 6).attributes['color'], isNull);
    await pick(find.text('A').at(StashColors.text.length));
    expect(
      document.collectStyle(1, 4).attributes['background']?.value,
      'mistyrose',
    );
    expect(document.collectStyle(1, 4).attributes['color']?.value, 'red');
    await pick(find.text('∅').first);
    expect(document.collectStyle(1, 4).attributes['color'], isNull);
    expect(
      document.collectStyle(1, 4).attributes['background']?.value,
      'mistyrose',
    );
    await pick(find.text('∅').last);
    expect(document.collectStyle(1, 4).attributes['background'], isNull);
    expect(document.toPlainText(), 'hello world\n');
    await mouse.removePointer();
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  testWidgets('a link is typed in the bar, not a dialog', (tester) async {
    final document = Document()..insert(0, 'see the docs');
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    controller.updateSelection(
      const TextSelection(baseOffset: 8, extentOffset: 12),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Codicons.link));
    await tester.pumpAndSettle();
    // The field in the bar (the text is Quill's own, no EditableText).
    expect(find.byType(EditableText), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'https://x.dev');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final style = controller.document.collectStyle(8, 4);
    expect(style.attributes[Attribute.link.key]?.value, 'https://x.dev');
    expect(find.byType(EditableText), findsNothing);
  });

  testWidgets('pictures and links are tags in the line, code a block', (
    tester,
  ) async {
    final document = Document()
      ..insert(0, 'a ')
      ..insert(2, StashEmbeds.of(StashEmbeds.image, {'src': '1/a.png'}))
      ..insert(3, ' b ')
      ..insert(
        6,
        StashEmbeds.of(StashEmbeds.card, {
          'url': 'https://x.dev',
          'title': 'X',
        }),
      )
      ..insert(7, '\n')
      ..insert(
        8,
        StashEmbeds.of(StashEmbeds.code, {'code': 'x\ny', 'language': 'dart'}),
      );
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    expect(find.text('Image 1'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    // All on the one line.
    final y = tester.getCenter(find.text('Image 1')).dy;
    // Code, as the chat shows it, on lines of its own.
    expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(MarkdownCodeBlock)).dy,
      greaterThan(y),
    );
    expect(tester.getCenter(find.text('X')).dy, closeTo(y, 2));
  });

  testWidgets('a task box is at the left edge of the text, centered on its '
      'line, and checks it', (tester) async {
    final document = Document()
      ..insert(0, 'plain\ntask\n')
      ..format(6, 1, Attribute.unchecked);
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    final box = find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.checked != null,
    );
    expect(box, findsOneWidget);
    final plain = tester.getRect(find.text('plain', findRichText: true));
    final task = tester.getRect(find.text('task', findRichText: true));
    final square = tester.getRect(box);
    expect(square.left, closeTo(plain.left, 0.5));
    expect(square.center.dy, closeTo(task.center.dy, 1));
    expect(task.left, closeTo(square.right + 8, 0.5));

    await tester.tap(box);
    await tester.pump();
    expect(controller.document.toDelta().toList()[1].attributes, {
      Attribute.list.key: Attribute.checked.value,
    });
  });

  testWidgets('said clearly, its text is replaced in one step Undo takes '
      'back; its pictures and a requirement written before stay', (
    tester,
  ) async {
    final controller = StashEditor.controllerFor(
      stashDocument('btn hidden ![](1/a.png) sidebar\n\n## 需求\n\nold one\n'),
    );
    await _edit(tester, controller);
    final state = tester.state<StashEditorState>(find.byType(StashEditor));
    final asked = state.textPart!.text;
    expect(asked, isNot(contains('需求')));
    expect(asked, contains('1/a.png]'));
    // Changed meanwhile: not replaced.
    expect(state.rewrite('$asked!', 'whatever'), isFalse);
    expect(
      state.rewrite(
        asked,
        asked.replaceFirst('btn hidden', 'The button is hidden by'),
      ),
      isTrue,
    );
    await tester.pump();
    final markdown = stashDeltaToMarkdown(controller.document.toDelta());
    expect(
      markdown,
      startsWith('The button is hidden by ![](1/a.png) sidebar'),
    );
    expect(markdown, contains('## 需求\n\nold one'));

    controller.undo();
    expect(
      stashDeltaToMarkdown(controller.document.toDelta()),
      startsWith('btn hidden ![](1/a.png) sidebar'),
    );
  });

  testWidgets('a tag never ends a line: a space after it', (tester) async {
    final document = Document()
      ..insert(0, 'see ')
      ..insert(
        4,
        StashEmbeds.of(StashEmbeds.card, {
          'url': 'https://x.dev',
          'title': 'X',
        }),
      );
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    expect(document.toPlainText(), 'see \uFFFC \n');
  });

  testWidgets('the caret in a web link: a bar over it opens or edits it, '
      'the text typed on', (tester) async {
    final document = Document()
      ..insert(0, 'see docs now')
      ..format(4, 4, const LinkAttribute('https://x.dev/guide'));
    final controller = StashEditor.controllerFor(document);
    final focus = await _edit(tester, controller);
    controller.updateSelection(
      const TextSelection.collapsed(offset: 6),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    expect(find.text('x.dev/guide'), findsOneWidget);
    // Typing goes on in the text: the bar takes no focus.
    expect(focus.hasFocus, isTrue);
    // Beside the link, not in it: no bar.
    controller.updateSelection(
      const TextSelection.collapsed(offset: 9),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    expect(find.text('x.dev/guide'), findsNothing);
    controller.updateSelection(
      const TextSelection.collapsed(offset: 5),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Codicons.edit));
    await tester.pumpAndSettle();
    expect(
      controller.selection,
      const TextSelection(baseOffset: 4, extentOffset: 8),
    );
    // The link field, with the link in it.
    expect(find.byType(EditableText), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'https://x.dev/guide',
    );
  });

  testWidgets('another stash shown closes the link field', (tester) async {
    final document = Document()..insert(0, 'see docs');
    final first = StashEditor.controllerFor(document);
    final focus = FocusNode();
    final store = StashStore(MemoryStashDisk());
    Widget editor(QuillController controller) => MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      home: Scaffold(
        body: StashEditor(
          controller: controller,
          store: store,
          ensureNote: () async => 1,
          focusNode: focus,
          autofocus: true,
        ),
      ),
    );
    await tester.pumpWidget(editor(first));
    focus.requestFocus();
    await tester.pumpAndSettle();
    first.updateSelection(
      const TextSelection(baseOffset: 4, extentOffset: 8),
      ChangeSource.local,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Codicons.link));
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsOneWidget);
    await tester.pumpWidget(
      editor(StashEditor.controllerFor(Document()..insert(0, 'other'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EditableText), findsNothing);
  });

  testWidgets('code pasted amid a line goes on lines of its own', (
    tester,
  ) async {
    final document = Document()..insert(0, 'abc def');
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    controller.updateSelection(
      const TextSelection.collapsed(offset: 3),
      ChangeSource.local,
    );
    tester
        .state<StashEditorState>(find.byType(StashEditor))
        .insertMarkdown('```\nx = 1\n```');
    await tester.pumpAndSettle();
    final nodes = document.root.children.toList();
    expect(nodes, hasLength(3));
    expect(nodes[0].toPlainText(), 'abc\n');
    // Lines of the editor's own code block, typed in in place.
    expect(nodes[1], isA<Block>());
    expect(nodes[1].toPlainText(), 'x = 1\n');
    expect(
      (nodes[1] as Block).style.attributes.containsKey(Attribute.codeBlock.key),
      isTrue,
    );
    expect(nodes[2].toPlainText(), ' def\n');
    // The caret after it.
    expect(controller.selection.baseOffset, 10);
  });

  testWidgets('a code block: started with ```lang and Enter, typed in, '
      'left with Enter on its empty last line, written as a fence', (
    tester,
  ) async {
    final document = Document()..insert(0, 'note\n```dart');
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    controller.updateSelection(
      TextSelection.collapsed(offset: document.length - 1),
      ChangeSource.local,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    controller.replaceText(
      controller.selection.baseOffset,
      0,
      'var a = 1;',
      const TextSelection.collapsed(offset: 15),
    );
    // A new line, as the system's text input types it.
    controller.replaceText(
      15,
      0,
      '\n',
      const TextSelection.collapsed(offset: 16),
    );
    await tester.pump();
    expect(
      document
          .queryChild(16)
          .node!
          .style
          .attributes[Attribute.codeBlock.key]
          ?.value,
      'dart',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    controller.replaceText(controller.selection.baseOffset, 0, 'after', null);
    await tester.pumpAndSettle();
    expect(
      stashDeltaToMarkdown(document.toDelta()),
      'note\n```dart\nvar a = 1;\n```\nafter',
    );
    // Read back as the same lines.
    expect(
      stashDeltaToMarkdown(
        stashMarkdownToDelta('note\n```dart\nvar a = 1;\n```\nafter'),
      ),
      'note\n```dart\nvar a = 1;\n```\nafter',
    );
  });

  test('code is told from prose and markdown', () {
    expect(
      StashEditorState.looksLikeCode('for the record I think\nwe ship'),
      isFalse,
    );
    expect(
      StashEditorState.looksLikeCode(
        '- item\n  - nested a\n  - nested b\n- two',
      ),
      isFalse,
    );
    expect(
      StashEditorState.looksLikeCode('const a = 1;\nconsole.log(a);'),
      isTrue,
    );
    expect(
      StashEditorState.looksLikeCode('def f(x):\n    return x * 2'),
      isTrue,
    );
    expect(
      StashEditorState.looksLikeCode('if (ready) {\n  start();\n}'),
      isTrue,
    );
  });

  testWidgets('a picture put in is undone at once, the space after it too', (
    tester,
  ) async {
    // As read from the file: nothing to undo of it.
    final document = Document.fromJson([
      {'insert': 'see\n'},
    ]);
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    final state = tester.state<StashEditorState>(find.byType(StashEditor));
    controller.updateSelection(
      const TextSelection.collapsed(offset: 3),
      ChangeSource.local,
    );
    state.insertCard('https://x.dev');
    await tester.pumpAndSettle();
    expect(document.toPlainText(), 'see\uFFFC \n');
    // The caret after it, typing on.
    expect(controller.selection, const TextSelection.collapsed(offset: 5));
    controller.undo();
    await tester.pumpAndSettle();
    expect(document.toPlainText(), 'see\n');
  });

  testWidgets('a click on a code block puts the caret after it', (
    tester,
  ) async {
    final document = Document()
      ..insert(0, 'before\n')
      ..insert(
        7,
        StashEmbeds.of(StashEmbeds.code, {'code': 'a\nb\nc', 'language': ''}),
      );
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    final block = find.byType(MarkdownCodeBlock);
    final box = tester.getRect(block);
    await tester.tapAt(Offset(box.center.dx, box.bottom - 4));
    await tester.pumpAndSettle();
    expect(controller.selection, const TextSelection.collapsed(offset: 9));
    expect(document.toPlainText().endsWith('\uFFFC\n\n'), isTrue);
  });

  testWidgets('files dragged in go where the pointer is, shown as they '
      'come', (tester) async {
    final document = Document()..insert(0, 'hello world');
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    controller.updateSelection(
      const TextSelection.collapsed(offset: 0),
      ChangeSource.local,
    );
    final editor = tester.state<StashEditorState>(find.byType(StashEditor));
    final quill = tester.getTopLeft(find.byType(QuillEditor));
    // Past the text's end, on its line.
    final over = quill + const Offset(300, 22);
    editor.fileDragOver(over, const []);
    await tester.pump();
    expect(find.byType(ColoredBox), findsWidgets);
    editor.fileDrop(over, const []);
    await tester.pumpAndSettle();
    expect(controller.selection, const TextSelection.collapsed(offset: 11));
  });

  testWidgets('the caret follows the text after the panel shows another '
      'stash (a new controller)', (tester) async {
    final focus = FocusNode();
    final store = StashStore(MemoryStashDisk());
    Widget editor(QuillController controller) => MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      home: Scaffold(
        body: StashEditor(
          controller: controller,
          store: store,
          ensureNote: () async => 1,
          focusNode: focus,
          autofocus: true,
        ),
      ),
    );
    await tester.pumpWidget(editor(StashEditor.controllerFor(Document())));
    await tester.pumpAndSettle();
    final next = StashEditor.controllerFor(Document());
    await tester.pumpWidget(editor(next));
    focus.requestFocus();
    await tester.pumpAndSettle();
    final caret = tester.state<StashCaretState>(find.byType(StashCaret));
    final start = caret.caretRect!.left;
    next.replaceText(0, 0, '321321', const TextSelection.collapsed(offset: 6));
    await tester.pump();
    expect(caret.caretRect!.left, greaterThan(start + 40));
    next.updateSelection(
      const TextSelection.collapsed(offset: 3),
      ChangeSource.local,
    );
    await tester.pump();
    expect(caret.caretRect!.left, lessThan(start + 60));
    expect(caret.caretRect!.left, greaterThan(start + 20));
  });

  testWidgets('pictures and files show above the text, each once', (
    tester,
  ) async {
    final document = Document()
      ..insert(0, 'a  b  c  d')
      ..insert(1, StashEmbeds.of(StashEmbeds.image, {'src': '1/a.png'}))
      ..insert(4, StashEmbeds.of(StashEmbeds.file, {'path': '1/x.pdf'}))
      ..insert(7, StashEmbeds.of(StashEmbeds.image, {'src': '1/a.png'}));
    final controller = StashEditor.controllerFor(document);
    expect(StashAttachment.of(document), const [
      StashAttachment.picture('1/a.png'),
      StashAttachment.file('1/x.pdf', 'x.pdf'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StashAttachments(
            controller: controller,
            store: StashStore(MemoryStashDisk()),
          ),
        ),
      ),
    );
    expect(find.text('x.pdf'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    // Another put in: shown at once; all gone, nothing shows.
    controller.replaceText(
      0,
      0,
      StashEmbeds.of(StashEmbeds.image, {'src': '1/b.png'}),
      null,
    );
    await tester.pump();
    expect(find.byType(Image), findsNWidgets(2));
    controller.replaceText(0, document.length - 1, '', null);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.text('x.pdf'), findsNothing);
  });

  test('polished, pictures and files go as their paths and come back', () {
    final slice = Delta()
      ..insert('see ')
      ..insert('this', {'bold': true})
      ..insert(' ')
      ..insert(StashEmbeds.of(StashEmbeds.image, {'src': '1/a.png'}).toJson())
      ..insert(' and ')
      ..insert(
        StashEmbeds.of(StashEmbeds.file, {
          'path': '1/b.pdf',
          'name': 'b.pdf',
        }).toJson(),
      );
    final asked = stashTextForModel(slice, (path) => '/stash/$path');
    expect(asked.text, 'see **this** [/stash/1/a.png] and [/stash/1/b.pdf]');

    // Put elsewhere, one left out: in its new place, the other after it.
    final back = stashTextFromModel(
      'Look at [/stash/1/a.png]: **this**.',
      asked.attachments,
      endsLine: false,
    );
    final ops = back.toList();
    expect(ops.first.data, 'Look at ');
    expect((ops[1].data! as Map).keys.single, StashEmbeds.image);
    expect(ops.any((op) => op.attributes?['bold'] == true), isTrue);
    expect((ops.last.data! as Map).keys.single, StashEmbeds.file);
    expect(back.toList().any((op) => op.data == '\n'), isFalse);
  });

  testWidgets('copied and pasted in a stash, pictures stay pictures; as '
      'text, their paths', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        } else if (call.method == 'Clipboard.getData') {
          return {'text': clipboard};
        } else if (call.method == 'Clipboard.hasStrings') {
          return {'value': clipboard != null};
        }
        return null;
      },
    );
    final document = Document.fromJson([
      {'insert': 'a '},
      {
        'insert': StashEmbeds.of(StashEmbeds.image, {
          'src': '/pics/a.png',
        }).toJson(),
      },
      {'insert': ' b\n'},
    ]);
    final controller = StashEditor.controllerFor(document);
    await _edit(tester, controller);
    controller.updateSelection(
      const TextSelection(baseOffset: 0, extentOffset: 5),
      ChangeSource.local,
    );
    // ignore: experimental_member_use
    controller.clipboardSelection(true);
    expect(clipboard, 'a @/pics/a.png b');

    controller.updateSelection(
      TextSelection.collapsed(offset: document.length - 1),
      ChangeSource.local,
    );
    // ignore: experimental_member_use
    await controller.clipboardPaste();
    await tester.pumpAndSettle();
    final pictures = document.toDelta().toList().where(
      (op) =>
          op.data is Map && (op.data! as Map).containsKey(StashEmbeds.image),
    );
    expect(pictures, hasLength(2));
  });
}

/// [document] in an editor, focused.
Future<FocusNode> _edit(WidgetTester tester, QuillController controller) async {
  final focus = FocusNode();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      home: Scaffold(
        body: StashEditor(
          controller: controller,
          store: StashStore(MemoryStashDisk()),
          ensureNote: () async => 1,
          focusNode: focus,
          autofocus: true,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  focus.requestFocus();
  await tester.pump();
  return focus;
}
