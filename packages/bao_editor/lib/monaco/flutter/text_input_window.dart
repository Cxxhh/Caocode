import 'package:flutter/services.dart';

/// An edit of a document, as the platform's text input made it in a
/// [TextInputWindow]: `[start, end)` replaced by [text], then [selection]
/// and [composing], all in document offsets. No text replaced is a
/// selection (or composing) change.
typedef TextInputEdit = ({
  int start,
  int end,
  String text,
  TextSelection selection,
  TextRange composing,
});

/// The part of a document the platform's text input is given, as Monaco's
/// hidden textarea holds the lines around the selection, not the model:
/// an input method needs the text around the caret, and the whole of a
/// large file, sent at every key and back, is what typing would wait for.
///
/// It is the lines around the selection and the composing range
/// ([contextLines] before and after, at most [contextUnits] UTF-16 units
/// each way). A selection longer than [selectionUnits] is shortened to its
/// start and its end: typed over, it is replaced whole all the same.
class TextInputWindow {
  TextInputWindow._(
    this.start,
    this.end,
    this.value,
    this._selectionStart,
    this._selectionEnd,
    this._windowSelectionStart,
    this._windowSelectionEnd,
  );

  static const contextLines = 2;
  static const contextUnits = 1000;
  static const selectionUnits = 10000;

  /// The window around [document]'s selection and composing range.
  factory TextInputWindow.around(TextEditingValue document) {
    final text = document.text;
    final (low, high) = _span(document);
    final start = _lineStartBefore(text, low);
    final end = _lineEndAfter(text, high);
    final selection = document.selection;
    if (!_isComposing(document.composing, text.length) &&
        selection.isValid &&
        selection.end - selection.start > selectionUnits) {
      return _shortenedAround(document, start, end);
    }
    return _over(document, start, end);
  }

  /// The window of [document] from [start] to [end], when its selection and
  /// composing range are in it and it is not too long to keep; else null.
  static TextInputWindow? within(
    TextEditingValue document,
    int start,
    int end,
  ) {
    final length = document.text.length;
    if (start < 0 || end > length || start > end) return null;
    if (end - start > 2 * (selectionUnits + 2 * contextUnits)) return null;
    final (low, high) = _span(document);
    if (low < start || high > end) return null;
    if (_splits(document.text, start) || _splits(document.text, end)) {
      return null;
    }
    return _over(document, start, end);
  }

  /// Document offset of the window's first code unit.
  final int start;

  /// Document offset just past the window's last code unit.
  final int end;

  /// What the platform's text input is given: the window's text, and its
  /// selection and composing range as offsets into it.
  final TextEditingValue value;

  /// The selection, in the document and in [value]; they differ in length
  /// when it was shortened.
  final int _selectionStart;
  final int _selectionEnd;
  final int _windowSelectionStart;
  final int _windowSelectionEnd;

  bool get _isShortened =>
      _windowSelectionEnd - _windowSelectionStart !=
      _selectionEnd - _selectionStart;

  /// The document offset of [offset] in [value]. In a shortened selection,
  /// where nothing tells which of its units it is: its start, or its end
  /// for the [end] of a range.
  int _toDocument(int offset, {bool end = false}) {
    if (offset < 0) return offset;
    if (!_isShortened || offset <= _windowSelectionStart) return start + offset;
    if (offset >= _windowSelectionEnd) {
      return _selectionEnd + offset - _windowSelectionEnd;
    }
    return end ? _selectionEnd : _selectionStart;
  }

  /// The document edit the platform made, [next] being its value of this
  /// window after it.
  TextInputEdit edit(TextEditingValue next) {
    final before = value.text;
    final after = next.text;
    if (before == after) {
      return (
        start: start,
        end: start,
        text: '',
        selection: _selectionToDocument(next.selection, _toDocument),
        composing: _rangeToDocument(next.composing, _toDocument),
      );
    }
    // The change starts at the selection at the latest and ends at its end
    // at the earliest, as typing replaces the selection: an "a" typed after
    // an "a" is put where the caret was, not after the first "a".
    final old = value.selection;
    final valid = old.isValid && old.start >= 0 && old.end <= before.length;
    final maxPrefix = valid ? old.start : before.length;
    final maxSuffix = valid ? before.length - old.end : before.length;
    var prefix = 0;
    while (prefix < maxPrefix &&
        prefix < after.length &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < maxSuffix &&
        suffix < before.length - prefix &&
        suffix < after.length - prefix &&
        before.codeUnitAt(before.length - suffix - 1) ==
            after.codeUnitAt(after.length - suffix - 1)) {
      suffix++;
    }
    final startOffset = _toDocument(prefix);
    final endOffset = _toDocument(before.length - suffix, end: true);
    final inserted = after.substring(prefix, after.length - suffix);
    final delta = inserted.length - (endOffset - startOffset);
    // Offsets into [next]: before the change as they were, in it from its
    // start, after it as they were, moved by what it changed.
    int map(int offset, {bool end = false}) {
      if (offset < 0) return offset;
      if (offset <= prefix) return _toDocument(offset);
      if (offset <= prefix + inserted.length) {
        return startOffset + offset - prefix;
      }
      final old = offset - (after.length - before.length);
      return _toDocument(old, end: true) + delta;
    }

    return (
      start: startOffset,
      end: endOffset,
      text: inserted,
      selection: _selectionToDocument(next.selection, map),
      composing: _rangeToDocument(next.composing, map),
    );
  }

