import 'package:caocode/ide/ide_explorer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Native directory reads need real I/O before an animated loading row can
/// settle under the widget test's fake clock.
Future<void> settleFileExplorers(WidgetTester tester) async {
  await tester.pump();
  bool loading() => tester
      .widgetList<IdeExplorer>(find.byType(IdeExplorer, skipOffstage: false))
      .any((explorer) => explorer.controller.rows.any((row) => row.loading));
  // Let I/O finish in the real zone, then flush its listeners in the fake
  // zone. Awaiting an already pending controller future in runAsync would
  // wait for fake-zone callbacks that cannot run until runAsync returns.
  for (var attempt = 0; loading() && attempt < 200; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(loading(), false, reason: 'Native directory reads must finish');
  await tester.pumpAndSettle();
}
