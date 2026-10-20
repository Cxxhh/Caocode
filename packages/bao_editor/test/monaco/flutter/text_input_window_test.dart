import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bao_editor/monaco/flutter/text_input_window.dart';

String _lines(int count) =>
    List.generate(count, (i) => 'line $i').join('\n');

/// [document] with the window's edit to it, as the editor applies it.
TextEditingValue _apply(TextEditingValue document, TextInputEdit edit) =>
    TextEditingValue(
      text: document.text.replaceRange(edit.start, edit.end, edit.text),
      selection: edit.selection,
      composing: edit.composing,
    );

void main() {
  test('holds the lines around the caret, not the document', () {
    final text = _lines(100);
    final caret = text.indexOf('line 50') + 2;
    final document = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    );
    final window = TextInputWindow.around(document);
    expect(window.value.text, 'line 48\nline 49\nline 50\nline 51\nline 52');
    expect(text.substring(window.start, window.end), window.value.text);
    expect(window.value.selection.baseOffset, caret - window.start);
  });

  test('is cut at contextUnits on a long line', () {
    final text = 'a' * 5000;
    final document = TextEditingValue(
      text: text,
      selection: const TextSelection.collapsed(offset: 2500),
    );
    final window = TextInputWindow.around(document);
    expect(window.start, 2500 - TextInputWindow.contextUnits);
    expect(window.end, 2500 + TextInputWindow.contextUnits);
  });

  test('maps typing, deleting and newlines to document offsets', () {
    var document = TextEditingValue(
      text: _lines(100),
      selection: const TextSelection.collapsed(offset: 400),
    );
    // Each the same at the caret of the window and of the whole document.
    final edits = <TextEditingValue Function(TextEditingValue)>[
      (v) => v.replaced(v.selection, 'a'),
      (v) => v.replaced(v.selection, 'a'),
      (v) => v.replaced(v.selection, '\n'),
      (v) => v.replaced(
        TextRange(start: v.selection.start - 1, end: v.selection.start),
        '',
      ),
      (v) => v.replaced(
        TextRange(start: v.selection.start - 1, end: v.selection.start),
        '',
      ),
    ];
    for (final make in edits) {
      final window = TextInputWindow.around(document);
      final expected = make(document);
      document = _apply(document, window.edit(make(window.value)));
      expect(document.text, expected.text);
      expect(document.selection, expected.selection);
    }
  });

  test('a repeated character typed goes where the caret was', () {
    const document = TextEditingValue(
      text: 'xaay',
      selection: TextSelection.collapsed(offset: 2),
    );
    final window = TextInputWindow.around(document);
    final edit = window.edit(
      const TextEditingValue(
        text: 'xaaay',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    expect((edit.start, edit.end, edit.text), (2, 2, 'a'));
  });

  test('maps the composing range and a selection change', () {
    final text = _lines(50);
    final caret = text.indexOf('line 20') + 4;
    final document = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    );
    final window = TextInputWindow.around(document);
    final local = caret - window.start;
    final composing = window.edit(
      TextEditingValue(
        text: window.value.text.replaceRange(local, local, 'ni'),
        selection: TextSelection.collapsed(offset: local + 2),
        composing: TextRange(start: local, end: local + 2),
      ),
    );
    expect((composing.start, composing.end, composing.text), (
      caret,
      caret,
      'ni',
    ));
    expect(composing.composing, TextRange(start: caret, end: caret + 2));
    expect(composing.selection, TextSelection.collapsed(offset: caret + 2));
    final moved = window.edit(
      window.value.copyWith(
        selection: TextSelection(baseOffset: local, extentOffset: local - 3),
      ),
    );
    expect(moved.text, isEmpty);
    expect(moved.start, moved.end);
    expect(
      moved.selection,
      TextSelection(baseOffset: caret, extentOffset: caret - 3),
    );
  });

  test('a long selection is shortened and replaced whole', () {
    final text = 'head\n${'b' * 50000}\ntail';
    final document = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: 5, extentOffset: 5 + 50000),
    );
    final window = TextInputWindow.around(document);
    expect(
      window.value.text.length,
      lessThan(TextInputWindow.selectionUnits + 3000),
    );
    final selection = window.value.selection;
    expect(
      selection.end - selection.start,
      TextInputWindow.selectionUnits,
    );
    final edit = window.edit(
      TextEditingValue(
        text: window.value.text.replaceRange(
          selection.start,
          selection.end,
          'x',
        ),
        selection: TextSelection.collapsed(offset: selection.start + 1),
      ),
    );
    expect((edit.start, edit.end, edit.text), (5, 50005, 'x'));
    expect(edit.selection, const TextSelection.collapsed(offset: 6));
    expect(_apply(document, edit).text, 'head\nx\ntail');
    // A backward selection keeps its direction.
    final backward = TextInputWindow.around(
      document.copyWith(
        selection: TextSelection(baseOffset: 50005, extentOffset: 5),
      ),
    );
    expect(
      backward.value.selection.baseOffset,
      greaterThan(backward.value.selection.extentOffset),
    );
    final unchanged = backward.edit(backward.value);
    expect(
      unchanged.selection,
      const TextSelection(baseOffset: 50005, extentOffset: 5),
    );
  });

  test('never splits a CRLF or a surrogate pair', () {
    final crlf = List.generate(10, (i) => 'r$i').join('\r\n');
    final at = crlf.indexOf('r5');
    final window = TextInputWindow.around(
      TextEditingValue(
        text: crlf,
        selection: TextSelection.collapsed(offset: at),
      ),
    );
    expect(window.value.text, 'r3\r\nr4\r\nr5\r\nr6\r\nr7');
    final emoji = '😀' * 1000;
    final emojiWindow = TextInputWindow.around(
      TextEditingValue(
        text: emoji,
        selection: const TextSelection.collapsed(offset: 1000),
      ),
    );
    for (final offset in [emojiWindow.start, emojiWindow.end]) {
      if (offset > 0 && offset < emoji.length) {
        expect(emoji.codeUnitAt(offset - 1), inInclusiveRange(0xDC00, 0xDFFF));
      }
    }
    expect(
      TextInputWindow.within(
        TextEditingValue(
          text: crlf,
          selection: TextSelection.collapsed(offset: at),
        ),
        crlf.indexOf('\n') - 0,
        crlf.length,
      ),
      isNull,
    );
  });

  test('within keeps a window holding the selection, else null', () {
    final text = _lines(100);
    final document = TextEditingValue(
      text: text,
      selection: const TextSelection.collapsed(offset: 300),
    );
    final kept = TextInputWindow.within(document, 250, 350);
    expect(kept, isNotNull);
    expect(kept!.value.text, text.substring(250, 350));
    expect(kept.value.selection, const TextSelection.collapsed(offset: 50));
    expect(TextInputWindow.within(document, 310, 350), isNull);
    expect(TextInputWindow.within(document, 0, text.length + 1), isNull);
  });
}
