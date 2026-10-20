/// A glob, as files are matched: `*` within a folder, `**` across
/// folders, `?` one character, `[abc]` one of a set, `{a,b}` one of the
/// alternatives. Paths are matched with `/` between folders.
class GlobPattern {
  GlobPattern(this.pattern, {this.caseSensitive = true})
    : _regExp = RegExp(
        '^${_translate(pattern)}\$',
        caseSensitive: caseSensitive,
      );

  final String pattern;
  final bool caseSensitive;
  final RegExp _regExp;

  bool matches(String path) => _regExp.hasMatch(path.replaceAll(r'\', '/'));

  /// Whether [pattern] has anything but plain characters.
  static bool isGlob(String pattern) => RegExp(r'[*?\[{]').hasMatch(pattern);

  /// The folder a pattern starts in before its first wildcard
  /// (`src/lib/**/*.dart` starts in `src/lib`).
  static String base(String pattern) {
    final parts = pattern.replaceAll(r'\', '/').split('/');
    final fixed = <String>[];
    for (final part in parts) {
      if (isGlob(part)) break;
      fixed.add(part);
    }
    if (fixed.length == parts.length) fixed.removeLast();
    return fixed.join('/');
  }

  static String _translate(String glob) {
    final out = StringBuffer();
    var inGroup = 0;
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      switch (c) {
        case '*':
          if (i + 1 < glob.length && glob[i + 1] == '*') {
            // `**/` matches no folder, or any number of them.
            final slash = i + 2 < glob.length && glob[i + 2] == '/';
            final atStart = i == 0 || glob[i - 1] == '/';
            if (slash && atStart) {
              out.write('(?:.*/)?');
              i += 2;
            } else {
              out.write('.*');
              i += 1;
            }
          } else {
            out.write('[^/]*');
          }
        case '?':
          out.write('[^/]');
        case '[':
          final end = glob.indexOf(']', i + 1);
          if (end < 0) {
            out.write(r'\[');
          } else {
            var set = glob.substring(i + 1, end);
            if (set.startsWith('!')) set = '^${set.substring(1)}';
            out.write('[${set.replaceAll(r'\', r'\\')}]');
            i = end;
          }
        case '{':
          inGroup++;
          out.write('(?:');
        case '}' when inGroup > 0:
          inGroup--;
          out.write(')');
        case ',' when inGroup > 0:
          out.write('|');
        default:
          out.write(RegExp.escape(c));
      }
    }
    return out.toString();
  }
}
