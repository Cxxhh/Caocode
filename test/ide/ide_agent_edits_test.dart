import 'package:bao_editor/monaco/flutter/document_snapshot.dart';
import 'package:bao_editor/monaco/vs/editor/common/diff/default_lines_diff_computer/default_lines_diff_computer.dart';
import 'package:bao_editor/monaco/vs/editor/common/diff/range_mapping.dart';
import 'package:caocode/ide/ide_agent_edits.dart';
import 'package:flutter_test/flutter_test.dart';

/// The changes from [original] to [modified], as the editor's diff has
/// them.
List<DetailedLineRangeMapping> _changes(
  DocumentSnapshot original,
  DocumentSnapshot modified,
) {
  List<String> lines(DocumentSnapshot text) => [
    for (var i = 0; i < text.lineCount; i++)
      text.text.substring(text.lineStarts[i], text.contentEnds[i]),
  ];
  return DefaultLinesDiffComputer()
      .computeDiff(
        lines(original),
        lines(modified),
        const LinesDiffComputerOptions(
          ignoreTrimWhitespace: false,
          maxComputationTimeMs: 0,
        ),
      )
      .changes;
}

/// [modified] with its first change from [original] taken out.
String _undoFirst(String original, String modified) {
  final o = DocumentSnapshot(original);
  final m = DocumentSnapshot(modified);
  final s = agentHunkSpans(_changes(o, m).first, o, m);
  return modified.replaceRange(
    s.modifiedStart,
    s.modifiedEnd,
    original.substring(s.originalStart, s.originalEnd),
  );
}

/// [original] with the first change to [modified] kept.
String _keepFirst(String original, String modified) {
  final o = DocumentSnapshot(original);
  final m = DocumentSnapshot(modified);
  return agentHunkKept(_changes(o, m).first, o, m);
}

void main() {
  const cases = {
    'a line changed': ('1\n2\n3\n', '1\ntwo\n3\n'),
    'lines added and removed apart': (
      '1\n2\n3\n4\n5\n',
      'one\n2\n3\n4\n5\n6\n',
    ),
    'a line added at the end, no line break after': ('a\nb', 'a\nb\nc'),
    'the last line removed, no line break after': ('a\nb\nc', 'a\nb'),
    'a line added first': ('b\nc\n', 'a\nb\nc\n'),
    'everything new': ('', 'x\ny\n'),
    'everything gone': ('x\ny\n', ''),
    'line breaks of their own': ('a\r\nb\r\n', 'a\r\nB\r\nc\r\n'),
  };

  for (final MapEntry(key: name, value: (original, modified))
      in cases.entries) {
    test('undoing each change in turn gives back the original: $name', () {
      var text = modified;
      for (var i = 0; i < 10 && text != original; i++) {
        text = _undoFirst(original, text);
      }
      expect(text, original);
    });

    test('keeping each change in turn gives the file: $name', () {
      var base = original;
      for (var i = 0; i < 10 && base != modified; i++) {
        base = _keepFirst(base, modified);
      }
      expect(base, modified);
    });
  }

  test('keeps one change and holds the file against it', () {
    const original = '1\n2\n3\n4\n5\n';
    const modified = 'one\n2\n3\n4\nfive\n';
    expect(_keepFirst(original, modified), 'one\n2\n3\n4\n5\n');
    expect(_undoFirst(original, modified), '1\n2\n3\n4\nfive\n');
  });
}
