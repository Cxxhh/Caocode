/// Whether Claude Code suggests the next prompt after each turn (greyed out
/// in the composer, Tab to take it): the `chat.promptSuggestions` setting.
/// Each suggestion is a request of its own, with the whole conversation, so
/// it can be turned off to spare the tokens. Read as the agent starts, and
/// as each message is sent: a change restarts the agent with the next one.
abstract final class PromptSuggestions {
  static const settingKey = 'chat.promptSuggestions';

  /// Written when off; on, the setting is left out.
  static const off = false;

  /// On unless set to false.
  static bool enabled(Object? setting) => setting != false;

  /// The setting as it is now; main() points it at settings.json.
  static bool Function() current = () => true;
}
