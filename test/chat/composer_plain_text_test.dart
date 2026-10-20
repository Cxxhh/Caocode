import 'package:caocode/chat/chat_session.dart';
import 'package:caocode/chat/composer/composer.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<QuillController> pumpComposer(WidgetTester tester) async {
    final session = ChatSession(historyCount: 0);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: Scaffold(
          body: ChatComposer(session: session, draft: session.draft),
        ),
      ),
    );
    await tester.pump();
    final editor = tester.widget<QuillEditor>(find.byType(QuillEditor));
    editor.focusNode.requestFocus();
    await tester.pump();
    editor.controller.replaceText(
      0,
      0,
      'hello',
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await tester.pump();
    return editor.controller;
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    const modifier = LogicalKeyboardKey.metaLeft;
    await tester.sendKeyDownEvent(modifier);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(modifier);
    await tester.pumpAndSettle();
  }

  final shortcuts = <(String, LogicalKeyboardKey, bool)>[
    ('header 1', LogicalKeyboardKey.digit1, false),
    ('header 2', LogicalKeyboardKey.digit2, false),
    ('header 6', LogicalKeyboardKey.digit6, false),
    ('bold', LogicalKeyboardKey.keyB, false),
    ('italic', LogicalKeyboardKey.keyI, false),
    ('underline', LogicalKeyboardKey.keyU, false),
    ('inline code', LogicalKeyboardKey.backquote, false),
    ('strike-through', LogicalKeyboardKey.keyS, true),
    ('quote', LogicalKeyboardKey.keyB, true),
    ('bullet list', LogicalKeyboardKey.keyL, true),
    ('numbered list', LogicalKeyboardKey.keyO, true),
    ('check list', LogicalKeyboardKey.keyC, true),
    ('indent', LogicalKeyboardKey.keyM, false),
  ];

  testWidgets('a style put on the text by other means is not taken', (
    tester,
  ) async {
    final controller = await pumpComposer(tester);
    controller
      ..formatSelection(Attribute.h2)
      ..formatSelection(Attribute.bold)
      ..formatText(0, 0, Attribute.italic);
    await tester.pump();
    final ops = controller.document.toDelta().toList();
    expect(ops.where((op) => op.attributes != null), isEmpty);
  });

  // Quill reads the platform once, for all its shortcuts: macOS's (⌘).
  for (final (name, key, shift) in shortcuts) {
    testWidgets(
      'Quill\'s $name shortcut leaves the text plain',
      (tester) async {
        final controller = await pumpComposer(tester);
        await press(tester, key, shift: shift);
        final ops = controller.document.toDelta().toList();
        expect(ops.where((op) => op.attributes != null), isEmpty);
        expect(controller.document.toPlainText(), 'hello\n');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );
  }
}
