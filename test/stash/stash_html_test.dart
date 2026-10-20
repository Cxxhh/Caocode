import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/stash/stash_html.dart';

void main() {
  test('a web page becomes clean markdown', () {
    const page = '''
<html><head><title>x</title><style>p{}</style></head><body>
<h1 style="font-family:Arial">Title</h1>
<p>Some <b>bold</b>, <em>italic</em> and <span style="color:#ff0000;font-size:30px">red</span> text with a <a href="https://a.dev/x">link</a>.</p>
<ul><li>one<ul><li>inner</li></ul></li><li><input type="checkbox" checked> done</li></ul>
<ol start="3"><li>three</li><li>four</li></ol>
<blockquote><p>quoted</p></blockquote>
<pre><code class="language-dart">void main() {}
</code></pre>
<table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2|3</td></tr></table>
<p><img src="https://a.dev/p.png" alt="pic"></p>
<script>alert(1)</script>
</body></html>''';
    expect(stashHtmlToMarkdown(page), '''
# Title

Some **bold**, *italic* and red text with a [link](https://a.dev/x).

- one
  - inner
- [x] done

3. three
4. four

> quoted

```dart
void main() {}
```

| a | b |
| --- | --- |
| 1 | 2\\|3 |

![pic](https://a.dev/p.png)''');
  });

  test('Google Docs\' normal-weight wrapper is not bold', () {
    expect(
      stashHtmlToMarkdown(
        '<b style="font-weight:normal" id="docs"><span style="font-weight:700">Hi</span> there</b>',
      ),
      '**Hi** there',
    );
  });

  test('marks in text are escaped', () {
    expect(stashHtmlToMarkdown('<p>a *b* [c]</p>'), r'a \*b\* \[c\]');
  });
}
