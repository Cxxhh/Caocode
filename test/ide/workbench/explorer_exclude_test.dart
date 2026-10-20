import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/ide/explorer_excludes.dart';
import 'package:caocode/ide/ide_explorer.dart';
import 'package:path/path.dart' as p;

import 'fake_files.dart';

/// The explorer with hidden files and folders (Caocode's own
/// `explorer.exclude`; see [IdeExplorerExcludes]).
void main() {
  const files = {
    'lib/a.dart': 'a',
    'lib/generated/api.dart': 'g',
    'node_modules/pkg/index.js': 'n',
    'build/out.js': 'b',
    'README.md': 'r',
  };

  Future<IdeExplorerController> controller(
    IdeExplorerExcludes excludes,
  ) async {
    final explorer = IdeExplorerController(
      root: testRoot,
      files: TreeFiles({
        for (final MapEntry(:key, :value) in files.entries) inRoot(key): value,
      }),
      paths: p.posix,
      excludes: excludes,
      watch: (_) => const Stream.empty(),
    );
    addTearDown(explorer.dispose);
    await Future<void>.delayed(Duration.zero);
    return explorer;
  }

  List<String> shown(IdeExplorerController explorer) => [
    for (final row in explorer.rows) row.name,
  ];

  test('nothing hidden by default', () async {
    final explorer = await controller(IdeExplorerExcludes.none);
    expect(
      shown(explorer),
      containsAll(['lib', 'node_modules', 'build', 'README.md']),
    );
  });

  test('a name hides the file or folder anywhere', () async {
    final explorer = await controller(
      const IdeExplorerExcludes(['node_modules', 'build', '*.md']),
    );
    expect(shown(explorer), ['lib']);
    // The hidden ones are left out; others (generated) are not.
    await explorer.expand(inRoot('lib'));
    expect(shown(explorer), containsAll(['lib', 'generated', 'a.dart']));
    expect(shown(explorer), isNot(contains('node_modules')));
  });

  test('a path hides within the folder it names', () async {
    final explorer = await controller(
      const IdeExplorerExcludes(['lib/generated']),
    );
    await explorer.expand(inRoot('lib'));
    // The folder itself is not there, nor its contents.
    expect(shown(explorer), contains('lib'));
    expect(shown(explorer), isNot(contains('generated')));
    expect(shown(explorer), isNot(contains('api.dart')));
    // Its siblings and the other folders are.
    expect(
      shown(explorer),
      containsAll(['a.dart', 'build', 'node_modules', 'README.md']),
    );
  });

  test('changing the excludes rebuilds the rows', () async {
    final explorer = await controller(IdeExplorerExcludes.none);
    expect(shown(explorer), contains('node_modules'));
    var notified = 0;
    explorer.addListener(() => notified++);
    explorer.excludes = const IdeExplorerExcludes(['node_modules']);
    expect(notified, 1);
    expect(shown(explorer), isNot(contains('node_modules')));
    // The same excludes again: nothing rebuilt.
    explorer.excludes = const IdeExplorerExcludes(['node_modules']);
    expect(notified, 1);
  });
}
