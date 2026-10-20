// A stash's text as the editor holds it (a Quill delta) and as its file
// keeps it (markdown), one into the other and back.
//
// The markdown goes line for line: each line of the editor is one of the
// file's, an empty one an empty one. What markdown has no mark for is
// written as the HTML markdown allows inline: a color or a background as a
// `<span style>`, an underline as `<u>`, a picture's width as `<img
// width>`. Formulas are `$…$` and `$$…$$`, tables GitHub's, a link shown as
// a card `[title](url "card")` alone on its line.

import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

/// The things in a stash's text that are not text.
abstract final class StashEmbeds {
  /// A picture: `{src, width?}` (its path relative to the stash folder,
  /// or absolute). On a line of its own.
  static const image = 'stash-image';

  /// A file: `{path, name}`; a link to it, in the text.
  static const file = 'stash-file';

  /// TeX: `{tex, block}`, a block one on a line of its own.
  static const formula = 'stash-formula';

  /// A table: `{markdown}`, GitHub's. On a line of its own.
  static const table = 'stash-table';

  /// Code: `{code, language}`. On a line of its own.
  static const code = 'stash-code';

  /// A link shown as a card: `{url, title}`. On a line of its own.
  static const card = 'stash-card';

  /// A rule (`---`). On a line of its own.
  static const rule = 'stash-rule';

  /// Those that take a line of their own.
  static const blocks = {image, table, code, card, rule};

  static Embeddable of(String type, Map<String, Object?> data) =>
      Embeddable(type, jsonEncode(data));

  static Map<String, Object?> data(Object? raw) {
    if (raw is Map) return raw.cast<String, Object?>();
    if (raw is String && raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw);
        if (json is Map) return json.cast<String, Object?>();
      } on FormatException {
        // Not one of these.
      }
    }
    return const {};
  }
}

// --- Markdown to the editor -----------------------------------------------------

/// [markdown] as the editor's document.
Delta stashMarkdownToDelta(String markdown) {
  final delta = Delta();
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  // Trailing empty lines are the file's end, not the text's.
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  final indents = <int>[];

  void line([Map<String, Object?>? attributes]) => delta.insert(
    '\n',
    attributes == null || attributes.isEmpty ? null : attributes,
  );

  void block(String type, Map<String, Object?> data) {
    delta.insert(StashEmbeds.of(type, data).toJson());
    line();
  }

  var i = 0;
  while (i < lines.length) {
    final raw = lines[i];
    final trimmed = raw.trim();

    // Fenced code.
    final fence = RegExp(r'^\s*(`{3,}|~{3,})\s*([^`\s]*).*$').firstMatch(raw);
    if (fence != null) {
      final marker = fence[1]!;
      final body = <String>[];
      var j = i + 1;
      while (j < lines.length && !lines[j].trim().startsWith(marker)) {
        body.add(lines[j]);
        j++;
      }
      // Lines of the editor's own code block, written in as text: its
      // language on each line's attribute (`true` for none).
      final language = fence[2] ?? '';
      for (final text in body.isEmpty ? const [''] : body) {
        if (text.isNotEmpty) delta.insert(text);
        line({'code-block': language.isEmpty ? true : language});
      }
      i = j + 1;
      indents.clear();
      continue;
    }

    // Block math.
    if (trimmed.startsWith(r'$$')) {
      if (trimmed.length > 4 && trimmed.endsWith(r'$$')) {
        block(StashEmbeds.formula, {
          'tex': trimmed.substring(2, trimmed.length - 2).trim(),
          'block': true,
        });
        i++;
        continue;
      }
      final body = <String>[if (trimmed.length > 2) trimmed.substring(2)];
      var j = i + 1;
      while (j < lines.length && !lines[j].trim().endsWith(r'$$')) {
        body.add(lines[j]);
        j++;
      }
      if (j < lines.length) {
        final last = lines[j].trim();
        body.add(last.substring(0, last.length - 2));
      }
      block(StashEmbeds.formula, {
        'tex': body.join('\n').trim(),
        'block': true,
      });
      i = j + 1;
      continue;
    }

    // A table: a header row, then its separator.
    if (trimmed.startsWith('|') &&
        i + 1 < lines.length &&
        RegExp(r'^\s*\|?\s*:?-{2,}').hasMatch(lines[i + 1])) {
      final rows = <String>[];
      var j = i;
      while (j < lines.length && lines[j].trim().startsWith('|')) {
        rows.add(lines[j].trim());
        j++;
      }
      block(StashEmbeds.table, {'markdown': rows.join('\n')});
      i = j;
      continue;
    }

    // A rule.
    if (RegExp(r'^(\*{3,}|-{3,}|_{3,})$').hasMatch(trimmed)) {
      block(StashEmbeds.rule, const {});
      i++;
      continue;
    }

    // A picture, or a card, alone on its line.
    if (_lonePicture(trimmed) case final picture?) {
      block(StashEmbeds.image, picture);
      i++;
      continue;
    }
    if (_cardPattern.firstMatch(trimmed) case final card?) {
      block(StashEmbeds.card, {'title': _unescape(card[1]!), 'url': card[2]!});
      i++;
      continue;
    }

    final attributes = <String, Object?>{};
    var text = raw;
    final heading = RegExp(r'^\s{0,3}(#{1,6})\s+(.*)$').firstMatch(raw);
    final quote = RegExp(r'^\s{0,3}>\s?(.*)$').firstMatch(raw);
    final item = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(?:\[([ xX])\]\s+)?(.*)$')
        .firstMatch(raw);
    if (heading != null) {
      attributes['header'] = heading[1]!.length.clamp(1, 3);
      text = heading[2]!.replaceFirst(RegExp(r'\s+#+\s*$'), '');
      indents.clear();
    } else if (quote != null) {
      attributes['blockquote'] = true;
      text = quote[1]!;
      indents.clear();
    } else if (item != null) {
      final width = item[1]!.replaceAll('\t', '    ').length;
      while (indents.isNotEmpty && indents.last > width) {
        indents.removeLast();
      }
      if (indents.isEmpty || indents.last < width) indents.add(width);
      final level = (indents.length - 1).clamp(0, 5);
      attributes['list'] = switch (item[3]) {
        ' ' => 'unchecked',
        'x' || 'X' => 'checked',
        _ => RegExp(r'^\d').hasMatch(item[2]!) ? 'ordered' : 'bullet',
      };
      if (level > 0) attributes['indent'] = level;
      text = item[4]!;
    } else {
      if (trimmed.isNotEmpty) indents.clear();
      text = raw.trimRight();
    }
    _inline(text, delta, const {});
    line(attributes);
    i++;
  }
  if (delta.isEmpty) delta.insert('\n');
  return delta;
}

