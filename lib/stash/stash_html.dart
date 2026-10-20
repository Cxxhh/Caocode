import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

/// A web page's (or a document's) [source] as the markdown a stash keeps:
/// its headings, lists, tasks, quotes, code, tables, links and pictures,
/// and its bold, italic, struck and underlined text; not its fonts,
/// sizes, colors or layout.
String stashHtmlToMarkdown(String source) {
  final document = html.parse(source);
  final body = document.body;
  if (body == null) return '';
  final out = _Blocks();
  _block(body, out, const _Context());
  return out.text();
}

/// The markdown being written: blocks, a blank line between each.
class _Blocks {
  final List<String> _blocks = [];
  final StringBuffer _line = StringBuffer();

  /// Text in the paragraph being written.
  void inline(String text) => _line.write(text);

  /// Ends the paragraph being written, if any.
  void flush(_Context context) {
    final text = _line.toString();
    _line.clear();
    final lines = text
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .toList();
    while (lines.isNotEmpty && lines.first.isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    if (lines.isEmpty) return;
    add(context.prefix(lines.join('\n')));
  }

  void add(String block) {
    if (block.trim().isEmpty) return;
    _blocks.add(block);
  }

  String text() {
    flush(const _Context());
    return _blocks.join('\n\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }
}

/// Where a block is: in quotes (each line `> `), in a list item (each
/// line after the first indented).
class _Context {
  const _Context({this.quote = 0});

  final int quote;

  _Context quoted() => _Context(quote: quote + 1);

  String prefix(String block) {
    if (quote == 0) return block;
    final mark = '> ' * quote;
    return block.split('\n').map((line) => '$mark$line'.trimRight()).join('\n');
  }
}

const _skipped = {
  'head',
  'script',
  'style',
  'noscript',
  'template',
  'meta',
  'link',
  'title',
  'svg',
  'canvas',
  'iframe',
  'object',
  'button',
  'select',
  'textarea',
  'nav',
};

const _blockTags = {
  'p',
  'div',
  'section',
  'article',
  'main',
  'header',
  'footer',
  'aside',
  'figure',
  'figcaption',
  'dl',
  'dt',
  'dd',
  'address',
  'details',
  'summary',
  'center',
  'form',
  'fieldset',
  'body',
  'html',
};

void _block(dom.Node node, _Blocks out, _Context context) {
  for (final child in node.nodes) {
    if (child is dom.Text) {
      out.inline(_escape(_collapse(child.text)));
      continue;
    }
    if (child is! dom.Element) continue;
    final tag = child.localName ?? '';
    if (_skipped.contains(tag) || _hidden(child)) continue;
    switch (tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        out.flush(context);
        final level = int.parse(tag.substring(1)).clamp(1, 3);
        final text = _inline(child).trim();
        if (text.isNotEmpty) {
          out.add(
            context.prefix('${'#' * level} ${text.replaceAll('\n', ' ')}'),
          );
        }
      case 'ul' || 'ol':
        out.flush(context);
        final list = _list(child, 0);
        if (list.isNotEmpty) out.add(context.prefix(list));
      case 'blockquote':
        out.flush(context);
        _block(child, out, context.quoted());
        out.flush(context.quoted());
      case 'pre':
        out.flush(context);
        out.add(context.prefix(_fence(child)));
      case 'table':
        out.flush(context);
        final table = _table(child);
        if (table.isNotEmpty) out.add(context.prefix(table));
      case 'hr':
        out.flush(context);
        out.add(context.prefix('---'));
      case 'img':
        // A picture alone is a block; in text, it stays in it.
        out.inline(_picture(child));
      case 'br':
        out.inline('\n');
      case 'li':
        // An item outside a list.
        out.flush(context);
        out.add(context.prefix('- ${_inline(child).trim()}'));
      default:
        if (_blockTags.contains(tag) || _isBlockStyle(child)) {
          out.flush(context);
          _block(child, out, context);
          out.flush(context);
        } else {
          out.inline(_inlineOf(child));
        }
    }
  }
}

bool _hidden(dom.Element element) {
  final style = element.attributes['style'] ?? '';
  return element.attributes.containsKey('hidden') ||
      RegExp(r'display\s*:\s*none').hasMatch(style);
}

bool _isBlockStyle(dom.Element element) {
  final style = element.attributes['style'] ?? '';
  return RegExp(r'display\s*:\s*(block|flex|grid)').hasMatch(style);
}

String _collapse(String text) => text.replaceAll(RegExp(r'\s+'), ' ');

/// [element]'s content as markdown text (its blocks run together).
String _inline(dom.Element element) {
  final buffer = StringBuffer();
  for (final child in element.nodes) {
    if (child is dom.Text) {
      buffer.write(_escape(_collapse(child.text)));
    } else if (child is dom.Element) {
      final tag = child.localName ?? '';
      if (_skipped.contains(tag) || _hidden(child)) continue;
      if (tag == 'ul' || tag == 'ol') continue;
      buffer.write(_inlineOf(child));
    }
  }
  return buffer.toString();
}

/// One inline element as markdown.
String _inlineOf(dom.Element element) {
  final tag = element.localName ?? '';
  switch (tag) {
    case 'br':
      return '\n';
    case 'img':
      return _picture(element);
    case 'code' || 'kbd' || 'samp' || 'tt':
      final code = element.text.replaceAll('\n', ' ');
      if (code.trim().isEmpty) return code;
      var ticks = '`';
      while (code.contains(ticks)) {
        ticks += '`';
      }
      final pad = code.startsWith('`') || code.endsWith('`') ? ' ' : '';
      return '$ticks$pad$code$pad$ticks';
    case 'a':
      final inner = _inline(element);
      final href = element.attributes['href']?.trim() ?? '';
      if (href.isEmpty ||
          href.startsWith('#') ||
          href.startsWith('javascript:') ||
          inner.trim().isEmpty) {
        return inner;
      }
      final target = href.contains(' ') ? '<$href>' : href;
      return _wrap(inner, '[', ']($target)');
    case 'input':
      return '';
  }
  final inner = _inline(element);
  final style = element.attributes['style'] ?? '';
  final weight = RegExp(r'font-weight\s*:\s*(\w+)').firstMatch(style)?[1];
  final bold =
      tag == 'b' ||
      tag == 'strong' ||
      weight == 'bold' ||
      (int.tryParse(weight ?? '') ?? 0) >= 600;
  // Google Docs wraps everything in a `<b style="font-weight:normal">`.
  final unbold = tag == 'b' && (weight == 'normal' || weight == '400');
  final italic =
      tag == 'i' ||
      tag == 'em' ||
      RegExp(r'font-style\s*:\s*italic').hasMatch(style);
  final struck =
      tag == 's' ||
      tag == 'del' ||
      tag == 'strike' ||
      RegExp(r'text-decoration[^;]*line-through').hasMatch(style);
  final underlined =
      tag == 'u' ||
      tag == 'ins' ||
      RegExp(r'text-decoration[^;]*underline').hasMatch(style);
  var text = inner;
  if (struck) text = _wrap(text, '~~', '~~');
  if (italic) text = _wrap(text, '*', '*');
  if (bold && !unbold) text = _wrap(text, '**', '**');
  if (underlined) text = _wrap(text, '<u>', '</u>');
  return text;
}

/// [text] in [open]…[close], its spaces kept outside.
String _wrap(String text, String open, String close) {
  if (text.trim().isEmpty) return text;
  final lead = RegExp(r'^\s*').firstMatch(text)![0]!;
  final trail = RegExp(r'\s*$').firstMatch(text)![0]!;
  final core = text.substring(lead.length, text.length - trail.length);
  // Already so (`<b><strong>x</strong></b>`).
  if (core.startsWith(open) && core.endsWith(close) && open != '[') {
    return text;
  }
  return '$lead$open$core$close$trail';
}

String _picture(dom.Element element) {
  final src = element.attributes['src']?.trim() ?? '';
  if (src.isEmpty || src.startsWith('data:')) return '';
  final alt = _escape(element.attributes['alt']?.trim() ?? '');
  return '![$alt](${src.contains(' ') ? '<$src>' : src})';
}

String _escape(String text) => text.replaceAllMapped(
  RegExp(r'[\\`*\[\]$<]|~~|(?<![\w])_|_(?![\w])'),
  (m) => m[0]!.split('').map((c) => '\\$c').join(),
);

/// A list as markdown: its items, theirs under them indented; a checkbox
/// at an item's start makes it a task.
String _list(dom.Element list, int depth) {
  final ordered = list.localName == 'ol';
  final lines = <String>[];
  var n = int.tryParse(list.attributes['start'] ?? '') ?? 1;
  for (final item in list.children) {
    if (item.localName != 'li') continue;
    final pad = '  ' * depth;
    final box = item.querySelector('input[type=checkbox]');
    String marker;
    if (box != null) {
      marker = box.attributes.containsKey('checked') ? '- [x]' : '- [ ]';
    } else if (ordered) {
      marker = '${n++}.';
    } else {
      marker = '-';
    }
    // Its own text, its paragraphs as lines of it.
    final own = StringBuffer();
    final nested = <String>[];
    for (final child in item.nodes) {
      if (child is dom.Element &&
          (child.localName == 'ul' || child.localName == 'ol')) {
        nested.add(_list(child, depth + 1));
      } else if (child is dom.Element) {
        if (_skipped.contains(child.localName) || _hidden(child)) continue;
        final text = _blockTags.contains(child.localName)
            ? '${_inline(child)} '
            : _inlineOf(child);
        own.write(text);
      } else if (child is dom.Text) {
        own.write(_escape(_collapse(child.text)));
      }
    }
    final text = own
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .join(' ');
    lines.add('$pad$marker $text'.trimRight());
    lines.addAll(nested.where((n) => n.isNotEmpty));
  }
  return lines.join('\n');
}

/// A `<pre>`, fenced, its language from a `language-…` class.
String _fence(dom.Element pre) {
  final code = pre.querySelector('code');
  final classes = '${pre.className} ${code?.className ?? ''}';
  final language =
      RegExp(r'(?:language|lang)-([\w+#-]+)').firstMatch(classes)?[1] ?? '';
  final text = (code ?? pre).text.replaceAll(RegExp(r'\n$'), '');
  var fence = '```';
  while (text.contains(fence)) {
    fence += '`';
  }
  return '$fence$language\n$text\n$fence';
}

/// A table as markdown's: its first row the header.
String _table(dom.Element table) {
  final rows = <List<String>>[];
  for (final row in table.querySelectorAll('tr')) {
    final cells = [
      for (final cell in row.children)
        if (cell.localName == 'td' || cell.localName == 'th')
          _inline(cell)
              .replaceAll('\n', ' ')
              .replaceAll('|', r'\|')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
    ];
    if (cells.isNotEmpty) rows.add(cells);
  }
  if (rows.isEmpty) return '';
  final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
  String line(List<String> cells) =>
      '| ${[for (var i = 0; i < width; i++) i < cells.length ? cells[i] : ''].join(' | ')} |';
  return [
    line(rows.first),
    '|${List.filled(width, ' --- ').join('|')}|',
    for (final row in rows.skip(1)) line(row),
  ].join('\n');
}
