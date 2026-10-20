import 'package:flutter/services.dart';

/// The DevTools protocol's modifiers (`Input.dispatch…Event`'s).
abstract final class BrowserModifiers {
  static const alt = 1;
  static const control = 2;
  static const meta = 4;
  static const shift = 8;

  /// The keyboard's, as now pressed.
  static int get keyboard {
    final keys = HardwareKeyboard.instance;
    return (keys.isAltPressed ? alt : 0) |
        (keys.isControlPressed ? control : 0) |
        (keys.isMetaPressed ? meta : 0) |
        (keys.isShiftPressed ? shift : 0);
  }
}

/// Keys that type nothing: the page has them as keys even while an input
/// method composes elsewhere (not while it composes).
final Set<PhysicalKeyboardKey> browserControlKeys = {
  PhysicalKeyboardKey.backspace,
  PhysicalKeyboardKey.delete,
  PhysicalKeyboardKey.enter,
  PhysicalKeyboardKey.numpadEnter,
  PhysicalKeyboardKey.tab,
  PhysicalKeyboardKey.escape,
  PhysicalKeyboardKey.arrowLeft,
  PhysicalKeyboardKey.arrowRight,
  PhysicalKeyboardKey.arrowUp,
  PhysicalKeyboardKey.arrowDown,
  PhysicalKeyboardKey.home,
  PhysicalKeyboardKey.end,
  PhysicalKeyboardKey.pageUp,
  PhysicalKeyboardKey.pageDown,
  for (final key in _functionKeys) key,
};

final _letters = [
  PhysicalKeyboardKey.keyA,
  PhysicalKeyboardKey.keyB,
  PhysicalKeyboardKey.keyC,
  PhysicalKeyboardKey.keyD,
  PhysicalKeyboardKey.keyE,
  PhysicalKeyboardKey.keyF,
  PhysicalKeyboardKey.keyG,
  PhysicalKeyboardKey.keyH,
  PhysicalKeyboardKey.keyI,
  PhysicalKeyboardKey.keyJ,
  PhysicalKeyboardKey.keyK,
  PhysicalKeyboardKey.keyL,
  PhysicalKeyboardKey.keyM,
  PhysicalKeyboardKey.keyN,
  PhysicalKeyboardKey.keyO,
  PhysicalKeyboardKey.keyP,
  PhysicalKeyboardKey.keyQ,
  PhysicalKeyboardKey.keyR,
  PhysicalKeyboardKey.keyS,
  PhysicalKeyboardKey.keyT,
  PhysicalKeyboardKey.keyU,
  PhysicalKeyboardKey.keyV,
  PhysicalKeyboardKey.keyW,
  PhysicalKeyboardKey.keyX,
  PhysicalKeyboardKey.keyY,
  PhysicalKeyboardKey.keyZ,
];

final _digits = [
  PhysicalKeyboardKey.digit0,
  PhysicalKeyboardKey.digit1,
  PhysicalKeyboardKey.digit2,
  PhysicalKeyboardKey.digit3,
  PhysicalKeyboardKey.digit4,
  PhysicalKeyboardKey.digit5,
  PhysicalKeyboardKey.digit6,
  PhysicalKeyboardKey.digit7,
  PhysicalKeyboardKey.digit8,
  PhysicalKeyboardKey.digit9,
];

final _functionKeys = [
  PhysicalKeyboardKey.f1,
  PhysicalKeyboardKey.f2,
  PhysicalKeyboardKey.f3,
  PhysicalKeyboardKey.f4,
  PhysicalKeyboardKey.f5,
  PhysicalKeyboardKey.f6,
  PhysicalKeyboardKey.f7,
  PhysicalKeyboardKey.f8,
  PhysicalKeyboardKey.f9,
  PhysicalKeyboardKey.f10,
  PhysicalKeyboardKey.f11,
  PhysicalKeyboardKey.f12,
];

/// [key]'s Windows key code (`VK_…`, the page's `keyCode`); 0 for a key
/// not known here.
int browserKeyCode(PhysicalKeyboardKey key) => _codes[key] ?? 0;

