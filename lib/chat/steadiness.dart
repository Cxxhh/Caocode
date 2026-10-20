import 'dart:async';

import 'package:flutter/foundation.dart';

/// Keeps what shows of a live turn only as long as it lasts (a closed run's
/// step under way, a thought opened as it streams) from flashing: it shows
/// once it has been wanted for [delay], and then for [hold] at least. What
/// is done sooner never shows; what showed does not go at once.
///
/// Asked as the history builds ([shows]); [onChange] is called when an
/// answer would be another, for it to build again. Timed by timers alone,
/// as a test's fake time runs them.
class Steadiness {
  Steadiness({
    required this.onChange,
    this.delay = const Duration(milliseconds: 300),
    this.hold = const Duration(milliseconds: 700),
  });

  final VoidCallback onChange;
  final Duration delay;
  final Duration hold;

  final Map<Object, _Steady> _entries = {};

  /// Whether what [key] names shows, [wanted] as it is now: once wanted for
  /// [delay] (at once, not [delayed]: e.g. a row that shows anyway, kept
  /// from going), and then for [hold] at least.
  bool shows(Object key, {required bool wanted, bool delayed = true}) {
    if (wanted) {
      final entry = _entries[key] ??= _Steady();
      entry.wanted = true;
      if (entry.shown) return true;
      if (!delayed || entry.ripe) {
        entry
          ..shown = true
          ..holding = true
          ..ripening?.cancel()
          ..ripening = null
          ..held = Timer(hold, () {
            entry.holding = false;
            if (!entry.wanted) onChange();
          });
        return true;
      }
      entry.ripening ??= Timer(delay, () {
        entry
          ..ripe = true
          ..ripening = null;
        onChange();
      });
      return false;
    }
    final entry = _entries[key];
    if (entry == null) return false;
    entry
      ..wanted = false
      ..ripe = false
      ..ripening?.cancel()
      ..ripening = null;
    if (entry.shown && entry.holding) return true;
    entry.held?.cancel();
    _entries.remove(key);
    return false;
  }

  /// Forgets all: the turn ended, or what the keys name moved.
  void clear() {
    for (final entry in _entries.values) {
      entry.ripening?.cancel();
      entry.held?.cancel();
    }
    _entries.clear();
  }

  void dispose() => clear();
}

class _Steady {
  /// Wanted as last asked.
  bool wanted = false;

  /// Wanted for long enough, and the timer that says so meanwhile.
  bool ripe = false;
  Timer? ripening;

  /// Shown, and not yet for long enough; the timer that says so.
  bool shown = false;
  bool holding = false;
  Timer? held;
}
