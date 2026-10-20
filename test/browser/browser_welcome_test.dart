import 'dart:convert';
import 'dart:io';

import 'package:caocode/browser/browser_bridge.dart';
import 'package:caocode/browser/browser_welcome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Made outside a test's fake time: its sockets are real.
  final bridge = BrowserBridge.instance;

  Future<void> open(WidgetTester tester, {VoidCallback? openSettings}) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showBrowserWelcome(
              context,
              openSettings: openSettings ?? () {},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('says what the agents do with the browser, and how to get it', (
    tester,
  ) async {
    var settings = 0;
    await open(tester, openSettings: () => settings++);
    expect(find.text('Agents can use your browser now'), findsOneWidget);
    expect(find.text('Only the tabs you share'), findsOneWidget);
    expect(find.text('Watch it work'), findsOneWidget);
    expect(find.text('Show it once'), findsOneWidget);
    expect(find.text('Add the extension'), findsOneWidget);
    expect(find.text('Open Store'), findsOneWidget);
    expect(find.text('Developer Mode Zip'), findsOneWidget);

    // Browser Settings closes it for the settings' page.
    await tester.tap(find.text('Browser Settings'));
    await tester.pump(const Duration(seconds: 1));
    expect(settings, 1);
    expect(find.text('Agents can use your browser now'), findsNothing);

    await tester.tap(find.text('open'));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.text('Got It'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Agents can use your browser now'), findsNothing);
  });

  testWidgets('the step turns to the browser once it connects', (tester) async {
    final temp = Directory('/tmp').createTempSync('bao-');
    BrowserBridge.socketFolder = temp.path;
    BrowserBridge.home = temp.path;
    addTearDown(() {
      BrowserBridge.socketFolder = null;
      BrowserBridge.home = null;
      temp.deleteSync(recursive: true);
    });
    await open(tester);
    expect(find.text('Add the extension'), findsOneWidget);

    await tester.runAsync(() async {
      await bridge.start();
      final socket = await Socket.connect(
        InternetAddress(
          BrowserBridge.socketPath,
          type: InternetAddressType.unix,
        ),
        0,
      );
      addTearDown(socket.destroy);
      for (final message in [
        {
          'type': 'hello',
          'origin': 'chrome-extension://${BrowserBridge.extensionIds.first}/',
        },
        {'type': 'hello', 'browser': 'Google Chrome', 'protocol': 1},
      ]) {
        final body = utf8.encode(jsonEncode(message));
        socket
          ..add(
            (ByteData(
              4,
            )..setUint32(0, body.length, Endian.little)).buffer.asUint8List(),
          )
          ..add(body);
      }
      await socket.flush();
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (bridge.browsers.isEmpty && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Google Chrome is connected'), findsOneWidget);
    expect(find.text('Open Store'), findsNothing);
    // Real sockets: let go outside the test's fake time.
    await tester.runAsync(bridge.stop);
  }, skip: !Platform.isMacOS);
}