final _cardPattern = RegExp(r'^\[([^\]]*)\]\((\S+)\s+"card"\)$');
final _inlineCard = RegExp(r'^\[([^\]]*)\]\((\S+)\s+"card"\)');

/// The picture [line] is, alone: `![alt](src)` or `<img src width>`.
Map<String, Object?>? _lonePicture(String line) {
  final markdown = RegExp(r'^!\[[^\]]*\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)$')
      .firstMatch(line);
  if (markdown != null) return {'src': markdown[1]!};
  if (RegExp(r'^<img\s[^>]*>$').hasMatch(line)) return _imgTag(line);
  return null;
}

Map<String, Object?>? _imgTag(String tag) {
  final src = RegExp(r'\ssrc="([^"]*)"').firstMatch(tag)?[1];
  if (src == null) return null;
  final width = double.tryParse(
    RegExp(r'\swidth="?(\d+(?:\.\d+)?)').firstMatch(tag)?[1] ?? '',
  );
  return {'src': src, 'width': ?width};
}

/// Whether [href] is a file here rather than a page: a path, absolute or
/// in the stash folder (`12/report.pdf`).
bool isStashFileHref(String href) {
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(href)) return false;
  if (href.startsWith('mailto:') || href.startsWith('#')) return false;
  return href.startsWith('/') ||
      href.startsWith('~/') ||
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(href) ||
      RegExp(r'^\d+/').hasMatch(href);
}

