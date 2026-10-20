import 'package:caocode/forge/forge_accounts.dart';
import 'package:caocode/forge/forge_ref.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/models/secret_store.dart';
import 'package:caocode/stash/stash_disk.dart';
import 'package:caocode/stash/stash_forge.dart';
import 'package:caocode/stash/stash_forge_view.dart';
import 'package:caocode/stash/stash_note.dart';
import 'package:caocode/stash/stash_store.dart';
import 'package:caocode/theme/codicons.dart';
import 'package:caocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../forge/forge_test.dart' show FakeForgeHttp;

const issueUrl = 'https://github.com/o/r/issues/3';
const pullUrl = 'https://github.com/o/r/pull/7';

void main() {
  late FakeForgeHttp http;
  late StashStore store;
  late StashForge forge;
  var issueState = 'open';

  Map<String, Object?> issue(int number, String title) => {
    'number': number,
    'title': title,
    'state': 'open',
    'user': {'login': 'ann'},
  };

  setUp(() {
    issueState = 'open';
    http = FakeForgeHttp()
      ..on('GET', 'https://api.github.com/user', (_) => {'login': 'leo'})
      ..on(
        'GET',
        'https://api.github.com/repos/o/r/issues/3',
        (_) => {
          'number': 3,
          'title': 'Uploads fail',
          'state': issueState,
          'labels': [
            {'name': 'bug', 'color': 'd73a4a'},
          ],
        },
      )
      ..on(
        'GET',
        'https://api.github.com/repos/o/r/pulls/7',
        (_) => {'number': 7, 'title': 'Retry uploads', 'state': 'open'},
      )
      ..on(
        'GET',
        'https://api.github.com/search/issues',
        (_) => {
          'items': [issue(3, 'Uploads fail'), issue(4, 'Dark mode')],
        },
      )
      ..on(
        'POST',
        'https://api.github.com/repos/o/r/issues/3/comments',
        (_) => {},
      )
      ..on('PATCH', 'https://api.github.com/repos/o/r/issues/3', (_) {
        issueState = 'closed';
        return {};
      });
  });

  /// The store, the forge signed in to github.com, [body]'s stash.
  Future<StashNote> setUpStash(String body) async {
    final accounts = ForgeAccounts(http: http, secrets: MemorySecretStore());
    await accounts.signInWithToken(ForgeKind.github, 'github.com', 't');
    store = StashStore(MemoryStashDisk());
    await store.load();
    forge = StashForge(
      store: store,
      workspace: Workspace.mock(),
      accounts: accounts,
      remotes: (folder) async => switch (folder) {
        '~/code/caocode' => ['git@github.com:o/r.git'],
        _ => const [],
      },
    );
    final note = await store.create(body: body);
    final links = ForgeRef.allIn(body).map((ref) => ref.url.toString());
    await store.update(note.id, (note) {
      for (final url in links) {
        note.issues.add(StashIssueLink(url: url));
      }
    }, touch: false);
    return store.byId(note.id)!;
  }

  Widget app(Widget child) => MaterialApp(
    localizationsDelegates: const [AppLocalizations.delegate],
    home: Scaffold(body: child),
  );

  Iterable<String> sent() =>
      http.requests.where((r) => r.method != 'GET').map((r) => r.method);

  testWidgets('a stash\'s issues and pull requests, as they are now; one '
      'closed asks whether the stash is done', (tester) async {
    final note = await setUpStash('Fix $issueUrl, see $pullUrl');
    await tester.pumpWidget(
      app(
        ListenableBuilder(
          listenable: store,
          builder: (context, _) =>
              StashIssueSection(forge: forge, note: store.byId(note.id)!),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Uploads fail'), findsOneWidget);
    expect(find.text('o/r#3'), findsOneWidget);
    expect(find.text('bug'), findsOneWidget);
    expect(find.text('Retry uploads'), findsOneWidget);
    expect(find.byIcon(Codicons.gitPullRequest), findsOneWidget);
    expect(find.textContaining('was closed'), findsNothing);

    issueState = 'closed';
    await forge.refresh(force: true);
    await tester.pump();
    expect(find.byIcon(Codicons.issueClosed), findsWidgets);
    expect(
      find.text('o/r#3 was closed. Is this stash done too?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Mark Done'));
    await tester.pump();
    await tester.pump();
    expect(store.byId(note.id)!.status, StashStatus.done);
    expect(store.byId(note.id)!.issueOf(issueUrl)!.answered, isTrue);
    expect(find.textContaining('was closed'), findsNothing);
    expect(sent(), isEmpty);
  });

  testWidgets('what goes to the issue is shown, what should not go out '
      'pointed out, and nothing is sent until the user says', (tester) async {
    final note = await setUpStash('Fix $issueUrl');
    await forge.refresh(force: true);
    final link = store.byId(note.id)!.issueOf(issueUrl)!;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showStashWriteDialog(
              context,
              forge: forge,
              note: note,
              link: link,
              draft: 'Fixed.',
            ),
            child: const Text('write'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('write'));
    await tester.pump();
    expect(find.text('Comment on o/r#3'), findsOneWidget);
    expect(find.text('Posted as leo on github.com.'), findsOneWidget);
    expect(find.text('Comment'), findsOneWidget);

    await tester.enterText(
      find.byType(EditableText),
      'Fixed in /Users/leo/app/upload.dart',
    );
    await tester.pump();
    expect(find.textContaining('paths on this computer'), findsOneWidget);
    expect(find.text('  /Users/leo/app/upload.dart'), findsOneWidget);
    expect(sent(), isEmpty);

    await tester.enterText(find.byType(EditableText), 'Fixed in #7.');
    await tester.tap(find.text('Close the issue too'));
    await tester.pump();
    expect(find.textContaining('paths on this computer'), findsNothing);
    await tester.tap(find.text('Comment and Close'));
    await tester.pump();
    await tester.pump();
    expect(sent(), ['POST', 'PATCH']);
    expect(http.requests.firstWhere((r) => r.method == 'POST').json, {
      'body': 'Fixed in #7.',
    });
    expect(find.text('Comment on o/r#3'), findsNothing);
    expect(store.byId(note.id)!.issueOf(issueUrl)!.answered, isTrue);
  });

  testWidgets('issues imported: the project\'s repository\'s listed, those '
      'checked made stashes, those imported before marked', (tester) async {
    await setUpStash('Fix $issueUrl');
    List<StashNote>? imported;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => imported = await showStashImportDialog(
              context,
              forge: forge,
              project: '~/code/caocode',
            ),
            child: const Text('import'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('import'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(find.text('o/r · caocode'), findsOneWidget);
    expect(find.text('Dark mode'), findsOneWidget);
    // In Stash #1 already.
    expect(find.text('o/r#3 · @ann · in Stash #1'), findsOneWidget);
    final search = http.requests.lastWhere(
      (r) => r.url.path == '/search/issues',
    );
    expect(
      search.url.queryParameters['q'],
      'repo:o/r is:issue is:open assignee:@me',
    );

    await tester.tap(find.text('Dark mode'));
    await tester.pump();
    await tester.tap(find.text('Import 1'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    final note = imported!.single;
    expect(note.title, 'Dark mode');
    expect(note.project, '~/code/caocode');
    expect(note.issues.single.url, 'https://github.com/o/r/issues/4');
    expect(store.notes, hasLength(2));
    expect(sent(), isEmpty);
  });
}
