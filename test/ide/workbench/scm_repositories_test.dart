import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show TextField;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/ide/git/ide_scm_view.dart';
import 'package:caocode/ide/git/repository_scan.dart';
import 'package:caocode/ide/ide_workbench.dart';
import 'package:caocode/ide/ide_workspace.dart';

import '../git/fake_git.dart';
import 'fake_files.dart';

/// Source Control's CHANGES with more than one repository (#68, #76): every
/// repository's changes known, and listed under its own header with its own
/// commit message and Commit.
void main() {
  late FakeGit own;
  late FakeGit app;

  setUp(() {
    own = FakeGit(testRoot)..status = '## main\x00 M README.md\x00';
    app = FakeGit(inRoot('app'))
      ..status = '## dev\x00 M main.dart\x00?? new.dart\x00';
  });

  Future<void> pumpScm(WidgetTester tester) async {
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
  }

  testWidgets('the activity bar counts every repository\'s changes', (
    tester,
  ) async {
    await pumpScm(tester);
    // README.md + main.dart + new.dart.
    expect(find.text('3'), findsWidgets);
  });

  Finder header(String root) => find.byKey(ValueKey('repo:$root')).first;

  Finder scmInputs() => find.descendant(
    of: find.byType(IdeScmView),
    matching: find.byType(TextField),
  );

  testWidgets('#76 CHANGES lists every repository, each under its header', (
    tester,
  ) async {
    await pumpScm(tester);
    expect(find.byKey(ValueKey('repo:$testRoot')), findsWidgets);
    expect(find.byKey(ValueKey('repo:${inRoot('app')}')), findsWidgets);
    expect(find.text('README.md'), findsWidgets);
    expect(find.text('new.dart'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    // Each with its own input; no REPOSITORIES to pick them in.
    expect(scmInputs(), findsNWidgets(2));
    expect(find.text('Repositories'), findsNothing);
  });

  testWidgets('a repository\'s header in CHANGES folds and unfolds it', (
    tester,
  ) async {
    await pumpScm(tester);
    expect(find.text('new.dart'), findsOneWidget);

    await tester.tap(header(inRoot('app')));
    await tester.pumpAndSettle();
    expect(find.text('new.dart'), findsNothing);
    expect(find.text('main.dart'), findsNothing);
    // The other repository's changes stay.
    expect(find.text('README.md'), findsWidgets);

    await tester.tap(header(inRoot('app')));
    await tester.pumpAndSettle();
    expect(find.text('new.dart'), findsOneWidget);
  });

  testWidgets('#76 a repository clicked becomes the one shown', (tester) async {
    await pumpScm(tester);
    final workspace = tester
        .state<IdeWorkbenchState>(find.byType(IdeWorkbench))
        .widget
        .workspace;
    expect(workspace.git?.service.root, testRoot);
    await tester.tap(header(inRoot('app')));
    await tester.pumpAndSettle();
    expect(workspace.git?.service.root, inRoot('app'));
  });

  testWidgets('#76 each repository has its own message and Commit', (
    tester,
  ) async {
    own.status = '## main\x00M  README.md\x00';
    app.status = '## dev\x00M  main.dart\x00';
    await pumpScm(tester);
    // Under each header, in the workspace's order: its input and Commit.
    expect(scmInputs(), findsNWidgets(2));
    await tester.enterText(scmInputs().last, 'Add the app');
    await tester.tap(find.byTooltip('Commit Changes (Ctrl+Enter)').last);
    await tester.pumpAndSettle();
    expect(app.callsTo('commit').single, [
      'commit',
      '--quiet',
      '-m',
      'Add the app',
    ]);
    expect(own.callsTo('commit'), isEmpty);
  });

  testWidgets('#76 an empty Changes hides under its repository', (
    tester,
  ) async {
    own.status = '## main\x00';
    await pumpScm(tester);
    expect(find.byKey(ValueKey('repo:$testRoot')), findsWidgets);
    expect(
      find.byKey(ValueKey('group:$testRoot\x00workingTree')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('group:${inRoot('app')}\x00workingTree')),
      findsWidgets,
    );
  });

  testWidgets('#76 a repository\'s folded group stays folded as the one '
      'shown changes', (tester) async {
    await pumpScm(tester);
    await tester.tap(
      find.byKey(ValueKey('group:${inRoot('app')}\x00workingTree')).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('new.dart'), findsNothing);

    // The folder's own shown (folded, then unfolded): the app's group
    // stays as it was.
    await tester.tap(header(testRoot));
    await tester.pumpAndSettle();
    await tester.tap(header(testRoot));
    await tester.pumpAndSettle();
    expect(find.text('README.md'), findsWidgets);
    expect(find.text('new.dart'), findsNothing);
  });

  test('#68 the workspace knows each file\'s repository', () async {
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
    await pumpEventQueue();
    final ownGit = workspace.repositories.first.$2;
    final appGit = workspace.repositories.last.$2;
    expect(workspace.gitAt(inRoot('app/main.dart')), same(appGit));
    expect(workspace.gitAt(inRoot('README.md')), same(ownGit));
  });

  IdeWorkbenchState workbench(WidgetTester tester) =>
      tester.state<IdeWorkbenchState>(find.byType(IdeWorkbench));

  TestGesture? mouse;
  tearDown(() => mouse = null);

  Future<void> hover(WidgetTester tester, Finder finder) async {
    if (mouse case final mouse?) {
      await mouse.moveTo(tester.getCenter(finder));
    } else {
      final created = mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(created.removePointer);
      await created.addPointer(location: tester.getCenter(finder));
    }
    await tester.pumpAndSettle();
  }

  testWidgets('#73 the CHANGES ... offers Fetch From All Remotes, Pull and '
      'Push', (tester) async {
    await pumpScm(tester);
    await hover(tester, find.text('Changes').first);
    await tester.tap(find.byTooltip('More Actions...').first);
    await tester.pumpAndSettle();
    for (final item in ['Fetch From All Remotes', 'Pull', 'Push']) {
      expect(find.text(item), findsOneWidget, reason: item);
    }
  });

  testWidgets('#73/#39 Git: Fetch From All Remotes fetches every repository', (
    tester,
  ) async {
    await pumpScm(tester);
    final state = workbench(tester);
    expect(state.commandsById['git.fetchAll']?.enabled, isTrue);
    expect(state.runCommand('git.fetchAll'), isTrue);
    await tester.pumpAndSettle();
    expect(own.callsTo('fetch'), isNotEmpty);
    expect(app.callsTo('fetch'), isNotEmpty);
  });

  testWidgets('a repository\'s ... Fetch From All Remotes fetches that '
      'repository alone', (tester) async {
    await pumpScm(tester);
    await tester.tap(header(inRoot('app')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch From All Remotes'));
    await tester.pumpAndSettle();
    expect(app.callsTo('fetch'), isNotEmpty);
    expect(own.callsTo('fetch'), isEmpty);
  });

  testWidgets('Git: Pull and Git: Push run on the shown repository', (
    tester,
  ) async {
    own.status = '## main...origin/main [ahead 1]\x00 M README.md\x00';
    await pumpScm(tester);
    final state = workbench(tester);
    expect(state.runCommand('git.pull'), isTrue);
    await tester.pumpAndSettle();
    expect(own.callsTo('pull').single, ['pull', '--tags', 'origin', 'main']);

    expect(state.runCommand('git.push'), isTrue);
    await tester.pumpAndSettle();
    expect(own.callsTo('push').single, ['push', 'origin', 'main:main']);
  });
}
