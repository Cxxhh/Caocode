import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/ide/git/repository_scan.dart';
import 'package:caocode/ide/ide_list.dart';
import 'package:caocode/ide/ide_workspace.dart';

import '../git/fake_git.dart';
import 'fake_files.dart';

void main() {
  test('a folder\'s repositories in its subfolders join its own, each '
      'file\'s the deepest it is in', () async {
    final own = FakeGit(testRoot);
    final app = FakeGit(inRoot('app'));
    final searched = <String>[];
    final workspace = IdeWorkspace(
      testRoot,
      files: TreeFiles(const {}),
      git: own.repository(),
      repositoryDetection: IdeRepositoryDetection(
        find: (folder) async {
          searched.add(folder);
          return [inRoot('app')];
        },
        open: (_) => app.repository(),
      ),
    );
    addTearDown(workspace.dispose);
    // None until found: the folder's own alone.
    expect(workspace.repositories, isEmpty);
    final ownGit = workspace.git;

    await pumpEventQueue();
    expect(searched, [testRoot]);
    expect(
      [for (final (root, _) in workspace.repositories) root],
      [testRoot, inRoot('app')],
    );
    expect(workspace.git, same(ownGit));
    final appGit = workspace.repositories.last.$2;
    expect(workspace.gitAt(inRoot('app/lib/main.dart')), same(appGit));
    expect(workspace.gitAt(inRoot('app')), same(appGit));
    expect(workspace.gitAt(inRoot('README.md')), same(ownGit));

    workspace.selectRepository(appGit);
    expect(workspace.git, same(appGit));
  });

  test('a folder that is not a repository is left out once ones are found '
      'in it', () async {
    final own = FakeGit(testRoot)..isRepository = false;
    final app = FakeGit(inRoot('app'));
    final workspace = IdeWorkspace(
      testRoot,
      files: TreeFiles(const {}),
      git: own.repository(),
      repositoryDetection: IdeRepositoryDetection(
        find: (_) async => [inRoot('app')],
        open: (_) => app.repository(),
      ),
    );
    addTearDown(workspace.dispose);
    var notified = 0;
    workspace.addListener(() => notified++);
    await pumpEventQueue();
    expect(
      [for (final (root, _) in workspace.repositories) root],
      [inRoot('app')],
    );
    expect(workspace.git?.isRepository, isTrue);
    expect(notified, greaterThan(0));
  });

  test('a workspace folder\'s found repositories go with it, and another '
      'folder is not found again', () async {
    final gits = <String, FakeGit>{};
    FakeGit git(String root) => gits[root] ??= FakeGit(root);
    final workspace = IdeWorkspace(
      '/data/w1',
      files: TreeFiles(const {}),
      roots: [inRoot('site'), inRoot('api')],
      gitOf: (root) => git(root).repository(),
      repositoryDetection: IdeRepositoryDetection(
        find: (folder) async => [
          if (folder == inRoot('site')) ...[
            inRoot('site/theme'),
            // A workspace folder of its own.
            inRoot('api'),
          ],
        ],
        open: (path) => git(path).repository(),
      ),
    );
    addTearDown(workspace.dispose);
    await pumpEventQueue();
    expect(
      [for (final (root, _) in workspace.repositories) root],
      [inRoot('site'), inRoot('site/theme'), inRoot('api')],
    );

    workspace.roots = [inRoot('api')];
    expect(
      [for (final (root, _) in workspace.repositories) root],
      [inRoot('api')],
    );
  });

  testWidgets('Source Control lists the repositories found in the folder, '
      'and shows the one picked', (tester) async {
    final own = FakeGit(testRoot)..status = '## main\x00 M README.md\x00';
    final app = FakeGit(inRoot('app'))
      ..status = '## dev\x00 M main.dart\x00?? new.dart\x00';
    await pumpWorkbench(
      tester,
      const {'README.md': '', 'app/main.dart': '', 'app/new.dart': ''},
      git: own.repository(),
      repositoryDetection: IdeRepositoryDetection(
        find: (_) async => [inRoot('app')],
        open: (_) => app.repository(),
      ),
    );
    await tester.pumpAndSettle();

    await chord(tester, LogicalKeyboardKey.keyG, control: true, shift: true);
    await tester.pumpAndSettle();
    // Every repository under its header in CHANGES (#76): its branch
    // right after its name, marked with what changed, and its changes.
    expect(find.text('Repositories'), findsNothing);
    expect(find.text('app'), findsWidgets);
    expect(find.text('dev*'), findsOneWidget);
    expect(find.text('main*'), findsOneWidget);
    expect(find.text('README.md'), findsWidgets);
    expect(find.text('new.dart'), findsOneWidget);
    final appHeader = find.byKey(ValueKey('repo:${inRoot('app')}')).first;
    final name = find.descendant(of: appHeader, matching: find.text('app'));
    expect(
      tester.getTopLeft(find.text('dev*')).dx,
      lessThan(tester.getTopRight(name).dx + 40),
    );
    // No count: the marks tell what changed (`scm.providerCountBadge`).
    expect(
      find.descendant(of: appHeader, matching: find.byType(IdeTitleBadge)),
      findsNothing,
    );

    // The one clicked is the one shown (the status bar's branch).
    expect(find.text('dev'), findsNothing);
    await tester.tap(appHeader);
    await tester.pumpAndSettle();
    expect(find.text('dev'), findsOneWidget);
  });
}