/// Puts [text] (one line's, markdown) into [delta] with [base] attributes
/// over its own.
void _inline(String text, Delta delta, Map<String, Object?> base) {
  final buffer = StringBuffer();
  void flush() {
    if (buffer.isEmpty) return;
    delta.insert(buffer.toString(), base.isEmpty ? null : {...base});
    buffer.clear();
  }

  void nested(String inner, Map<String, Object?> more) {
    flush();
    _inline(inner, delta, {...base, ...more});
  }

  void embed(String type, Map<String, Object?> data) {
    flush();
    delta.insert(
      StashEmbeds.of(type, data).toJson(),
      base.isEmpty ? null : {...base},
    );
  }

  var i = 0;
  while (i < text.length) {
    final char = text[i];
    final rest = text.substring(i);

    // An escaped mark is the character itself.
    if (char == r'\' &&
        i + 1 < text.length &&
        _escapable.contains(text[i + 1])) {
      buffer.write(text[i + 1]);
      i += 2;
      continue;
    }

    // Code: as many backticks close it as opened it.
    if (char == '`') {
      final open = RegExp('^`+').firstMatch(rest)![0]!;
      final close = text.indexOf(open, i + open.length);
      if (close > i) {
        var code = text.substring(i + open.length, close);
        if (code.length > 2 && code.startsWith(' ') && code.endsWith(' ')) {
          code = code.substring(1, code.length - 1);
        }
        flush();
        delta.insert(code, {...base, 'code': true});
        i = close + open.length;
        continue;
      }
    }

    // Inline math.
    if (char == r'$' && !rest.startsWith(r'$$')) {
      final match = RegExp(r'^\$([^\s$](?:[^$]*[^\s$])?)\$(?!\d)')
          .firstMatch(rest);
      if (match != null) {
        embed(StashEmbeds.formula, {'tex': match[1]!, 'block': false});
        i += match[0]!.length;
        continue;
      }
    }

    // Pictures and links.
    if (char == '!' && rest.startsWith('![')) {
      final link = _link(text, i + 1);
      if (link != null) {
        embed(StashEmbeds.image, {'src': link.href});
        i = link.end;
        continue;
      }
    }
    if (char == '[') {
      // A card amid text.
      if (_inlineCard.firstMatch(rest) case final card?) {
        embed(StashEmbeds.card, {
          'title': _unescape(card[1]!),
          'url': card[2]!,
        });
        i += card[0]!.length;
        continue;
      }
      final link = _link(text, i);
      if (link != null) {
        if (isStashFileHref(link.href)) {
          embed(StashEmbeds.file, {
            'path': link.href,
            'name': _unescape(link.text),
          });
        } else {
          nested(link.text, {'link': link.href});
        }
        i = link.end;
        continue;
      }
    }

    // HTML: spans, underlines, pictures, autolinks.
    if (char == '<') {
      if (RegExp(r'^<https?://[^>\s]+>').firstMatch(rest) case final auto?) {
        final url = auto[0]!.substring(1, auto[0]!.length - 1);
        flush();
        delta.insert(url, {...base, 'link': url});
        i += auto[0]!.length;
        continue;
      }
      if (RegExp(r'^<img\s[^>]*>').firstMatch(rest) case final tag?) {
        if (_imgTag(tag[0]!) case final picture?) {
          embed(StashEmbeds.image, picture);
          i += tag[0]!.length;
          continue;
        }
      }
      if (RegExp(r'^<br\s*/?>').firstMatch(rest) case final br?) {
        buffer.write(' ');
        i += br[0]!.length;
        continue;
      }
      if (_tag(text, i) case (
        :final name,
        :final attributes,
        :final inner,
        :final end,
      )) {
        final more = <String, Object?>{};
        switch (name) {
          case 'span' || 'font' || 'mark':
            final style =
                RegExp(r'''style\s*=\s*["']([^"']*)["']''')
                    .firstMatch(attributes)?[1] ??
                '';
            if (RegExp(r'(?:^|;)\s*color:\s*([^;]+)').firstMatch(style)
                case final color?) {
              more['color'] = color[1]!.trim();
            }
            if (RegExp(r'background(?:-color)?:\s*([^;]+)').firstMatch(style)
                case final background?) {
              more['background'] = background[1]!.trim();
            }
            if (name == 'mark' && !more.containsKey('background')) {
              more['background'] = '#fff3a3';
            }
          case 'u':
            more['underline'] = true;
          case 'b' || 'strong':
            more['bold'] = true;
          case 'i' || 'em':
            more['italic'] = true;
          case 's' || 'del':
            more['strike'] = true;
        }
        nested(inner, more);
        i = end;
        continue;
      }
    }

    // Emphasis.
    if (char == '*' || char == '_' || char == '~') {
      final span = _emphasis(text, i);
      if (span != null) {
        nested(span.inner, span.attributes);
        i = span.end;
        continue;
      }
    }

    // A bare web address is a link.
    if ((char == 'h') && (i == 0 || !RegExp(r'[\w/]').hasMatch(text[i - 1]))) {
      final url = RegExp(r'^https?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?。，；：！？]')
          .firstMatch(rest);
      if (url != null && !base.containsKey('link')) {
        flush();
        delta.insert(url[0]!, {...base, 'link': url[0]!});
        i += url[0]!.length;
        continue;
      }
    }

    buffer.write(char);
    i++;
  }
  flush();
}

