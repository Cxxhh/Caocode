import 'dart:convert';

/// A source map (version 3): where each piece of a script (bundled,
/// minified) came from in the sources it was built of, and back. Index maps
/// (sections) too.
class SourceMap {
  SourceMap._(this.sources, this._contents, this._lines, this._ignored);

  /// Reads [json], the map of a script at [url] (its sources' URLs are
  /// resolved against it); null if it is not a source map.
  static SourceMap? parse(String json, {String? url}) {
    try {
      final map = jsonDecode(json);
      if (map is! Map) return null;
      final sources = <String>[];
      final contents = <String?>[];
      final lines = <List<_Segment>>[];
      final ignored = <int>{};
      _read(map, url, 0, 0, sources, contents, lines, ignored);
      return SourceMap._(sources, contents, lines, ignored);
    } on Object {
      return null;
    }
  }

  static void _read(
    Map map,
    String? url,
    int lineOffset,
    int columnOffset,
    List<String> sources,
    List<String?> contents,
    List<List<_Segment>> lines,
    Set<int> ignored,
  ) {
    if (map['sections'] case final List sections) {
      for (final section in sections.cast<Map>()) {
        final offset = section['offset'] as Map? ?? const {};
        if (section['map'] case final Map inner) {
          _read(
            inner,
            url,
            lineOffset + ((offset['line'] as num?)?.toInt() ?? 0),
            (offset['column'] as num?)?.toInt() ?? 0,
            sources,
            contents,
            lines,
            ignored,
          );
        }
      }
      return;
    }
    final root = map['sourceRoot'] as String? ?? '';
    final first = sources.length;
    final own = (map['sources'] as List? ?? const []);
    final ownContents = map['sourcesContent'] as List?;
    for (final (i, source) in own.indexed) {
      sources.add(_resolve(url, root, '${source ?? ''}'));
      contents.add(
        ownContents != null && i < ownContents.length
            ? ownContents[i] as String?
            : null,
      );
    }
    // The libraries' (DevTools hides their calls).
    for (final i
        in (map['ignoreList'] ?? map['x_google_ignoreList'] ?? const [])
            as List) {
      if (i is int) ignored.add(first + i);
    }
    final names = (map['names'] as List? ?? const []).cast<Object?>();
    final mappings = map['mappings'] as String? ?? '';
    var line = lineOffset;
    var column = 0;
    var source = 0;
    var sourceLine = 0;
    var sourceColumn = 0;
    var name = 0;
    var first0 = true;
    for (final text in mappings.split(';')) {
      while (lines.length <= line) {
        lines.add([]);
      }
      column = 0;
      for (final piece in text.split(',')) {
        if (piece.isEmpty) continue;
        final values = _vlq(piece);
        column += values[0];
        final at = column + (first0 ? columnOffset : 0);
        if (values.length >= 4) {
          source += values[1];
          sourceLine += values[2];
          sourceColumn += values[3];
          String? named;
          if (values.length >= 5) {
            name += values[4];
            if (name >= 0 && name < names.length) named = '${names[name]}';
          }
          lines[line].add(
            _Segment(at, first + source, sourceLine, sourceColumn, named),
          );
        } else {
          lines[line].add(_Segment(at, -1, 0, 0, null));
        }
      }
      line++;
      first0 = false;
    }
    for (final segments in lines) {
      segments.sort((a, b) => a.column.compareTo(b.column));
    }
  }

  static String _resolve(String? url, String root, String source) {
    var path = source;
    if (root.isNotEmpty) {
      path = root.endsWith('/') ? '$root$source' : '$root/$source';
    }
    if (url == null || url.startsWith('data:')) return path;
    try {
      return Uri.parse(url).resolve(path).toString();
    } on FormatException {
      return path;
    }
  }

  static const _base64 =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  static List<int> _vlq(String piece) {
    final out = <int>[];
    var value = 0;
    var shift = 0;
    for (final char in piece.codeUnits) {
      final digit = _base64.indexOf(String.fromCharCode(char));
      if (digit < 0) break;
      value += (digit & 31) << shift;
      if (digit & 32 != 0) {
        shift += 5;
        continue;
      }
      out.add(value & 1 == 1 ? -(value >> 1) : value >> 1);
      value = 0;
      shift = 0;
    }
    return out;
  }

  /// The sources' URLs, resolved.
  final List<String> sources;
  final List<String?> _contents;
  final Set<int> _ignored;

