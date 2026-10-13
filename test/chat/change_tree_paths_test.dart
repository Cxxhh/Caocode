import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/chat/panels/change_tree.dart';
import 'package:caocode/ide/git/git_model.dart';
import 'package:caocode/ide/git/scm_tree.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A remote project's changes, listed from Windows: its paths are its
/// host's (POSIX), not this machine's.
void main() {
  IdeGitResource resource(String path) => IdeGitResource(
    path: path,
    status: IdeGitStatus.modified,
    group: IdeGitGroup.workingTree,
  );

  test('a path spelled otherwise than its root still finds its place', () {
    // As the review spelled a remote file from Windows: it went looking for
    // folders above the root, without end.
    final tree = ideScmTree('/home/u/app', [
      resource(r'\home\u\app\src\a.ts'),
      resource('/home/u/app/src/b.ts'),
    ], paths: p.windows);
    final files = [
      for (final node in tree)
        ...switch (node) {
          IdeScmTreeFolder(:final resources) => resources,
          IdeScmTreeFile(:final resource) => [resource],
        },
    ];
    expect(files.map((r) => r.path), {
      r'\home\u\app\src\a.ts',
      '/home/u/app/src/b.ts',
    });
  });

  testWidgets('a remote project\'s changes list under their folders', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: ChangeTree(
            root: '/home/u/app',
            paths: p.posix,
            changes: const [
              FileChange(path: '/home/u/app/src/a.ts', added: 3, removed: 1),
              FileChange(path: '/home/u/app/src/b.ts', added: 2, removed: 0),
            ],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('src'), findsOneWidget);
    expect(find.text('a.ts'), findsOneWidget);
    expect(find.text('b.ts'), findsOneWidget);
  });
}
