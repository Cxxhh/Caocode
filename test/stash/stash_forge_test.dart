import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/forge/forge_accounts.dart';
import 'package:caocode/forge/forge_api.dart';
import 'package:caocode/forge/forge_ref.dart';
import 'package:caocode/models/secret_store.dart';
import 'package:caocode/stash/stash_disk.dart';
import 'package:caocode/stash/stash_forge.dart';
import 'package:caocode/stash/stash_note.dart';
import 'package:caocode/stash/stash_store.dart';
import 'package:caocode/stash/stash_threads.dart';
import 'package:caocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import '../forge/forge_test.dart' show FakeForgeHttp;

const issueUrl = 'https://github.com/o/r/issues/3';
const pullUrl = 'https://github.com/o/r/pull/7';

void main() {
  late FakeForgeHttp http;
  late ForgeAccounts accounts;
  late StashStore store;
  late StashForge forge;
  var issueState = 'open';

  setUp(() async {
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
        (_) => {
          'number': 7,
          'title': 'Retry uploads',
          'state': 'open',
          'draft': false,
        },
      )
      ..on(
        'POST',
        'https://api.github.com/repos/o/r/issues/3/comments',
        (_) => {},
      )
      ..on('PATCH', 'https://api.github.com/repos/o/r/issues/3', (request) {
        issueState = 'closed';
        return {};
      });
    accounts = ForgeAccounts(http: http, secrets: MemorySecretStore());
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
  });

  tearDown(() => forge.dispose());

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('a link in its text links the stash to the issue, asked of GitHub '
      'and kept with the link', () async {
    final note = await store.create(body: 'Fix this: $issueUrl please');
    forge.start();
    await settle();
    final link = store.byId(note.id)!.issues.single;
    expect(link.url, issueUrl);
    expect(link.title, 'Uploads fail');
    expect(link.state, 'open');
    expect(forge.itemOf(issueUrl)?.labels.single.name, 'bug');
    // In its file too, for when it cannot be asked.
    expect(StashNote.decode(note.id, store.byId(note.id)!.encode()).issues, [
      link,
    ]);
  });

  test('closed while the stash is not done, it asks; done with the issue '
      'still open, it asks to say so there, and writes only then', () async {
    final note = await store.create(body: issueUrl);
    forge.start();
    await settle();
    expect(forge.closedIssues(store.byId(note.id)!), isEmpty);

    issueState = 'closed';
    await forge.refresh(force: true);
    await settle();
    expect(forge.closedIssues(store.byId(note.id)!).single.url, issueUrl);
    await forge.answer(note.id, [issueUrl]);
    expect(forge.closedIssues(store.byId(note.id)!), isEmpty);

    // Opened again: the question is new.
    issueState = 'open';
    await forge.refresh(force: true);
    await settle();
    await store.update(note.id, (note) => note.status = StashStatus.done);
    expect(forge.openIssues(store.byId(note.id)!).single.url, issueUrl);
    final writes = http.requests.where((r) => r.method != 'GET').length;
    expect(writes, 0);

    await forge.write(note.id, issueUrl, text: 'Fixed in #7', close: true);
    final sent = http.requests.where((r) => r.method != 'GET').toList();
    expect(sent.map((r) => r.method), ['POST', 'PATCH']);
    expect(sent.first.json, {'body': 'Fixed in #7'});
    await settle();
    expect(forge.openIssues(store.byId(note.id)!), isEmpty);
    expect(store.byId(note.id)!.issueOf(issueUrl)?.state, 'closed');
  });

  test('what should not go out is found', () {
    expect(
      StashForge.sensitive(
        'see /Users/leo/app/a.dart with sk-ant-0123456789abcdefghij',
      ),
      ['/Users/leo/app/a.dart', 'sk-ant-0123456789abcdefghij'],
    );
    expect(StashForge.sensitive('Fixed in #7.'), isEmpty);
  });

  test('imported: a stash each, titled, a card of the issue and its text; '
      'once', () async {
    final repos = await forge.repositories();
    expect(repos.single.repo.path, 'o/r');
    expect(repos.single.project.path, '~/code/caocode');
    final item = ForgeItem(
      ref: ForgeRef.parse(issueUrl)!,
      title: 'Uploads fail [503]',
      state: ForgeState.open,
      body: 'They fail on 503.',
    );
    final notes = await forge.import([item], project: '~/code/caocode');
    final note = notes.single;
    expect(note.title, 'Uploads fail [503]');
    expect(note.project, '~/code/caocode');
    expect(
      note.body,
      '[o/r#3 Uploads fail \\[503\\]]($issueUrl "card")\n\n'
      'They fail on 503.',
    );
    expect(note.issues.single.url, issueUrl);
    expect(forge.stashOf(issueUrl)?.id, note.id);
    expect((await forge.import([item])).single.id, note.id);
    expect(store.notes, hasLength(1));
  });

  test('the pull requests a conversation links to', () {
    expect(
      stashPullsIn([
        const UserMessageItem(text: 'see $pullUrl'),
        const AssistantTextItem('Opened $pullUrl and read $issueUrl.'),
        const ToolCallItem(
          kind: ToolKind.command,
          target: 'gh pr create',
          output: 'https://gitlab.com/g/app/-/merge_requests/4\n',
        ),
      ]),
      [pullUrl, 'https://gitlab.com/g/app/-/merge_requests/4'],
    );
  });
}