  /// Whether the map says [source] is a library's (its ignore list).
  bool ignored(int source) => _ignored.contains(source);

  /// Each generated line's segments, by column.
  final List<List<_Segment>> _lines;

  Map<int, List<_Segment>>? _bySource;

  /// [source]'s text, if the map has it.
  String? content(int source) =>
      source >= 0 && source < _contents.length ? _contents[source] : null;

  /// Where the script's [line] and [column] (from 0) came from; null where
  /// nothing maps.
  SourcePosition? original(int line, int column) {
    if (line < 0 || line >= _lines.length) return null;
    final segments = _lines[line];
    var low = 0;
    var high = segments.length - 1;
    _Segment? found;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (segments[mid].column <= column) {
        found = segments[mid];
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    // Before the line's first: its first, as DevTools does.
    found ??= segments.isEmpty ? null : segments.first;
    if (found == null || found.source < 0) return null;
    return SourcePosition(
      sources[found.source],
      found.source,
      found.sourceLine,
      found.sourceColumn,
      found.name,
    );
  }

  /// Where [source]'s [line] (from 0) is in the script: its first piece
  /// there, else on the nearest line after (up to a few); null if none.
  ({int line, int column})? generated(int source, int line) {
    final index = _bySource ??= _index();
    final segments = index[source];
    if (segments == null) return null;
    ({int line, int column})? best;
    var bestLine = 1 << 30;
    for (final s in segments) {
      if (s.sourceLine < line || s.sourceLine > line + 5) continue;
      final at = (line: s.generatedLine, column: s.column);
      if (s.sourceLine < bestLine ||
          (s.sourceLine == bestLine &&
              (at.line < best!.line ||
                  (at.line == best.line && at.column < best.column)))) {
        best = at;
        bestLine = s.sourceLine;
      }
    }
    return best;
  }

  Map<int, List<_Segment>> _index() {
    final index = <int, List<_Segment>>{};
    for (final (line, segments) in _lines.indexed) {
      for (final s in segments) {
        if (s.source < 0) continue;
        (index[s.source] ??= []).add(s..generatedLine = line);
      }
    }
    return index;
  }

  /// The pieces from [fromLine] to [toLine] (the script's, from 0) that
  /// name something of the source (a variable, a function): where, and
  /// its name there.
  Iterable<({int line, int column, String name})> named(
    int fromLine,
    int toLine,
  ) sync* {
    for (
      var line = fromLine.clamp(0, _lines.length);
      line <= toLine && line < _lines.length;
      line++
    ) {
      for (final s in _lines[line]) {
        if (s.name case final name?) {
          yield (line: line, column: s.column, name: name);
        }
      }
    }
  }

  /// The source whose URL ends with [path] (or has it), best first: an
  /// exact end over a part.
  int? find(String path) {
    if (path.isEmpty) return null;
    int? part;
    for (final (i, source) in sources.indexed) {
      if (source == path || source.endsWith('/$path')) return i;
      if (part == null && source.contains(path)) part = i;
    }
    return part;
  }
}

class _Segment {
  _Segment(
    this.column,
    this.source,
    this.sourceLine,
    this.sourceColumn,
    this.name,
  );

  final int column;
  final int source;
  final int sourceLine;
  final int sourceColumn;
  final String? name;

  /// Set as the map is indexed by source.
  int generatedLine = 0;
}

/// A place in a source a map names: [line] and [column] from 0.
class SourcePosition {
  const SourcePosition(
    this.url,
    this.source,
    this.line,
    this.column,
    this.name,
  );

  final String url;
  final int source;
  final int line;
  final int column;

  /// The name there (the function's, a variable's), if the map says.
  final String? name;

