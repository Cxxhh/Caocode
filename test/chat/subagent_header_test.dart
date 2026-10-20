import 'package:caocode/chat/agent_view.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:caocode/theme/codicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('subagent header keeps its back button without a chevron', (
    tester,
  ) async {
    final depths = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SubagentHeader(
            trail: const ['Inspect files'],
            onBack: depths.add,
          ),
        ),
      ),
    );

    expect(find.text('Inspect files'), findsOneWidget);
    expect(find.byIcon(Codicons.arrowLeft), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);

    await tester.tap(find.text('Conversation'));
    expect(depths, [0]);
  });

  testWidgets('nested subagent titles still navigate without chevrons', (
    tester,
  ) async {
    final depths = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SubagentHeader(
            trail: const ['First', 'Second', 'Current'],
            onBack: depths.add,
          ),
        ),
      ),
    );

    expect(find.text('Current'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);

    await tester.tap(find.text('First'));
    await tester.tap(find.text('Second'));
    await tester.tap(find.text('Conversation'));
    expect(depths, [1, 2, 2]);
  });
}
