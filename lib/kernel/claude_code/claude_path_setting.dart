import 'local_claude_stub.dart' if (dart.library.io) 'local_claude_io.dart';

/// Settings → General → Claude Code: the build to run on this machine
/// (`claudeCode.path` in settings.json), e.g. one built from a fork; none
/// set, the newest of those installed and the one Caocode downloaded.
abstract final class ClaudePathSetting {
  static const settingKey = 'claudeCode.path';

  /// The path a setting's [value] names; null for none.
  static String? parse(Object? value) => switch (value) {
    final String path when path.trim().isNotEmpty => path.trim(),
    _ => null,
  };

  /// The path set now: main.dart reads it from settings.json.
  static String? Function() current = () => null;
}

/// The Claude Code that runs on this machine, as Settings shows it.
sealed class LocalClaudeStatus {
  const LocalClaudeStatus();
}

/// [path] runs, at [version] (null when it does not say); [downloaded]
/// when it is the one Caocode downloaded.
class LocalClaudeFound extends LocalClaudeStatus {
  const LocalClaudeFound(this.path, this.version, {this.downloaded = false});

  final String path;
  final String? version;
  final bool downloaded;
}

/// None yet: one is downloaded as the first conversation starts.
class LocalClaudeMissing extends LocalClaudeStatus {
  const LocalClaudeMissing();
}

/// None runs, for [message]: the path set is not there.
class LocalClaudeFailed extends LocalClaudeStatus {
  const LocalClaudeFailed(this.message);

  final String message;
}

/// The Claude Code that runs on this machine now, nothing downloaded for
/// it; null where there are no processes (the web).
Future<LocalClaudeStatus?> localClaudeStatus() => LocalClaude.status();
