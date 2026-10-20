import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// The composer's [QuillController]: keeps an input method's edit from
/// turning the tags and images before it into text, and a replacement in a
/// URL from putting its text in the wrong place.
///
/// Quill finds what the input method changed assuming the caret ends the
/// text it put in. One that shows a suggestion after the caret while
/// composing (an inline emoji, `ni hc〔表情：👋〕`) breaks that: the change
/// found then starts before the composition and takes in what precedes it,
/// embeds as the U+FFFC standing for them, which it puts back as text (drawn
/// as a boxed "OBJ" on Windows 10). Leaving out what such a replacement keeps
/// as it was leaves those embeds be.
///
/// Its text is plain: no style goes on it, by whatever way Quill has to put
/// one (a shortcut, a link, a paste with its styles).
class ComposerController extends QuillController {
  ComposerController({
    required super.document,
    required super.selection,
    super.config,
  });

  ComposerController.basic({super.config})
    : super(
        document: Document(),
        selection: const TextSelection.collapsed(offset: 0),
      );

  /// Only a style taken off (Backspace at the start of a line takes its
  /// block's): ⌘2 made the line a header, its text and the placeholder
  /// several times their size.
  @override
  void formatText(
    int index,
    int len,
    Attribute? attribute, {
    bool shouldNotifyListeners = true,
  }) {
    if (attribute?.value != null) return;
    super.formatText(
      index,
      len,
      attribute,
      // ignore: experimental_member_use
      shouldNotifyListeners: shouldNotifyListeners,
    );
  }

  @override
  void replaceText(
    int index,
    int len,
    Object? data,
    TextSelection? textSelection, {
    bool ignoreFocus = false,
    bool shouldNotifyListeners = true,
  }) {
    if (data is String &&
        len > 0 &&
        data.contains(Embed.kObjectReplacementCharacter)) {
      final old = document.toPlainText().substring(index, index + len);
      final shorter = math.min(old.length, data.length);
      var head = 0;
      while (head < shorter && old.codeUnitAt(head) == data.codeUnitAt(head)) {
        head++;
      }
      // Not between the halves of a surrogate pair.
      if (head > 0 && _isLeadSurrogate(old.codeUnitAt(head - 1))) head--;
      var tail = 0;
      while (tail < shorter - head &&
          old.codeUnitAt(old.length - 1 - tail) ==
              data.codeUnitAt(data.length - 1 - tail)) {
        tail++;
      }
      if (tail > 0 && _isTrailSurrogate(old.codeUnitAt(old.length - tail))) {
        tail--;
      }
      index += head;
      len -= head + tail;
      data = data.substring(head, data.length - tail);
    }
    // Quill puts the text in before it deletes what it replaces, by its
    // rules after that; the one that finds links puts it at [index] all the
    // same (typed into a URL), so the delete takes the head of what was
    // put in and the text replaced stays, after it. Deleted first, there is
    // nothing after it to put wrong.
    if (data is String && data.isNotEmpty && len > 0) {
      super.replaceText(
        index,
        len,
        '',
        null,
        ignoreFocus: ignoreFocus,
        // ignore: experimental_member_use
        shouldNotifyListeners: false,
      );
      len = 0;
    }
    super.replaceText(
      index,
      len,
      data,
      textSelection,
      ignoreFocus: ignoreFocus,
      // ignore: experimental_member_use
      shouldNotifyListeners: shouldNotifyListeners,
    );
  }
}

bool _isLeadSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isTrailSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
