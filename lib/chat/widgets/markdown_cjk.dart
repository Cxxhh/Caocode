import 'package:markdown/markdown.dart' as md;

/// `*emphasis*` and `**strong**` as CommonMark parses them, but beside
/// Chinese, Japanese or Korean text too: there punctuation is written
/// without spaces around it, and CommonMark's flanking rules would leave
/// `**新版应遵循。**这条` unclosed (the closing run follows `。` and
/// comes before `这`). As markdown-cjk-friendly: a run next to a CJK
/// character on either side flanks whatever punctuation is on the other.
class CjkEmphasisSyntax extends md.DelimiterSyntax {
  CjkEmphasisSyntax()
    : super(
        r'\*+',
        requiresDelimiterRun: true,
        allowIntraWord: true,
        tags: _tags,
        startCharacter: 0x2A, // *
      );

  static final _tags = [md.DelimiterTag('em', 1), md.DelimiterTag('strong', 2)];

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final runStart = parser.pos;
    final runEnd = runStart + match.group(0)!.length;
    final source = parser.source;
    final node = md.Text(source.substring(runStart, runEnd));
    final before = runStart == 0 ? null : _runeBefore(source, runStart);
    final after = runEnd == source.length ? null : _runeAt(source, runEnd);
    final beforeSpace = before == null || _isWhitespace(before);
    final afterSpace = after == null || _isWhitespace(after);
    final beforePunctuation = !beforeSpace && _isPunctuation(before);
    final afterPunctuation = !afterSpace && _isPunctuation(after);
    final cjk = _isCjk(before) || _isCjk(after);
    final left =
        !afterSpace &&
        (!afterPunctuation || beforeSpace || beforePunctuation || cjk);
    final right =
        !beforeSpace &&
        (!beforePunctuation || afterSpace || afterPunctuation || cjk);
    // The run's own constructor is the library's: one is had by parsing a
    // run with the same flanking in a text of ours.
    final at = _flanking[(left, right)]!;
    final run = md.DelimiterRun.tryParse(
      _sample,
      at,
      at + 1,
      syntax: this,
      tags: _tags,
      node: node,
      allowIntraWord: true,
    );
    if (run == null) {
      parser.advanceBy(runEnd - runStart);
      return false;
    }
    parser.pushDelimiter(run);
    parser.addNode(node);
    return true;
  }

  /// A run of each flanking, by (left, right): where its `*` is in
  /// [_sample].
  static const _flanking = {
    (true, true): 1,
    (true, false): 4,
    (false, true): 8,
    (false, false): 10,
  };
  static final _sample = md.InlineParser('a*a *a a* * ', md.Document());

  static int _runeBefore(String text, int index) {
    final last = text.codeUnitAt(index - 1);
    if (_isLowSurrogate(last) && index >= 2) {
      final high = text.codeUnitAt(index - 2);
      if (_isHighSurrogate(high)) return _combine(high, last);
    }
    return last;
  }

  static int _runeAt(String text, int index) {
    final first = text.codeUnitAt(index);
    if (_isHighSurrogate(first) && index + 1 < text.length) {
      final low = text.codeUnitAt(index + 1);
      if (_isLowSurrogate(low)) return _combine(first, low);
    }
    return first;
  }

  static bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
  static int _combine(int high, int low) =>
      0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);

  static bool _isWhitespace(int rune) =>
      md.DelimiterRun.unicodeWhitespace.contains(String.fromCharCode(rune));

  static bool _isPunctuation(int? rune) =>
      rune != null &&
      md.DelimiterRun.unicodePunctuationPattern.hasMatch(
        String.fromCharCode(rune),
      );

  /// Han, kana, Hangul, and the CJK punctuation and full-width forms.
  static bool _isCjk(int? rune) {
    if (rune == null) return false;
    return (rune >= 0x1100 && rune <= 0x11FF) || // Hangul Jamo
        (rune >= 0x2E80 && rune <= 0x2FDF) || // radicals
        (rune >= 0x3000 && rune <= 0x303F) || // CJK symbols and punctuation
        (rune >= 0x3040 && rune <= 0x30FF) || // kana
        (rune >= 0x3100 && rune <= 0x31FF) || // Bopomofo, kana extensions
        (rune >= 0x3200 && rune <= 0x4DBF) || // enclosed, Ext A
        (rune >= 0x4E00 && rune <= 0x9FFF) || // unified ideographs
        (rune >= 0xA960 && rune <= 0xA97F) || // Hangul Jamo Ext A
        (rune >= 0xAC00 && rune <= 0xD7FF) || // Hangul syllables
        (rune >= 0xF900 && rune <= 0xFAFF) || // compatibility ideographs
        (rune >= 0xFE30 && rune <= 0xFE4F) || // compatibility forms
        (rune >= 0xFF00 && rune <= 0xFFEF) || // full-width forms
        (rune >= 0x20000 && rune <= 0x3FFFF); // Ext B and on
  }
}