  /// As a person reads it: its path short, lines and columns from 1.
  @override
  String toString() => '${shortSource(url)}:${line + 1}:${column + 1}';
}

/// A source's URL as it is read: `webpack://app/./src/App.tsx` as
/// `src/App.tsx`.
String shortSource(String url) {
  var path = url;
  final scheme = RegExp(r'^[a-z][a-z0-9+.-]*://[^/]*/').firstMatch(path);
  if (scheme != null) path = path.substring(scheme.end);
  path = path.replaceFirst(RegExp(r'^(\./)+'), '');
  return path.isEmpty ? url : path;
}

/// The name of the function [source] has its [line] and [column] (from 0)
/// in, as written: what a minified script's calls are named by. Read off
/// the blocks around it (a function's head before its `{`); null if none
/// says, or an anonymous one's.
String? enclosingFunction(String source, int line, int column) {
  var offset = 0;
  for (var i = 0; i < line; i++) {
    final next = source.indexOf('\n', offset);
    if (next < 0) return null;
    offset = next + 1;
  }
  offset = (offset + column).clamp(0, source.length);
  var depth = 0;
  for (var i = offset - 1; i >= 0 && offset - i < 100000; i--) {
    final char = source.codeUnitAt(i);
    if (char == 0x7d) {
      depth++;
    } else if (char == 0x7b) {
      if (depth > 0) {
        depth--;
        continue;
      }
      // A block around it: what opens it, back to the last statement.
      var start = i;
      while (start > 0 && i - start < 300) {
        final c = source.codeUnitAt(start - 1);
        if (c == 0x3b || c == 0x7b || c == 0x7d) break;
        start--;
      }
      final head = source
          .substring(start, i)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      switch (_functionHead(head)) {
        case final String name:
          return name.isEmpty ? null : name;
        case null:
          continue;
      }
    }
  }
  return null;
}

const _notFunctions = {
  'if', 'for', 'while', 'switch', 'catch', 'with', 'function', 'return', //
  'else', 'do', 'try', 'finally', 'class', 'constructor', 'super',
};

/// A function's name, if [head] opens one (`''`: an anonymous one); null
/// if it opens something else (an if's block, an object, a class).
String? functionName(String head) => _functionHead(head.trim());

/// A function's name, if [head] opens one (`''`: an anonymous one); null
/// if it opens something else (an if's block, an object, a class).
String? _functionHead(String head) {
  const params = r'\((?:[^()]|\([^()]*\))*\)';
  const type = r'(?:\s*:\s*[^=]+?)?';
  const name = r'([\w$]+)';
  final patterns = [
    RegExp('function\\s*\\*?\\s*$name\\s*(?:<[^>]*>)?\\s*$params$type\$'),
    RegExp('$name\\s*[=:]\\s*(?:async\\s+)?function\\b[^=]*\$'),
    RegExp(
      '$name\\s*[=:]\\s*(?:async\\s*)?(?:$params|[\\w\$]+)$type\\s*=>\\s*\$',
    ),
  ];
  for (final pattern in patterns) {
    if (pattern.firstMatch(head) case final m?) return m[1];
  }
  // A method: `async save(a, b) {`.
  final method = RegExp(
    '(?:^|[\\s,(])(?:(?:async|static|get|set|public|private|protected)\\s+)*'
    '\\*?$name\\s*(?:<[^>]*>)?\\s*$params$type\$',
  ).firstMatch(head);
  if (method != null && !_notFunctions.contains(method[1])) return method[1];
  if (RegExp('(?:=>|\\bfunction\\s*\\*?\\s*$params$type)\\s*\$')
      .hasMatch(head)) {
    return '';
  }
  return null;
}

/// [expression] with its variables' names ([names]: as written, to the
/// script's) as the script has them: what is evaluated in a minified
/// script's call. Strings and properties (`a.name`, `{name: 1}`) are kept.
String renameVariables(String expression, Map<String, String> names) {
  if (names.isEmpty) return expression;
  final out = StringBuffer();
  final identifier = RegExp(r'[A-Za-z_$][\w$]*');
  var i = 0;
  while (i < expression.length) {
    final char = expression[i];
    if (char == '"' || char == "'" || char == '`') {
      var end = i + 1;
      while (end < expression.length && expression[end] != char) {
        if (expression[end] == r'\') end++;
        end++;
      }
      end = (end + 1).clamp(0, expression.length);
      out.write(expression.substring(i, end));
      i = end;
      continue;
    }
    final match = identifier.matchAsPrefix(expression, i);
    if (match == null ||
        (i > 0 && RegExp(r'[\w$]').hasMatch(expression[i - 1]))) {
      out.write(char);
      i++;
      continue;
    }
    final name = match[0]!;
    final before = expression.substring(0, i).trimRight();
    final after = expression.substring(match.end).trimLeft();
    final property =
        before.endsWith('.') ||
        (after.startsWith(':') &&
            !after.startsWith('::') &&
            RegExp(r'[{,]$').hasMatch(before));
    out.write(property ? name : names[name] ?? name);
    i = match.end;
  }
  return out.toString();
}
