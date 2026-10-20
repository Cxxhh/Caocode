import 'package:bao_remote/client.dart';
import 'package:caocode/ide/ide_input.dart';
import 'package:caocode/remote/ssh_server_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Future<SshServerFormResult?>> open(
    WidgetTester tester, {
    String? host,
    String? address,
    SshServer? server,
    bool hasPassword = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final result = showSshServerForm(
      context,
      host: host,
      address: address,
      server: server,
      hasPassword: hasPassword,
      jumps: const ['bastion', 'dev'],
    );
    await tester.pumpAndSettle();
    return result;
  }

  Finder input(String label) => find.byWidgetPredicate(
    (widget) => widget is IdeInputBox && widget.semanticsLabel == label,
  );

  testWidgets('an address pasted is split up; saved with its password, '
      'named by it', (tester) async {
    final result = await open(tester);
    expect(find.text('Add SSH Server'), findsOneWidget);
    await tester.enterText(input('Host'), 'admin@10.1.2.3:2200');
    await tester.pump();
    expect(find.text('10.1.2.3'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
    expect(find.text('2200'), findsOneWidget);
    await tester.enterText(input('Password'), 'hunter2');
    await tester.tap(find.text('Save and Connect'));
    await tester.pumpAndSettle();
    final saved = (await result)!;
    expect(saved.host, 'admin@10.1.2.3:2200');
    expect(
      saved.server,
      const SshServer(
        hostName: '10.1.2.3',
        port: 2200,
        user: 'admin',
        auth: SshAuth.password,
      ),
    );
    expect(saved.password, 'hunter2');
    expect(saved.connect, isTrue);
  });

  testWidgets('what is missing is said, and nothing saved', (tester) async {
    final result = await open(tester);
    await tester.tap(find.text('Private Key'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text("Enter the server's domain or IP"), findsOneWidget);
    expect(find.text('Choose the private key file'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('edited: the host it is known as kept, its password left '
      'as it was when not typed', (tester) async {
    final result = await open(
      tester,
      host: 'root@old',
      server: const SshServer(
        hostName: 'old',
        user: 'root',
        auth: SshAuth.password,
      ),
      hasPassword: true,
    );
    expect(find.text('Edit root@old'), findsOneWidget);
    expect(find.text('Saved: leave empty to keep it'), findsOneWidget);
    await tester.enterText(input('Host'), 'new.example.com');
    // A jump picked from the menu.
    await tester.tap(find.text('None: connect directly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bastion').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final saved = (await result)!;
    expect(saved.host, 'root@old');
    expect(saved.server.hostName, 'new.example.com');
    expect(saved.server.jump, 'bastion');
    expect(saved.password, isNull);
    expect(saved.connect, isFalse);
  });

  testWidgets('a host typed in the picker starts the form', (tester) async {
    final result = await open(tester, address: 'me@box');
    expect(find.text('box'), findsOneWidget);
    expect(find.text('me'), findsOneWidget);
    // How it signs in: the first of the two.
    await tester.tap(find.text('Automatic').first);
    await tester.pump();
    expect(find.textContaining('ssh-agent'), findsOneWidget);
    await tester.tap(find.text('Save and Connect'));
    await tester.pumpAndSettle();
    final saved = (await result)!;
    expect(saved.host, 'me@box');
    expect(saved.server.auth, SshAuth.auto);
    expect(saved.server.core, SshCore.auto);
    expect(saved.password, isNull);
  });

  testWidgets('the core: automatic at first, as picked, said what it '
      'does', (tester) async {
    final result = await open(
      tester,
      host: 'prod',
      server: const SshServer(hostName: 'prod.example', core: SshCore.cli),
    );
    expect(find.textContaining('installed there if it has none'), findsOne);
    await tester.tap(find.text('Built-in'));
    await tester.pump();
    expect(find.textContaining('upstreams of Settings'), findsOne);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await result)!.server.core, SshCore.builtin);
  });
}
