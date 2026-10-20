import 'package:flutter/foundation.dart';

/// Where a conversation stays as the reply to a message sent comes:
/// settings.json's `chat.replyScroll`, as Settings → Appearance picks it.
/// Unset: [follow].
enum ReplyScroll {
  /// At its end, following what is written.
  follow,

  /// Following it only until the message sent is at the top, the reply's
  /// start under it: then it stays, to read from there. Back at the end,
  /// the user scrolled, it follows again.
  start;

  static const settingKey = 'chat.replyScroll';

  /// [value] as settings.json has it.
  static ReplyScroll parse(Object? value) =>
      value == start.name ? start : follow;

  /// As settings.json keeps it; null (not written) for [follow].
  Object? get setting => this == follow ? null : name;

  /// What the chats do now; main() keeps it to settings.json ([keep]).
  static final ValueNotifier<ReplyScroll> current = ValueNotifier(follow);

  /// Sets [current] from [read] now and whenever [changes] notifies.
  static void keep(Listenable changes, Object? Function() read) {
    void update() => current.value = parse(read());
    update();
    changes.addListener(update);
  }
}
