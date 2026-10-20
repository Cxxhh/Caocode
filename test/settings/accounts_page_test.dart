import 'package:caocode/forge/forge_accounts.dart';
import 'package:caocode/forge/forge_api.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/models/secret_store.dart';
import 'package:caocode/settings/pages/accounts_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../forge/forge_test.dart' show FakeForgeHttp;

void main() {
  late FakeForgeHttp http;
  late MemorySecretStore secrets;
  Object? kept;

  setUp(() {
    kept = null;
    secrets = MemorySecretStore();
    http = FakeForgeHttp()
      ..on(
        'GET',
        'https://api.github.com/user',
        (request) => request.headers['Authorization'] == 'Bearer good'
            ? {'login': 'leo', 'name': 'Leo'}
            : const ForgeResponse(401, '{"message":"Bad credentials"}'),
      )
      ..on(
        'POST',
        'https://github.com/login/device/code',
        (_) => {
          'device_code': 'dc',
          'user_code': 'ABCD-1234',
          'verification_uri': 'https://github.com/login/device',
          'interval': 5,
          'expires_in': 900,
        },
      )
      ..on(
        'POST',
        'https://github.com/login/oauth/access_token',
        (_) => {'access_token': 'good'},
      );
  });

  ForgeAccounts accountsWith({String githubClient = ''}) => ForgeAccounts(
    http: http,
    secrets: secrets,
    read: () => kept,
    write: (json) async => kept = json,
    githubClient: githubClient,
  );

  Future<void> pumpPage(WidgetTester tester, ForgeAccounts accounts) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        home: Scaffold(body: AccountsSettingsPage(accounts: accounts)),
      ),
    );
    await tester.pump();
  }

  testWidgets('signed in with a token, checked first; listed; signed out, '
      'its token deleted', (tester) async {
    final accounts = accountsWith();
    await pumpPage(tester, accounts);
    expect(find.text('GitHub'), findsOneWidget);
    expect(find.text('GitLab'), findsOneWidget);
    // No app registered: no browser sign-in.
    expect(find.text('Sign in with Browser'), findsNothing);

    await tester.tap(find.text('Use a Token…').first);
    await tester.pump();
    expect(find.text('Sign in to GitHub with a Token'), findsOneWidget);
    final token = find.byType(EditableText).at(1);
    await tester.enterText(token, 'bad');
    await tester.tap(find.text('Sign In'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('was not accepted'), findsOneWidget);
    expect(accounts.accounts, isEmpty);

    await tester.enterText(token, 'good');
    await tester.tap(find.text('Sign In'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Sign in to GitHub with a Token'), findsNothing);
    expect(find.text('leo (Leo)'), findsOneWidget);
    expect(find.textContaining('GitHub · github.com'), findsOneWidget);
    expect(await secrets.read('forge.github.com'), isNotNull);
    expect(kept, [
      {
        'kind': 'github',
        'host': 'github.com',
        'login': 'leo',
        'name': 'Leo',
        'via': 'token',
      },
    ]);

    await tester.tap(find.text('Sign Out'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sign out of GitHub account leo?'), findsOneWidget);
    await tester.tap(find.text('Sign Out').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(accounts.accounts, isEmpty);
    expect(await secrets.read('forge.github.com'), isNull);
    expect(find.text('leo (Leo)'), findsNothing);
  });

  testWidgets('signed in from the browser: the code shown, the account '
      'once it is entered', (tester) async {
    final accounts = accountsWith(githubClient: 'client');
    await pumpPage(tester, accounts);
    await tester.tap(find.text('Sign in with Browser'));
    await tester.pump();
    await tester.pump();
    expect(find.text('ABCD-1234'), findsOneWidget);
    expect(find.textContaining('Waiting for you'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    await tester.pump();
    expect(find.text('ABCD-1234'), findsNothing);
    expect(accounts.accountFor('github.com')?.via, ForgeSignIn.browser);
    expect(find.text('leo (Leo)'), findsOneWidget);
  });
}