final Map<PhysicalKeyboardKey, int> _codes = {
  // Letters: VK_A… VK_Z; digits: VK_0… VK_9.
  for (final (i, key) in _letters.indexed) key: 0x41 + i,
  for (final (i, key) in _digits.indexed) key: 0x30 + i,
  PhysicalKeyboardKey.equal: 0xBB,
  PhysicalKeyboardKey.minus: 0xBD,
  PhysicalKeyboardKey.bracketRight: 0xDD,
  PhysicalKeyboardKey.bracketLeft: 0xDB,
  PhysicalKeyboardKey.quote: 0xDE,
  PhysicalKeyboardKey.semicolon: 0xBA,
  PhysicalKeyboardKey.backslash: 0xDC,
  PhysicalKeyboardKey.comma: 0xBC,
  PhysicalKeyboardKey.slash: 0xBF,
  PhysicalKeyboardKey.period: 0xBE,
  PhysicalKeyboardKey.backquote: 0xC0,
  PhysicalKeyboardKey.enter: 0x0D,
  PhysicalKeyboardKey.numpadEnter: 0x0D,
  PhysicalKeyboardKey.tab: 0x09,
  PhysicalKeyboardKey.space: 0x20,
  PhysicalKeyboardKey.backspace: 0x08,
  PhysicalKeyboardKey.escape: 0x1B,
  PhysicalKeyboardKey.delete: 0x2E,
  PhysicalKeyboardKey.home: 0x24,
  PhysicalKeyboardKey.end: 0x23,
  PhysicalKeyboardKey.pageUp: 0x21,
  PhysicalKeyboardKey.pageDown: 0x22,
  PhysicalKeyboardKey.arrowLeft: 0x25,
  PhysicalKeyboardKey.arrowRight: 0x27,
  PhysicalKeyboardKey.arrowDown: 0x28,
  PhysicalKeyboardKey.arrowUp: 0x26,
  PhysicalKeyboardKey.shiftLeft: 0x10,
  PhysicalKeyboardKey.shiftRight: 0x10,
  PhysicalKeyboardKey.controlLeft: 0x11,
  PhysicalKeyboardKey.controlRight: 0x11,
  PhysicalKeyboardKey.altLeft: 0x12,
  PhysicalKeyboardKey.altRight: 0x12,
  PhysicalKeyboardKey.metaLeft: 0x5B,
  PhysicalKeyboardKey.metaRight: 0x5C,
  PhysicalKeyboardKey.capsLock: 0x14,
  // F1… F12: VK_F1… VK_F12.
  for (final (i, key) in _functionKeys.indexed) key: 0x70 + i,
};

/// The DOM's names of a key that types nothing ([browserControlKeys]): its
/// `key` and `code` (`ArrowLeft`, `F5`); null for any other.
String? browserKeyName(PhysicalKeyboardKey key) => _names[key];

final Map<PhysicalKeyboardKey, String> _names = {
  PhysicalKeyboardKey.backspace: 'Backspace',
  PhysicalKeyboardKey.delete: 'Delete',
  PhysicalKeyboardKey.enter: 'Enter',
  PhysicalKeyboardKey.numpadEnter: 'Enter',
  PhysicalKeyboardKey.tab: 'Tab',
  PhysicalKeyboardKey.escape: 'Escape',
  PhysicalKeyboardKey.arrowLeft: 'ArrowLeft',
  PhysicalKeyboardKey.arrowRight: 'ArrowRight',
  PhysicalKeyboardKey.arrowUp: 'ArrowUp',
  PhysicalKeyboardKey.arrowDown: 'ArrowDown',
  PhysicalKeyboardKey.home: 'Home',
  PhysicalKeyboardKey.end: 'End',
  PhysicalKeyboardKey.pageUp: 'PageUp',
  PhysicalKeyboardKey.pageDown: 'PageDown',
  for (final (i, key) in _functionKeys.indexed) key: 'F${i + 1}',
};
