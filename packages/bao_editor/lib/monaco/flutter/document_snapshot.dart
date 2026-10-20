import 'dart:typed_data';

import '../vs/editor/common/core/position.dart';

/// Immutable UTF-16 line geometry for a Flutter text value.
///
/// Line arrays are zero-indexed; [Position] uses one-based line numbers and
/// columns. A CRLF is one newline of length two, while lone CR and LF are each
/// one newline. A final newline creates an empty trailing line.
class DocumentSnapshot {
  factory DocumentSnapshot(String text) {
    final starts = <int>[0];
    final ends = <int>[];
    final newlineLengths = <int>[];

    var offset = 0;
    while (offset < text.length) {
      final unit = text.codeUnitAt(offset);
      if (unit == 0x0D || unit == 0x0A) {
        final length =
            unit == 0x0D &&
                offset + 1 < text.length &&
                text.codeUnitAt(offset + 1) == 0x0A
            ? 2
            : 1;
        ends.add(offset);
        newlineLengths.add(length);
        offset += length;
        starts.add(offset);
      } else {
        offset++;
      }
    }
    ends.add(text.length);
    newlineLengths.add(0);

    return DocumentSnapshot._(
      text,
      _frozen(Int32List.fromList(starts)),
      _frozen(Int32List.fromList(ends)),
      _frozen(Int32List.fromList(newlineLengths)),
    );
  }

  /// [before] with `[start, end)` replaced by [inserted]: only the lines the
  /// edit touches are scanned, the others are copied (and moved), so typing
  /// in a large file does not go through all of its text.
  factory DocumentSnapshot.edited(
    DocumentSnapshot before,
    int start,
    int end,
    String inserted,
  ) {
    final old = before.text;
    final text = old.substring(0, start) + inserted + old.substring(end);
    final delta = inserted.length - (end - start);
    final oldStarts = before.lineStarts;
    final oldEnds = before.contentEnds;
    final oldNewlines = before.newlineLengths;
    final lineCount = oldStarts.length;
    // The first line changed: the one with the edit's start, or the one
    // before when its lone CR could take an inserted LF.
    var first = _lineAt(oldStarts, start);
    if (first > 0 && oldStarts[first] == start && oldNewlines[first - 1] == 1) {
      if (old.codeUnitAt(start - 1) == 0x0D) first--;
    }
    // The first line whose content goes on after the edit's end: its own
    // newline and every line after it are as they were, moved by delta.
    var last = _lineAt(oldStarts, end);
    while (last < lineCount && oldEnds[last] <= end) {
      last++;
    }
    final scanEnd = last < lineCount ? oldEnds[last] + delta : text.length;
    final starts = <int>[];
    final ends = <int>[];
    final newlines = <int>[];
    var offset = oldStarts[first];
    while (offset < scanEnd) {
      final unit = text.codeUnitAt(offset);
      if (unit == 0x0D || unit == 0x0A) {
        final length =
            unit == 0x0D &&
                offset + 1 < text.length &&
                text.codeUnitAt(offset + 1) == 0x0A
            ? 2
            : 1;
        ends.add(offset);
        newlines.add(length);
        offset += length;
        starts.add(offset);
      } else {
        offset++;
      }
    }
    final tail = last < lineCount ? lineCount - last - 1 : 0;
    final count = first + 1 + starts.length + tail;
    final newStarts = Int32List(count);
    final newEnds = Int32List(count);
    final newNewlines = Int32List(count);
    newStarts.setRange(0, first + 1, oldStarts);
    newEnds.setRange(0, first, oldEnds);
    newNewlines.setRange(0, first, oldNewlines);
    var line = first;
    for (var i = 0; i < starts.length; i++) {
      newEnds[line] = ends[i];
      newNewlines[line] = newlines[i];
      newStarts[++line] = starts[i];
    }
    // The line the scan stopped in ends where it did, with its old newline.
    newEnds[line] = scanEnd;
    newNewlines[line] = last < lineCount ? oldNewlines[last] : 0;
    for (var i = 1; i <= tail; i++) {
      newStarts[line + i] = oldStarts[last + i] + delta;
      newEnds[line + i] = oldEnds[last + i] + delta;
      newNewlines[line + i] = oldNewlines[last + i];
    }
    return DocumentSnapshot._(
      text,
      _frozen(newStarts),
      _frozen(newEnds),
      _frozen(newNewlines),
      before._editedTo(start, end, inserted.length),
    );
  }

  /// [text], [before] with `[start, end)` replaced, scanned whole: for many
  /// edits at once, [start] and [end] taking in them all.
  factory DocumentSnapshot.replaced(
    DocumentSnapshot before,
    String text,
    int start,
    int end,
  ) {
    final scanned = DocumentSnapshot(text);
    return DocumentSnapshot._(
      text,
      scanned.lineStarts,
      scanned.contentEnds,
      scanned.newlineLengths,
      before._editedTo(
        start,
        end,
        text.length - (before.text.length - (end - start)),
      ),
    );
  }