  static TextSelection _selectionToDocument(
    TextSelection selection,
    int Function(int offset, {bool end}) map,
  ) {
    if (!selection.isValid) return selection;
    final forward = selection.baseOffset <= selection.extentOffset;
    return selection.copyWith(
      baseOffset: map(selection.baseOffset, end: !forward),
      extentOffset: map(selection.extentOffset, end: forward),
    );
  }

  static TextRange _rangeToDocument(
    TextRange range,
    int Function(int offset, {bool end}) map,
  ) {
    if (!range.isValid) return range;
    return TextRange(start: map(range.start), end: map(range.end, end: true));
  }

  static TextInputWindow _over(TextEditingValue document, int start, int end) {
    final selection = document.selection;
    final composing = document.composing;
    TextSelection shiftSelection(TextSelection s) => s.isValid
        ? s.copyWith(
            baseOffset: s.baseOffset - start,
            extentOffset: s.extentOffset - start,
          )
        : s;
    TextRange shiftRange(TextRange r) =>
        r.isValid ? TextRange(start: r.start - start, end: r.end - start) : r;
    final selectionStart = selection.isValid ? selection.start : start;
    final selectionEnd = selection.isValid ? selection.end : start;
    return TextInputWindow._(
      start,
      end,
      TextEditingValue(
        text: document.text.substring(start, end),
        selection: shiftSelection(selection),
        composing: shiftRange(composing),
      ),
      selectionStart,
      selectionEnd,
      selectionStart - start,
      selectionEnd - start,
    );
  }

  static TextInputWindow _shortenedAround(
    TextEditingValue document,
    int start,
    int end,
  ) {
    final text = document.text;
    final selection = document.selection;
    var head = selection.start + selectionUnits ~/ 2;
    if (_splits(text, head)) head--;
    var tail = selection.end - selectionUnits ~/ 2;
    if (_splits(text, tail)) tail++;
    final selected =
        '${text.substring(selection.start, head)}'
        '${text.substring(tail, selection.end)}';
    final windowStart = selection.start - start;
    final windowEnd = windowStart + selected.length;
    final forward = selection.baseOffset <= selection.extentOffset;
    return TextInputWindow._(
      start,
      end,
      TextEditingValue(
        text:
            text.substring(start, selection.start) +
            selected +
            text.substring(selection.end, end),
        selection: TextSelection(
          baseOffset: forward ? windowStart : windowEnd,
          extentOffset: forward ? windowEnd : windowStart,
          affinity: selection.affinity,
        ),
      ),
      selection.start,
      selection.end,
      windowStart,
      windowEnd,
    );
  }

  /// The document range the window must hold: the selection and the
  /// composing range (the start of the text without either).
  static (int, int) _span(TextEditingValue document) {
    final length = document.text.length;
    var low = length;
    var high = 0;
    final selection = document.selection;
    if (selection.isValid) {
      low = selection.start.clamp(0, length);
      high = selection.end.clamp(0, length);
    }
    final composing = document.composing;
    if (_isComposing(composing, length)) {
      if (composing.start < low) low = composing.start;
      if (composing.end > high) high = composing.end;
    }
    if (low > high) return (0, 0);
    return (low, high);
  }

  static bool _isComposing(TextRange composing, int length) =>
      composing.isValid && !composing.isCollapsed && composing.end <= length;

  static bool _isBreak(int unit) => unit == 0x0A || unit == 0x0D;

  /// Whether [offset] falls between the halves of a surrogate pair or of a
  /// CRLF.
  static bool _splits(String text, int offset) {
    if (offset <= 0 || offset >= text.length) return false;
    final before = text.codeUnitAt(offset - 1);
    final at = text.codeUnitAt(offset);
    return (before >= 0xD800 &&
            before <= 0xDBFF &&
            at >= 0xDC00 &&
            at <= 0xDFFF) ||
        (before == 0x0D && at == 0x0A);
  }

  /// The start of the line [contextLines] lines before [offset]'s, at most
  /// [contextUnits] before it.
  static int _lineStartBefore(String text, int offset) {
    final limit = offset - contextUnits;
    var lines = 0;
    var i = offset;
    while (i > 0 && i > limit) {
      final unit = text.codeUnitAt(i - 1);
      if (_isBreak(unit)) {
        if (lines == contextLines) break;
        lines++;
        if (unit == 0x0A && i > 1 && text.codeUnitAt(i - 2) == 0x0D) i--;
      }
      i--;
    }
    if (_splits(text, i)) i--;
    return i < 0 ? 0 : i;
  }

  /// The end of the line [contextLines] lines after [offset]'s, at most
  /// [contextUnits] after it.
  static int _lineEndAfter(String text, int offset) {
    final limit = offset + contextUnits;
    var lines = 0;
    var i = offset;
    while (i < text.length && i < limit) {
      final unit = text.codeUnitAt(i);
      if (_isBreak(unit)) {
        if (lines == contextLines) break;
        lines++;
        if (unit == 0x0D &&
            i + 1 < text.length &&
            text.codeUnitAt(i + 1) == 0x0A) {
          i++;
        }
      }
      i++;
    }
    if (_splits(text, i)) i++;
    return i > text.length ? text.length : i;
  }
}
