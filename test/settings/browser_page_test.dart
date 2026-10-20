import 'dart:io';

import 'package:caocode/browser/browser_bridge.dart';
import 'package:caocode/browser/browser_tools.dart' show BrowserHistory;
import 'package:caocode/settings/pages/browser_page.dart';
import 'package:caocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory data;
  late UserSettings settings;

  setUp(() async {
    data = await Directory.systemTemp.createTemp('caocode-browser-page');
    settings = UserSettings(p.join(data.path, 'settings.json'));
    await settings.load();
    // Turned off, the host's manifests go: a test's own, not the user's.
    BrowserBridge.home = data.path;
    BrowserHistory.folderOverride = p.join(data.path, 'history');
  });

  tearDown(() async {
    BrowserBridge.instance.enabled = true;
    BrowserBridge.home = null;
    BrowserHistory.folderOverride = null;
    BrowserHistory.instance.detailed = false;
    settings.dispose();
    await data.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100; i++) {
      if (done()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    fail('timed out');
  }

  testWidgets(
    'the switch is kept in settings.json, and the extension is there to get',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BrowserSettingsPage(settings: settings)),
        ),
      );
      await tester.pump();
      expect(find.text('Chrome Web Store'), findsOneWidget);
      expect(find.text('Install Manually (Developer Mode)'), findsOneWidget);
      expect(find.text('Open Store'), findsOneWidget);
      expect(find.text('Download Zip'), findsOneWidget);
      if (!Platform.isMacOS) return;

      // Never connected: it says to get the extension.
      expect(find.text('No browser has connected yet'), findsOneWidget);

      await tester.tap(find.text('Let Agents Use the Browser'));
      await settle(tester, () => settings[BrowserBridge.settingKey] == false);
      expect(BrowserBridge.instance.enabled, isFalse);
      await tester.pump();
      expect(find.text('Status'), findsNothing);

      await tester.tap(find.text('Let Agents Use the Browser'));
      await settle(
        tester,
        () => !settings.values.containsKey(BrowserBridge.settingKey),
      );
      expect(BrowserBridge.instance.enabled, isTrue);
      await tester.pump();

      // The debugging history: kept with the browsers in use, detailed
      // when asked.
      expect(find.text('Debugging history'), findsOneWidget);
      expect(find.text('Using 0 B'), findsOneWidget);
      await tester.tap(find.text('Detailed history'));
      await settle(tester, () => settings[BrowserHistory.detailedKey] == true);
      expect(BrowserHistory.instance.detailed, isTrue);
      await tester.tap(find.text('Detailed history'));
      await settle(
        tester,
        () => !settings.values.containsKey(BrowserHistory.detailedKey),
      );
      expect(BrowserHistory.instance.detailed, isFalse);
    },
  );

  testWidgets('a history grown large is said over the pages, and cleared', (
    tester,
  ) async {
    // A gigabyte, sparse.
    final file = File(p.join(data.path, 'history', '2026-10-17', 'a.jsonl'))
      ..createSync(recursive: true);
    await tester.runAsync(() async {
      final open = file.openSync(mode: FileMode.write);
      open
        ..setPositionSync(BrowserHistory.warnSize)
        ..writeByteSync(10)
        ..closeSync();
    });
    final history = BrowserHistory.instance..start();
    await settle(tester, () => history.tooLarge);
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              BrowserHistoryNotice(open: () => opened = true),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    expect(
      find.text("The browser's debugging history takes 1.0 GB"),
      findsOneWidget,
    );
    await tester.tap(find.text('Browser settings'));
    expect(opened, isTrue);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Clear the debugging history?'), findsOneWidget);
    await tester.tap(find.text('Clear').last);
    await settle(tester, () => !history.tooLarge);
    await tester.pump();
    expect(file.existsSync(), isFalse);
    expect(find.text('Browser settings'), findsNothing);
  });
}
