import 'package:flutter/foundation.dart';

/// settings.json's `sidebar.showTimes`: whether the agents' rows in the
/// sidebar end with when each last did something, as Settings → Appearance
/// turns it on or off. Unset: on. Off, a row's hover still tells it.
abstract final class SidebarTimes {
  static const settingKey = 'sidebar.showTimes';

  /// Whether the rows show them now; main() keeps it to settings.json
  /// ([follow]).
  static final ValueNotifier<bool> shown = ValueNotifier(true);

  /// [value] as settings.json has it.
  static bool parse(Object? value) => value != false;

  /// [on] as settings.json keeps it; null (not written) for on.
  static Object? setting(bool on) => on ? null : false;

  /// Sets [shown] from [read] now and whenever [changes] notifies.
  static void follow(Listenable changes, Object? Function() read) {
    void update() => shown.value = parse(read());
    update();
    changes.addListener(update);
  }
}
