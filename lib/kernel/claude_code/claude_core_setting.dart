/// Settings → General → Claude Code: what runs a Claude Code session
/// (`claudeCode.core` in settings.json).
enum ClaudeCore {
  /// Caocode's own core, written in Dart (package:bao_agent): the same
  /// protocol, files and settings as the CLI, in the app itself. It runs
  /// on the upstreams of Settings → Models alone, never on a model the
  /// machine's Claude Code setup names.
  builtin,

  /// The Claude Code CLI, as a process.
  cli;

  static const settingKey = 'claudeCode.core';

  /// When the setting is unset, or not one of these: the CLI where Claude
  /// Code is installed on this machine, else the built-in core.
  static ClaudeCore get fallback => cliInstalled() ? cli : builtin;

  /// Whether Claude Code is installed on this machine, as last looked;
  /// main() points it at `LocalClaude.installed`.
  static bool Function() cliInstalled = () => false;

  static ClaudeCore parse(Object? setting) =>
      values.where((value) => value.name == setting).firstOrNull ?? fallback;

  /// The setting as it is now, read as each session starts; main() points
  /// it at settings.json.
  static ClaudeCore Function() current = () => fallback;

  /// Why [builtin] has nothing to run on: no upstream turned on.
  static const noModel =
      'No model to run on: Caocode\'s own core runs on the upstreams of '
      'Settings → Models. Add one there, or switch the core to the Claude '
      'Code CLI in Settings → General.';
}
