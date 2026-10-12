import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/link_host.dart';
import 'package:baocode/link/qr_view.dart';
import 'package:baocode/settings/pages/mobile_page.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../link/fake_link_platform.dart';

void main() {
  testWidgets('shows a code to pair with, then the safety code to compare', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final platform = FakeLinkPlatform();
    final host = LinkHost(workspace: Workspace.mock(), platform: platform);
    addTearDown(host.dispose);
    await host.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MobileSettingsPage(host: host)),
      ),
    );
    await tester.pump();
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('192.168.1.5:47100'), findsOneWidget);
    expect(find.text('Not Available Yet'), findsOneWidget);

    await tester.tap(find.text('Show QR Code'));
    await tester.pump();
    await tester.pump();
    expect(host.enabled, isTrue);
    expect(find.byType(QrView), findsOneWidget);
    expect(find.text('Listening on port 47100'), findsOneWidget);

    // A phone scans it.
    final phone = LinkIdentity.generate();
    final (a, b) = MemoryLinkSocket.pair();
    platform.incoming.add(b);
    final offer = host.offer!;
    var answered = false;
    () async {
      final channel = await SecureChannel.connect(
        a,
        identity: phone,
        serverKey: offer.key,
      );
      await LinkPeer(channel).call(LinkMethods.hello, {
        'name': 'iPhone',
        'token': encodeKey(offer.token),
      });
      answered = true;
    }();
    for (var i = 0; i < 20 && !answered; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(answered, isTrue);
    final code = safetyCode(offer.key, phone.publicKey);
    expect(find.text('Compare with iPhone'), findsOneWidget);
    expect(find.text(code.join('  ')), findsOneWidget);

    await tester.tap(find.text("Codes Don't Match"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(host.pending, isNull);
    expect(find.byType(QrView), findsNothing);
    // The phone let go, once told.
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a phone that found it nearby is allowed here', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final platform = FakeLinkPlatform();
    final host = LinkHost(workspace: Workspace.mock(), platform: platform);
    addTearDown(host.dispose);
    await host.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MobileSettingsPage(host: host)),
      ),
    );
    await tester.pump();
    expect(find.text('Find on the Local Network'), findsOneWidget);
    await tester.tap(find.text('Show QR Code'));
    await tester.pump();
    await tester.pump();

    final phone = LinkIdentity.generate();
    final (a, b) = MemoryLinkSocket.pair();
    platform.incoming.add(b);
    final key = host.offer!.key;
    Object? confirmed;
    () async {
      final channel = await SecureChannel.connect(
        a,
        identity: phone,
        serverKey: key,
      );
      final peer = LinkPeer(channel);
      await peer.call(LinkMethods.hello, {'name': 'Pixel', 'request': true});
      confirmed = await peer.call(LinkMethods.confirm);
    }();
    for (var i = 0; i < 20 && host.pending?.needsApproval != true; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();
    expect(find.text('Pixel Wants to Pair'), findsOneWidget);
    expect(
      find.text(safetyCode(key, phone.publicKey).join('  ')),
      findsOneWidget,
    );
    await tester.tap(find.text('Allow'));
    for (var i = 0; i < 20 && confirmed == null; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(confirmed, isA<Map>());
    expect(host.phones.single.name, 'Pixel');
    await tester.pump();
    expect(find.text('Paired with Pixel.'), findsOneWidget);
  });
}