const _escapable = r'\`*_{}[]()#+-.!|~$<>"';

String _unescape(String text) => text.replaceAllMapped(
  RegExp(r'\\(.)'),
  (m) => _escapable.contains(m[1]!) ? m[1]! : m[0]!,
);

/// The link (`[text](href "title")`) at [at] of [text].
({String text, String href, int end})? _link(String text, int at) {
  if (at >= text.length || text[at] != '[') return null;
  var depth = 0;
  var close = -1;
  for (var j = at; j < text.length; j++) {
    final c = text[j];
    if (c == r'\') {
      j++;
      continue;
    }
    if (c == '[') depth++;
    if (c == ']' && --depth == 0) {
      close = j;
      break;
    }
  }
  if (close < 0 || close + 1 >= text.length || text[close + 1] != '(') {
    return null;
  }
  final match = RegExp(r'^\(<?([^)\s>]*)>?(?:\s+"[^"]*")?\)')
      .firstMatch(text.substring(close + 1));
  if (match == null) return null;
  return (
    text: text.substring(at + 1, close),
    href: match[1]!,
    end: close + 1 + match[0]!.length,
  );
}

/// The HTML element at [at] of [text], with what is between its tags.
({String name, String attributes, String inner, int end})? _tag(
  String text,
  int at,
) {
  final open = RegExp(r'^<([a-zA-Z]+)((?:\s[^>]*)?)>')
      .firstMatch(text.substring(at));
  if (open == null) return null;
  final name = open[1]!.toLowerCase();
  final start = at + open[0]!.length;
  var depth = 1;
  final tags = RegExp('<(/?)$name(?:\\s[^>]*)?>', caseSensitive: false);
  for (final match in tags.allMatches(text, start)) {
    depth += match[1]!.isEmpty ? 1 : -1;
    if (depth == 0) {
      return (
        name: name,
        attributes: open[2] ?? '',
        inner: text.substring(start, match.start),
        end: match.end,
      );
    }
  }
  return null;
}

/// The emphasis (`**bold**`, `*italic*`, `~~struck~~`…) at [at] of
/// [text]; underscores only between words' edges, as GitHub reads them.
({String inner, Map<String, Object?> attributes, int end})? _emphasis(
  String text,
  int at,
) {
  for (final (mark, attributes) in const [
    ('***', {'bold': true, 'italic': true}),
    ('**', {'bold': true}),
    ('__', {'bold': true}),
    ('~~', {'strike': true}),
    ('*', {'italic': true}),
    ('_', {'italic': true}),
  ]) {
    if (!text.startsWith(mark, at)) continue;
    final start = at + mark.length;
    if (start >= text.length || text[start].trim().isEmpty) continue;
    final underscore = mark.startsWith('_');
    if (underscore && at > 0 && RegExp(r'\w').hasMatch(text[at - 1])) {
      continue;
    }
    var from = start + 1;
    while (true) {
      final close = text.indexOf(mark, from);
      if (close < 0) break;
      final after = close + mark.length;
      final ok =
          text[close - 1].trim().isNotEmpty &&
          text[close - 1] != r'\' &&
          // `**a**` is not `*` + `*a*` + `*`.
          (after >= text.length || text[after] != mark[0]) &&
          (!underscore ||
              after >= text.length ||
              !RegExp(r'\w').hasMatch(text[after]));
      if (ok) {
        return (
          inner: text.substring(start, close),
          attributes: attributes,
          end: after,
        );
      }
      from = close + 1;
    }
  }
  return null;
}

// --- The editor to markdown -----------------------------------------------------

