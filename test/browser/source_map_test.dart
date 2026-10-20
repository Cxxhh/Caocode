import 'dart:convert';

import 'package:caocode/browser/source_map.dart';
import 'package:flutter_test/flutter_test.dart';

/// [segments] of each generated line ([column, source, line, column, name?],
/// absolute) as a map's mappings.
String _mappings(List<List<List<int>>> lines) {
  const digits =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  String vlq(int value) {
    var v = value < 0 ? ((-value) << 1) | 1 : value << 1;
    final out = StringBuffer();
    do {
      var digit = v & 31;
      v >>= 5;
      if (v > 0) digit |= 32;
      out.write(digits[digit]);
    } while (v > 0);
    return out.toString();
  }

  var source = 0, line = 0, column = 0, name = 0;
  return [
    for (final segments in lines)
      () {
        var generated = 0;
        return [
          for (final s in segments)
            () {
              final out = StringBuffer(vlq(s[0] - generated));
              generated = s[0];
              out
                ..write(vlq(s[1] - source))
                ..write(vlq(s[2] - line))
                ..write(vlq(s[3] - column));
              source = s[1];
              line = s[2];
              column = s[3];
              if (s.length > 4) {
                out.write(vlq(s[4] - name));
                name = s[4];
              }
              return out.toString();
            }(),
        ].join(',');
      }(),
  ].join(';');
}

void main() {
  final json = jsonEncode({
    'version': 3,
    'sources': ['./src/a.ts', 'src/b.ts'],
    'sourceRoot': 'webpack://app/',
    'sourcesContent': ['const a = 1;\nfoo();\n', null],
    'names': ['foo'],
    'mappings': _mappings([
      [
        [0, 0, 0, 0],
        [9, 0, 1, 2, 0],
      ],
      [
        [0, 1, 4, 0],
      ],
    ]),
  });

  test('a place in the bundle maps to its source', () {
    final map = SourceMap.parse(json, url: 'https://site/app.js.map')!;
    expect(map.sources, ['webpack://app/src/a.ts', 'webpack://app/src/b.ts']);
    final at = map.original(0, 12)!;
    expect((at.source, at.line, at.column, at.name), (0, 1, 2, 'foo'));
    expect(at.toString(), 'src/a.ts:2:3');
    expect(map.original(1, 40)!.line, 4);
    expect(map.original(5, 0), isNull);
    expect(map.content(0), contains('foo();'));
    expect(map.content(1), isNull);
  });

  test("a source's line maps to the bundle, or the next line that runs", () {
    final map = SourceMap.parse(json)!;
    expect(map.generated(0, 1), (line: 0, column: 9));
    expect(map.generated(1, 2), (line: 1, column: 0));
    expect(map.generated(1, 20), isNull);
    expect(map.find('b.ts'), 1);
    expect(map.find('src/a.ts'), 0);
    expect(map.find('nothing.ts'), isNull);
  });

  test('an index map reads its sections where they are', () {
    final indexed = jsonEncode({
      'version': 3,
      'sections': [
        {
          'offset': {'line': 10, 'column': 0},
          'map': jsonDecode(json),
        },
      ],
    });
    final map = SourceMap.parse(indexed)!;
    expect(map.original(10, 12)!.line, 1);
    expect(map.original(11, 0)!.source, 1);
    expect(map.original(0, 0), isNull);
  });

  test('a source reads short', () {
    expect(shortSource('webpack://app/./src/App.tsx'), 'src/App.tsx');
    expect(shortSource('http://localhost:5173/src/main.ts'), 'src/main.ts');
    expect(shortSource('src/x.js'), 'src/x.js');
    expect(SourceMap.parse('not json'), isNull);
  });

  test('the function a place is in, by its head', () {
    const code = r'''
export async function saveTodo(text: string): Promise<Todo> {
  const res = await fetch('/api', { method: 'POST' })
  if (!res.ok) {
    throw new Error(`failed: ${res.status}`)
  }
}
const add = async () => {
  try { await saveTodo(text) } catch (e) { console.error(e) }
}
class Store {
  load(id: number): void {
    items.forEach((item) => {
      use(item)
    })
  }
}
''';
    int lineOf(String text) =>
        code.split('\n').indexWhere((l) => l.contains(text));
    expect(enclosingFunction(code, lineOf('throw new'), 4), 'saveTodo');
    expect(enclosingFunction(code, lineOf('const res'), 2), 'saveTodo');
    expect(enclosingFunction(code, lineOf('console.error'), 45), 'add');
    expect(enclosingFunction(code, lineOf('use(item)'), 6), isNull);
    expect(enclosingFunction(code, lineOf('items.forEach'), 4), 'load');
  });

  test("an expression's variables as the minified script names them", () {
    final names = {'res': 't', 'text': 'e'};
    expect(renameVariables('res.status', names), 't.status');
    expect(
      renameVariables('{text: text, s: "res"}.text + res.text', names),
      '{text: e, s: "res"}.text + t.text',
    );
    expect(renameVariables('result + res', names), 'result + t');
    expect(renameVariables('a ? res : text', names), 'a ? t : e');
  });
}
