import 'dart:io';

import 'package:path/path.dart' as p;

import 'codex_path_setting.dart';
import 'codex_rpc.dart';

/// The same executable and npm shim resolution for app-server and updates.
class CodexCli {
  const CodexCli(this.path, this.executable, this.arguments);

  final String path;
  final String executable;
  final List<String> arguments;

  static CodexCli locate(Map<String, String> environment, {String? cwd}) {
    final override =
        CodexPathSetting.forLocation(cwd, windows: Platform.isWindows) ??
        environment['CAOCODE_CODEX_PATH'];
    if (override != null &&
        override.isNotEmpty &&
        !File(override).existsSync()) {
      throw CodexRpcException('指定的 Codex CLI 路径不存在：$override');
    }
    final home = environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    final candidates = [
      if (override != null && override.isNotEmpty) override,
      for (final directory in (environment['PATH'] ?? '').split(
        Platform.isWindows ? ';' : ':',
      ))
        if (directory.isNotEmpty)
          for (final name
              in Platform.isWindows
                  ? ['codex.exe', 'codex.cmd', 'codex.ps1']
                  : ['codex'])
            p.join(directory, name),
      if (home != null && !Platform.isWindows)
        p.join(home, '.local', 'bin', 'codex'),
    ];
    for (final candidate in candidates) {
      if (!File(candidate).existsSync()) continue;
      if (!Platform.isWindows || candidate.toLowerCase().endsWith('.exe')) {
        return CodexCli(candidate, candidate, const []);
      }
      // Run npm's JavaScript entry point directly: no shell or script policy.
      final directory = p.dirname(candidate);
      final script = p.join(
        directory,
        'node_modules',
        '@openai',
        'codex',
        'bin',
        'codex.js',
      );
      if (File(script).existsSync()) {
        final node = p.join(directory, 'node.exe');
        return CodexCli(
          candidate,
          File(node).existsSync() ? node : 'node.exe',
          [script],
        );
      }
    }
    throw const CodexRpcException(
      '未找到 Codex CLI。请安装并登录 Codex，或设置 CAOCODE_CODEX_PATH。',
    );
  }
}
