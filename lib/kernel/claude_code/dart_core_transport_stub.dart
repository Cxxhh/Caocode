import 'claude_code_transport.dart';

abstract final class DartCoreTransport {
  static Future<ClaudeCodeTransport> start(ClaudeLaunch launch) async =>
      throw const ClaudeUnavailable(
        'Claude Code runs in the desktop app',
        detail: 'The browser cannot run the agent.',
      );
}