  /// The edits [_edits] keeps: enough for whoever has not seen the latest
  /// few, not to hold on to many.
  static const _keptEdits = 32;
  static int _nextId = 0;

  /// What sets this snapshot apart from the snapshots it was edited from.
  final int _id = _nextId++;

  /// The latest edits that made this snapshot from the ones before it,
  /// oldest first, each with the id of the snapshot it was made to. Not the
  /// snapshots themselves, which would keep every text before alive.
  final List<_Edit> _edits;

  List<_Edit> _editedTo(int start, int end, int length) => [
    ..._edits.length < _keptEdits
        ? _edits
        : _edits.sublist(_edits.length - _keptEdits + 1),
    (of: _id, start: start, end: end, length: length),
  ];

  /// How much of their text [old] and [next] share at the start and at the
  /// end (not overlapping) as far as the edits from one to the other tell,
  /// without reading the text; null when [next] was not edited from [old]
  /// recently. Each may be less than what they really share.
  static (int, int)? knownSharedEnds(
    DocumentSnapshot old,
    DocumentSnapshot next,
  ) {
    if (identical(old, next)) return (old.text.length, 0);
    final edits = next._edits;
    var i = edits.length - 1;
    while (i >= 0 && edits[i].of != old._id) {
      i--;
    }
    if (i < 0) return null;
    var length = old.text.length;
    var prefix = length;
    var suffix = length;
    for (; i < edits.length; i++) {
      final edit = edits[i];
      if (edit.start < prefix) prefix = edit.start;
      if (length - edit.end < suffix) suffix = length - edit.end;
      length += edit.length - (edit.end - edit.start);
    }
    return (prefix, suffix);
  }

  /// How much of their text [old] and [next] share at the start and at the
  /// end, not overlapping: from their edits when known, else read.
  static (int, int) sharedEnds(DocumentSnapshot old, DocumentSnapshot next) {
    final known = knownSharedEnds(old, next);
    if (known != null) return known;
    final a = old.text;
    final b = next.text;
    final shortest = a.length < b.length ? a.length : b.length;
    var prefix = 0;
    while (prefix < shortest && a.codeUnitAt(prefix) == b.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shortest - prefix &&
        a.codeUnitAt(a.length - 1 - suffix) ==
            b.codeUnitAt(b.length - 1 - suffix)) {
      suffix++;
    }
    return (prefix, suffix);
  }

  static List<int> _frozen(Int32List list) => list.asUnmodifiableView();

  /// The index of the line [offset] is in (the last starting at or before it).
  static int _lineAt(List<int> starts, int offset) {
    var low = 0;
    var high = starts.length;
    while (low < high) {
      final middle = low + ((high - low) ~/ 2);
      if (starts[middle] <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low - 1;
  }

  DocumentSnapshot._(
    this.text,
    this.lineStarts,
    this.contentEnds,
    this.newlineLengths, [
    this._edits = const [],
  ]);

  final String text;

  /// UTF-16 offsets of the first code unit on each line.
  final List<int> lineStarts;

  /// Exclusive UTF-16 end of each line's content, before its newline.
  final List<int> contentEnds;

  /// Number of newline code units after each line (0 on the final line).
  final List<int> newlineLengths;

  int get lineCount => lineStarts.length;

  /// Returns the one-based position at [offset], clamped to the document.
  ///
  /// An offset between CR and LF maps to the preceding line's end column.
  /// The binary search takes O(log lineCount) time.
  Position positionAtOffset(int offset) {
    final clamped = offset < 0
        ? 0
        : (offset > text.length ? text.length : offset);
    final line = _lineAt(lineStarts, clamped);
    final columnOffset = clamped > contentEnds[line]
        ? contentEnds[line]
        : clamped;
    return Position(line + 1, columnOffset - lineStarts[line] + 1);
  }

  /// Returns the UTF-16 offset of [position], clamping lines and columns.
  ///
  /// Columns count code units (including both halves of a surrogate pair) and
  /// stop at the content end, never inside a newline.
  int offsetAtPosition(IPosition position) {
    final line = position.lineNumber <= 1
        ? 0
        : (position.lineNumber >= lineCount
              ? lineCount - 1
              : position.lineNumber - 1);
    final start = lineStarts[line];
    final end = contentEnds[line];
    if (position.column <= 1) return start;
    if (position.column >= end - start + 1) return end;
    return start + position.column - 1;
  }
}

/// An edit of the snapshot with id [of]: `[start, end)` replaced by [length]
/// code units.
typedef _Edit = ({int of, int start, int end, int length});
