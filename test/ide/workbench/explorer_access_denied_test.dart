import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/ide/file_service.dart';
import 'package:caocode/ide/ide_explorer.dart';
import 'package:caocode/theme/codicons.dart';

import 'fake_files.dart';

/// A folder the user may not read: [locked] refused, as the system (or the
/// remote host, over its server) refuses it.
class _LockedFiles extends TreeFiles {
  _LockedFiles(super.contents, this.locked);

  final String locked;

  @override
  Future<List<IdeFile>> list(String directory) async {
    if (directory == locked) throw IdeFileAccessDeniedException(directory);
    return super.list(directory);
  }
}

void main() {
  testWidgets('a folder the user may not read says so, under a lock', (
    tester,
  ) async {
    final controller = IdeExplorerController(
      files: _LockedFiles({
        inRoot('ubuntu/a.txt'): 'a',
        inRoot('dev/b.txt'): 'b',
      }, inRoot('ubuntu')),
      root: testRoot,
      watch: (_) => const Stream.empty(),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: IdeExplorer(controller: controller, onOpen: (_, _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('ubuntu'));
    await tester.pumpAndSettle();

    expect(find.text('No permission to read this folder'), findsOneWidget);
    expect(find.byIcon(Codicons.lock), findsOneWidget);
    expect(find.textContaining('Cannot read folder'), findsNothing);
  });
}
