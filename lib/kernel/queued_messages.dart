/// When a message sent while the agent works is taken up: the
/// `chat.queuedMessages` setting. Read as each message is sent, so a change
/// applies to those sent after it.
enum QueuedMessages {
  /// Once the turn running ends, one after another.
  afterTurn,

  /// In the turn running, between its tool calls, as Claude Code does in
  /// its own terminal.
  duringTurn;

  static const settingKey = 'chat.queuedMessages';

  /// When the setting is unset, or not one of these.
  static const fallback = afterTurn;

  static QueuedMessages parse(Object? setting) =>
      values.where((value) => value.name == setting).firstOrNull ?? fallback;

  /// The setting as it is now; main() points it at settings.json.
  static QueuedMessages Function() current = () => fallback;
}