/// The editor's [delta] as markdown.
String stashDeltaToMarkdown(Delta delta) {
  final out = <String>[];
  final segments = <_Segment>[];
  // Ordered lists' counters, by level.
  final counters = <int, int>{};

  // A code block's lines as they come, written as one fence once it ends.
  final code = <String>[];
  Object? codeLanguage;
  void endCode() {
    if (code.isEmpty) return;
    final text = code.join('\n');
    var fence = '```';
    while (text.contains(fence)) {
      fence += '`';
    }
    final language = codeLanguage is String ? codeLanguage : '';
    out.add('$fence$language\n$text\n$fence');
    code.clear();
    codeLanguage = null;
  }

  void endLine(Map<String, Object?> attributes) {
    final lineSegments = [...segments];
    segments.clear();
    if (attributes['code-block'] case final language?) {
      if (code.isNotEmpty && language != codeLanguage) endCode();
      codeLanguage = language;
      // As typed: no marks, no escapes.
      code.add(lineSegments.map((segment) => segment.text).join());
      counters.clear();
      return;
    }
    endCode();
    // The space the editor keeps after a tag ending its line (for the
    // caret) is not the text's.
    if (lineSegments.length > 1 &&
        lineSegments.last.embed == null &&
        lineSegments.last.text.trim().isEmpty &&
        lineSegments[lineSegments.length - 2].embed != null) {
      lineSegments.removeLast();
    }
    // A block thing alone on its line.
    if (lineSegments.length == 1) {
      if (lineSegments.single.embed case (final type, final data)
          when StashEmbeds.blocks.contains(type) ||
              (type == StashEmbeds.formula && data['block'] == true)) {
        out.add(_blockMarkdown(type, data));
        counters.clear();
        return;
      }
    }
    var text = _inlineMarkdown(lineSegments);
    final list = attributes['list'] as String?;
    final indent = (attributes['indent'] as int?) ?? 0;
    if (list == null) counters.clear();
    if (attributes['header'] case final int level) {
      text = '${'#' * level} $text';
    } else if (attributes['blockquote'] == true) {
      text = '> $text';
    } else if (list != null) {
      final pad = '  ' * indent;
      counters.removeWhere((level, _) => level > indent);
      final String marker;
      if (list == 'ordered') {
        final n = counters[indent] = (counters[indent] ?? 0) + 1;
        marker = '$n.';
      } else {
        counters.remove(indent);
        marker = switch (list) {
          'checked' => '- [x]',
          'unchecked' => '- [ ]',
          _ => '-',
        };
      }
      text = '$pad$marker $text';
    } else {
      text = _escapeLineStart(text);
    }
    out.add(text);
  }

  for (final op in delta.toList()) {
    final data = op.data;
    final attributes = op.attributes ?? const <String, Object?>{};
    if (data is String) {
      final parts = data.split('\n');
      for (var k = 0; k < parts.length; k++) {
        if (parts[k].isNotEmpty) {
          segments.add(_Segment.text(parts[k], attributes));
        }
        if (k < parts.length - 1) endLine(attributes);
      }
    } else if (data is Map) {
      final entry = data.entries.first;
      segments.add(
        _Segment.embed(
          '${entry.key}',
          StashEmbeds.data(entry.value),
          attributes,
        ),
      );
    }
  }
  if (segments.isNotEmpty) endLine(const {});
  endCode();
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

class _Segment {
  _Segment.text(this.text, this.attributes) : embed = null;
  _Segment.embed(String type, Map<String, Object?> data, this.attributes)
    : text = '',
      embed = (type, data);

  final String text;
  final (String, Map<String, Object?>)? embed;
  final Map<String, Object?> attributes;
}

String _blockMarkdown(String type, Map<String, Object?> data) {
  switch (type) {
    case StashEmbeds.image:
      return _pictureMarkdown(data);
    case StashEmbeds.code:
      final code = data['code'] as String? ?? '';
      final language = data['language'] as String? ?? '';
      var fence = '```';
      while (code.contains(fence)) {
        fence += '`';
      }
      return '$fence$language\n$code\n$fence';
    case StashEmbeds.table:
      return (data['markdown'] as String? ?? '').trim();
    case StashEmbeds.card:
      final title = _escapeText(data['title'] as String? ?? '');
      return '[$title](${data['url']} "card")';
    case StashEmbeds.formula:
      return '\$\$\n${(data['tex'] as String? ?? '').trim()}\n\$\$';
    case StashEmbeds.rule:
      return '---';
  }
  return '';
}

String _pictureMarkdown(Map<String, Object?> data) {
  final src = data['src'] as String? ?? '';
  final width = (data['width'] as num?)?.round();
  if (width != null) return '<img src="$src" width="$width">';
  return src.contains(' ') ? '![](<$src>)' : '![]($src)';
}

String _inlineMarkdown(List<_Segment> segments) {
  final buffer = StringBuffer();
  var i = 0;
  while (i < segments.length) {
    final segment = segments[i];
    if (segment.embed case (final type, final data)) {
      buffer.write(switch (type) {
        StashEmbeds.image => _pictureMarkdown(data),
        StashEmbeds.file =>
          '[${_escapeText(data['name'] as String? ?? '')}](${_href(data['path'] as String? ?? '')})',
        StashEmbeds.formula => '\$${data['tex']}\$',
        StashEmbeds.card => _blockMarkdown(type, data),
        // Fenced on lines of their own, amid text.
        StashEmbeds.code ||
        StashEmbeds.table ||
        StashEmbeds.rule => '\n${_blockMarkdown(type, data)}\n',
        _ => '',
      });
      i++;
      continue;
    }
    // Runs of the same link (or none) go together.
    final link = segment.attributes['link'] as String?;
    final run = <_Segment>[];
    while (i < segments.length &&
        segments[i].embed == null &&
        segments[i].attributes['link'] == link) {
      run.add(segments[i]);
      i++;
    }
    final inner = run.map(_styled).join();
    if (link == null) {
      buffer.write(inner);
    } else if (run.length == 1 &&
        run.single.text == link &&
        run.single.attributes.length == 1 &&
        RegExp(r'^https?://').hasMatch(link)) {
      buffer.write('<$link>');
    } else {
      buffer.write('[$inner](${_href(link)})');
    }
  }
  return buffer.toString();
}

String _href(String href) => href.contains(' ') ? '<$href>' : href;

/// One run of text with its marks, whitespace kept outside them.
String _styled(_Segment segment) {
  final attributes = segment.attributes;
  final text = segment.text;
  if (text.trim().isEmpty) return text;
  final lead = RegExp(r'^\s*').firstMatch(text)![0]!;
  final trail = RegExp(r'\s*$').firstMatch(text)![0]!;
  var core = text.substring(lead.length, text.length - trail.length);
  if (attributes['code'] == true) {
    var ticks = '`';
    while (core.contains(ticks)) {
      ticks += '`';
    }
    final pad = core.startsWith('`') || core.endsWith('`') ? ' ' : '';
    core = '$ticks$pad$core$pad$ticks';
  } else {
    core = _escapeText(core);
    if (attributes['strike'] == true) core = '~~$core~~';
    if (attributes['italic'] == true) core = '*$core*';
    if (attributes['bold'] == true) core = '**$core**';
    if (attributes['underline'] == true) core = '<u>$core</u>';
  }
  final styles = [
    if (attributes['color'] case final String color) 'color:$color',
    if (attributes['background'] case final String background)
      'background-color:$background',
  ];
  if (styles.isNotEmpty) {
    core = '<span style="${styles.join(';')}">$core</span>';
  }
  return '$lead$core$trail';
}

/// [text] with the marks that would make it something else escaped.
String _escapeText(String text) => text.replaceAllMapped(
  RegExp(r'[\\`*\[\]$<]|~~|(?<![\w])_|_(?![\w])'),
  (m) => m[0]!.split('').map((c) => '\\$c').join(),
);

/// A line of text that would read as a heading, a quote, a list item or a
/// rule, escaped not to.
String _escapeLineStart(String line) {
  // `1. ` as `1\. `: a digit has no escape.
  if (RegExp(r'^(\s*\d+)([.)]\s)').firstMatch(line) case final number?) {
    return '${number[1]}\\${line.substring(number[1]!.length)}';
  }
  if (RegExp(r'^\s{0,3}(#{1,6}\s|>|[-+*]\s)').hasMatch(line) ||
      RegExp(r'^(\*{3,}|-{3,}|_{3,})$').hasMatch(line.trim()) ||
      RegExp(r'^\s*(```|~~~|\$\$|\|)').hasMatch(line)) {
    final at = line.length - line.trimLeft().length;
    return '${line.substring(0, at)}\\${line.substring(at)}';
  }
  return line;
}

/// A [Document] of [markdown], for the editor.
Document stashDocument(String markdown) =>
    Document.fromDelta(stashMarkdownToDelta(markdown));
