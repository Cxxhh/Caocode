import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/chat/composer/composer_embeds.dart';
import 'package:caocode/chat/composer/composer_files.dart';
import 'package:caocode/chat/widgets/text_preview.dart';
import 'package:caocode/chat/widgets/user_message_bubble.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:caocode/theme/codicons.dart';

void main() {
  final pasted = PastedText(
    number: 1,
    text: [for (var i = 1; i <= 548; i++) 'UPDATE t SET a = $i;'].join('\n'),
  );

  Future<int Function()> pump(WidgetTester tester) async {
    var edits = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: UserMessageBubble(
            text: '${pasted.reference} 去掉注释。${codeAppendix([pasted])}',
            onEdit: () => edits++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return () => edits;
  }

  testWidgets('a click on a sent paste\'s tag shows all of it, '
      'not the message\'s editor', (tester) async {
    final edits = await pump(tester);
    await tester.tap(find.byType(ComposerPastedTextChip));
    await tester.pumpAndSettle();

    expect(edits(), 0);
    expect(find.byType(TextPreview), findsOneWidget);
    expect(find.text('Pasted text #1'), findsWidgets);
    // Its first lines; the last as it scrolls into view.
    expect(find.text('UPDATE t SET a = 1;'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('UPDATE t SET a = 548;'),
      find.byType(ListView),
      const Offset(0, -2000),
    );
    expect(find.text('548'), findsOneWidget);

    // Esc closes it.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(TextPreview), findsNothing);

    // The rest of the message still opens it.
    final text = tester.getRect(
      find
          .descendant(
            of: find.byType(UserMessageBubble),
            matching: find.byType(RichText),
          )
          .first,
    );
    await tester.tapAt(text.centerRight - const Offset(8, 0));
    await tester.pumpAndSettle();
    expect(edits(), 1);
  });

  testWidgets('copies all of it', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await pump(tester);
    await tester.tap(find.byType(ComposerPastedTextChip));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(TextPreview),
        matching: find.byIcon(Codicons.copy),
      ),
    );
    await tester.pump();
    expect(copied, pasted.text);
    await tester.pump(const Duration(seconds: 2));
  });
}
