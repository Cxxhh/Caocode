import 'package:caocode/stash/stash_markdown.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

/// [markdown] read into the editor and written back.
String roundTrip(String markdown) =>
    stashDeltaToMarkdown(stashMarkdownToDelta(markdown));

void main() {
  test('round-trips what the editor writes', () {
    const markdown = '''
# Title
## 需求

Plain line
**bold** and *italic* and ~~struck~~ and `code`
<span style="color:#e5534b">red</span> <span style="background-color:#fff3a3">marked</span> <u>under</u>
[a link](https://example.com) and <https://bare.dev>
- one
  - nested
- [ ] todo
- [x] done
1. first
2. second
> quoted
\$E = mc^2\$ inline
\$\$
\\int_0^1 x\\,dx
\$\$
```dart
void main() {}
```
| a | b |
|---|---|
| 1 | 2 |
![](12/shot.png)
<img src="12/big.png" width="320">
[report.pdf](12/report.pdf)
[Caocode](https://caocode.dev "card")
---
end''';
    expect(roundTrip(markdown), markdown);
  });

  test('reads marks into attributes', () {
    final delta = stashMarkdownToDelta(
      '**b** <span style="color:#f00">r</span>',
    );
    final ops = delta.toList();
    expect(ops[0].data, 'b');
    expect(ops[0].attributes, {'bold': true});
    expect(ops[2].attributes, {'color': '#f00'});
  });

  test('writes nested marks with their whitespace outside', () {
    final delta = Delta()
      ..insert('a ')
      ..insert(' bold ', {'bold': true})
      ..insert('tail\n');
    expect(stashDeltaToMarkdown(delta), 'a  **bold** tail');
  });

  test('escapes what would read as marks', () {
    const tricky = r'2 \* 3 costs \$5, a\_b stays, file_name too';
    final delta = stashMarkdownToDelta(tricky);
    expect(
      delta.toList().first.data,
      '2 * 3 costs \$5, a_b stays, file_name too\n',
    );
    expect(roundTrip(tricky), r'2 \* 3 costs \$5, a_b stays, file_name too');
  });

  test('escapes a line that would be a list or a heading', () {
    final delta = Delta()..insert('# not a heading\n1. not a list\n');
    final markdown = stashDeltaToMarkdown(delta);
    expect(markdown, '\\# not a heading\n1\\. not a list');
    expect(
      stashMarkdownToDelta(markdown).toList().first.data,
      '# not a heading\n1. not a list\n',
    );
  });

  test('reads agents\' markdown: four-space lists, blank lines', () {
    const markdown = '## 背景\n\nText\n\n- a\n    - b\n        - c\n';
    expect(roundTrip(markdown), '## 背景\n\nText\n\n- a\n  - b\n    - c');
  });

  test('a lone picture is a block, one in text inline', () {
    final ops = stashMarkdownToDelta('see ![](1/a.png) here').toList();
    expect((ops[1].data as Map).keys.single, StashEmbeds.image);
    expect(roundTrip('see ![](1/a.png) here'), 'see ![](1/a.png) here');
  });

  test('the space kept after a tag ending its line is not written', () {
    String padded(String markdown) {
      final delta = stashMarkdownToDelta(markdown);
      final ops = delta.toList();
      // The editor's: a space before the line's end.
      final out = Delta();
      for (final op in ops.take(ops.length - 1)) {
        out.push(op);
      }
      out
        ..insert(' ')
        ..push(ops.last);
      return stashDeltaToMarkdown(out);
    }

    expect(
      padded('see [X](https://x.dev "card")'),
      'see [X](https://x.dev "card")',
    );
    expect(padded('![](1/a.png)'), '![](1/a.png)');
    // Text's own spaces stay.
    expect(roundTrip('a  b'), 'a  b');
  });
}
