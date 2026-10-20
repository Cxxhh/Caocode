import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/ide/explorer_excludes.dart';
import 'package:path/path.dart' as p;

void main() {
  group('IdeExplorerExcludes', () {
    test('parses the setting: strings kept, blanks dropped', () {
      expect(
        IdeExplorerExcludes.parse([
          'node_modules',
          '  build/**  ',
          '',
          42,
          null,
        ]).patterns,
        ['node_modules', 'build/**'],
      );
      // Not a list: none.
      expect(IdeExplorerExcludes.parse('node_modules').patterns, isEmpty);
      expect(IdeExplorerExcludes.parse(null).patterns, isEmpty);
    });

    test('a name pattern matches anywhere; a path one within the folder', () {
      const excludes = IdeExplorerExcludes([
        'node_modules',
        '*.log',
        'build/**',
      ]);
      const root = '/project';
      // A name matches at any depth.
      expect(excludes.hides('/project/node_modules', root, p.posix), isTrue);
      expect(
        excludes.hides('/project/app/node_modules', root, p.posix),
        isTrue,
      );
      expect(excludes.hides('/project/debug.log', root, p.posix), isTrue);
      expect(excludes.hides('/project/logs/debug.log', root, p.posix), isTrue);
      // A path is relative to the folder the entry is in.
      expect(
        excludes.hides('/project/build/output.js', root, p.posix),
        isTrue,
      );
      expect(excludes.hides('/project/build', root, p.posix), isTrue);
      // Not matched.
      expect(excludes.hides('/project/lib/a.dart', root, p.posix), isFalse);
      expect(excludes.hides('/project/src/a.log.md', root, p.posix), isFalse);
    });

    test('withPattern adds and drops, keeping the order', () {
      const none = IdeExplorerExcludes.none;
      final one = none.withPattern('node_modules');
      expect(one.patterns, ['node_modules']);
      expect(one.withPattern('  ').patterns, ['node_modules']);
      expect(one.withPattern('node_modules').patterns, ['node_modules']);
      expect(
        one.withPattern('build').withPattern('node_modules', exclude: false)
            .patterns,
        ['build'],
      );
    });

    test('equality is by the patterns', () {
      expect(
        const IdeExplorerExcludes(['a', 'b']),
        const IdeExplorerExcludes(['a', 'b']),
      );
      expect(
        const IdeExplorerExcludes(['a']),
        isNot(const IdeExplorerExcludes(['a', 'b'])),
      );
    });
  });
}
