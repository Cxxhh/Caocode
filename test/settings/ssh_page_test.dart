import 'dart:async';

import 'package:bao_remote/client.dart';
import 'package:caocode/ide/ide_input.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/models/secret_store.dart';
import 'package:caocode/remote/ssh_host.dart';
import 'package:caocode/remote/ssh_passwords.dart';
import 'package:caocode/settings/pages/ssh_page.dart';
import 'package:caocode/workspace/preference_store.dart';
import 'package:caocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Settings → SSH Servers: the servers the app's form edits, added,
/// edited and removed there; ~/.ssh/config's listed as they are.
void main() {
  final previous = SshHosts.instance;
  late Workspace workspace;
  late MemorySecretStore secrets;

  setUp(() {
    secrets = MemorySecretStore();
    SshHosts.instance = SshHosts(
      passwords: SshPasswords(secrets: secrets),
      // Never connected here.
      connect: (target, {onProgress}) => Completer<SshConnection>().future,
    );
    workspace = Workspace(preferences: MemoryPreferenceStore())
      ..saveSshServer(
        'prod',
        const SshServer(
          hostName: '10.0.0.5',
          user: 'deploy',
          auth: SshAuth.password,
          jump: 'bastion',
          core: SshCore.builtin,
        ),
        name: 'Production',
      )
      ..addSshHost('me@typed')
      ..addSshHost('bastion');
    SshHosts.instance.savedServers = () => workspace.sshServers;
  });
  tearDown(() => SshHosts.instance = previous);

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        home: Scaffold(
          body: SshSettingsPage(
            workspace: workspace,
            configHosts: () async => ['bastion', 'gpu'],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the servers as saved; ~/.ssh/config\'s apart, not edited '
      'here', (tester) async {
    await pumpPage(tester);
    expect(find.text('Production'), findsOneWidget);
    expect(
      find.text(
        'Not connected · deploy@10.0.0.5 · Password · through bastion · '
        'Core: Built-in',
      ),
      findsOneWidget,
    );
    expect(find.text('Not connected · As typed'), findsOneWidget);
    expect(find.text('Hosts of ~/.ssh/config'), findsOneWidget);
    // bastion is ~/.ssh/config's: listed there alone, with no Edit.
    expect(find.text('bastion'), findsOneWidget);
    expect(find.text('gpu'), findsOneWidget);
    expect(find.text('Edit…'), findsNWidgets(2));
  });

  testWidgets('edited with the form: what it saves is kept', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Edit…').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit Production'), findsOneWidget);
    await tester.tap(find.text('Automatic').last);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(workspace.sshServers['prod']!.core, SshCore.auto);
    expect(find.textContaining('Core: Automatic'), findsOneWidget);
  });

  testWidgets('added from the page', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('Add Server…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is IdeInputBox && widget.semanticsLabel == 'Host',
      ),
      'root@new.example',
    );
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is IdeInputBox && widget.semanticsLabel == 'Password',
      ),
      'hunter2',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(workspace.sshServers['root@new.example']!.hostName, 'new.example');
    expect(
      await secrets.read(SshPasswords.serverId('root@new.example')),
      'hunter2',
    );
    expect(find.text('root@new.example'), findsOneWidget);
  });

  testWidgets('removed, once asked: its password with it', (tester) async {
    await secrets.write(SshPasswords.serverId('prod'), 'secret');
    await pumpPage(tester);
    await tester.tap(find.text('Remove').first);
    await tester.pumpAndSettle();
    expect(find.text('Remove Production?'), findsOneWidget);
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(workspace.sshServers, isNot(contains('prod')));
    expect(find.text('Production'), findsNothing);
    expect(await secrets.read(SshPasswords.serverId('prod')), isNull);
  });
}
