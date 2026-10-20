import 'package:caocode/browser/browser_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("a CPU profile's functions by their own time and their total", () {
    Map node(int id, String name, List<int> children) => {
      'id': id,
      'callFrame': {
        'functionName': name,
        'url': 'https://site/app.js',
        'lineNumber': id,
        'columnNumber': 0,
      },
      'children': children,
    };
    final summary = CpuSummary.of({
      'nodes': [
        node(1, '(root)', [2, 4]),
        node(2, 'a', [3]),
        node(3, 'b', []),
        node(4, '(idle)', []),
      ],
      'samples': [3, 3, 2, 4, 4],
      'timeDeltas': [0, 1000, 1000, 1000, 2000],
    });
    final byName = {for (final f in summary.functions) f.function.name: f};
    expect(byName['b']!.self, 2);
    expect(byName['b']!.total, 2);
    expect(byName['a']!.self, 1);
    expect(byName['a']!.total, 3);
    expect(summary.functions.first.function.name, 'b');
    expect(summary.idle, 2);
  });

  test("a trace's CPU profile: its nodes by parent", () {
    Map node(int id, String name, int? parent) => {
      'id': id,
      'callFrame': {'functionName': name, 'url': 'app.js', 'lineNumber': id},
      'parent': ?parent,
    };
    final summary = CpuSummary.of({
      'nodes': [node(1, '(root)', null), node(2, 'a', 1), node(3, 'b', 2)],
      'samples': [3, 2, 3],
      'timeDeltas': [0, 1000, 1000, 0],
    });
    final byName = {for (final f in summary.functions) f.function.name: f};
    expect(byName['a']!.total, 2);
    expect(byName['b']!.self, 1);
  });

  test("a style sheet's coverage: what its used rules leave", () {
    const css =
        '.a { color: red }\n'
        '/* card */\n'
        '.never, .not { display: grid }\n'
        '@media (min-width: 9px) { .wide { gap: 1px } }\n'
        '.b { color: blue }\n';
    final b = css.indexOf('.b');
    final coverage = styleCoverage('app.css', css, [
      {'startOffset': 0, 'endOffset': 17, 'used': true},
      {'startOffset': css.indexOf('.never'), 'endOffset': b - 1, 'used': false},
      {'startOffset': b, 'endOffset': css.length - 1, 'used': true},
    ]);
    expect(coverage.unusedRules, ['.never, .not', '.wide']);
    expect(coverage.unused.single.$1, css.indexOf('/*'));
    expect(coverage.kind, 'CSS');
  });
}
