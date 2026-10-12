import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/widgets/chat_item_view.dart';
import 'package:baocode/chat/widgets/step_header.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> showThought(WidgetTester tester, ThinkingItem item) async {
  var expanded = false;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => ChatItemView(
            item: item,
            expanded: expanded,
            onToggle: () => setState(() => expanded = !expanded),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('restored summary shows its heading and opens its details', (
    tester,
  ) async {
    const text =
        '**检查串口配置**\n\n核对共享端口和 TCP 参数。\n\n'
        '**修正线程回调**\n\n将控制操作交给后台线程。';
    const item = ThinkingItem(
      text: text,
      tokens: 0,
      summarized: true,
      streaming: false,
    );
    await showThought(tester, item);
    expect(find.text('检查串口配置', findRichText: true), findsOneWidget);
    expect(find.textContaining('Thought', findRichText: true), findsNothing);
    expect(find.textContaining('1s', findRichText: true), findsNothing);
    expect(tester.widget<StepHeader>(find.byType(StepHeader)).running, isFalse);
    expect(find.textContaining('核对共享端口'), findsNothing);

    await tester.tap(find.byType(StepHeader));
    await tester.pumpAndSettle();
    expect(find.textContaining('核对共享端口和 TCP 参数'), findsOneWidget);
    expect(find.textContaining('修正线程回调'), findsOneWidget);
    expect(find.textContaining('将控制操作交给后台线程'), findsOneWidget);
    expect(chatItemPlainText(item, expanded: true), contains('修正线程回调'));
    expect(chatItemPlainText(item, expanded: true), isNot(contains('**')));
  });

  testWidgets('plain summary has a short heading and expandable details', (
    tester,
  ) async {
    const item = ThinkingItem(
      text: '检查接口回调\n\n避免控制服务阻塞主界面。',
      tokens: 0,
      summarized: true,
      streaming: false,
    );
    await showThought(tester, item);
    expect(find.text('检查接口回调', findRichText: true), findsOneWidget);
    expect(find.textContaining('Thought', findRichText: true), findsNothing);
    await tester.tap(find.byType(StepHeader));
    await tester.pumpAndSettle();
    expect(find.text('避免控制服务阻塞主界面。'), findsOneWidget);
    expect(chatItemPlainText(item), '检查接口回调');
  });

  testWidgets('completed thought with unknown duration never starts a clock', (
    tester,
  ) async {
    await showThought(
      tester,
      const ThinkingItem(text: '已完成的思考。', tokens: 0, streaming: false),
    );
    expect(find.text('Thought', findRichText: true), findsOneWidget);
    expect(tester.widget<StepHeader>(find.byType(StepHeader)).running, isFalse);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Thought', findRichText: true), findsOneWidget);
    expect(find.textContaining('1s', findRichText: true), findsNothing);
    expect(find.textContaining('Thinking', findRichText: true), findsNothing);
  });
}
