import 'package:bao_remote/claude.dart'
    show ClaudeDownloadFailed, ClaudeNotInstalled;
import 'package:bao_remote/local.dart'
    show
        AppPaths,
        ClaudeCli,
        ClaudeRelease,
        ClaudeRuntime,
        ManagedClaude,
        machinePlatform;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../../network/network_proxy_io.dart';
import '../../platform/data_dir.dart';
import 'claude_code_transport.dart';
import 'claude_install_progress.dart';
import 'claude_path_setting.dart';

/// Claude Code on this machine, as VS Code's extension carries its own:
/// the one set in Settings ([ClaudePathSetting]), else the newest of the
/// user's builds and the one Caocode downloaded into the data folder for
/// them (see [ClaudeRuntime]), which is downloaded the first time the
/// user has none that runs. Its progress is [LocalClaudeInstall]'s.
abstract final class LocalClaude {
  static ClaudeRuntime? _runtime;

  static ClaudeRuntime get runtime => _runtime ??= ClaudeRuntime(
    managed: ManagedClaude(p.join(DataDirectory.current.path, 'claude')),
    platform: ClaudeRelease.platformOf(machinePlatform()),
    named: _named,
  );

  /// The path set in Settings, `~` its user's home.
  static ({String path, String undo})? _named(Map<String, String> env) {
    final path = ClaudePathSetting.current();
    if (path == null) return null;
    final home = AppPaths.home(env);
    return (
      path: path == '~' || path.startsWith('~/') || path.startsWith(r'~\')
          ? '$home${path.substring(1)}'
          : path,
      undo:
          'Correct it in Settings → General → Claude Code, or clear it to '
          'run the installed one.',
    );
  }

  /// The one that runs now, nothing downloaded for it.
  static Future<LocalClaudeStatus?> status() async {
    try {
      final cli = await runtime.locate();
      return LocalClaudeFound(
        cli.executable,
        await runtime.versionOf(cli),
        downloaded: runtime.isInstalled(cli),
      );
    } on ClaudeNotInstalled {
      return const LocalClaudeMissing();
    } on ClaudeUnavailable catch (error) {
      return LocalClaudeFailed(error.detail ?? error.message);
    }
  }

  /// Another runtime, e.g. one over a fake release under test; null for
  /// the data folder's.
  @visibleForTesting
  static set runtime(ClaudeRuntime? runtime) => _runtime = runtime;

  /// The CLI to run; one is downloaded where there is none, unless not
  /// to [install].
  static Future<ClaudeCli> locate({bool install = true}) async {
    if (!install) return runtime.locate();
    // Downloaded through the proxy as it is now: Clash may be on since.
    await NetworkProxy.instance.resolve(maxAge: NetworkProxy.connectionMaxAge);
    try {
      return await runtime.locate(onDownload: _progress);
    } on ClaudeDownloadFailed catch (error) {
      throw _downloadFailed(error);
    } finally {
      LocalClaudeInstall.instance.progress = null;
    }
  }

  /// [executable] refused an option Caocode starts it with: whether
  /// another, newer, may be run instead (see [ClaudeRuntime.rejectTooOld]).
  static Future<bool> rejectTooOld(String executable) async {
    try {
      return await runtime.rejectTooOld(executable, onDownload: _progress);
    } finally {
      LocalClaudeInstall.instance.progress = null;
    }
  }

  static void _progress(int received, int size) =>
      LocalClaudeInstall.instance.progress = ClaudeInstallProgress(
        received,
        size,
      );

  static ClaudeUnavailable _downloadFailed(ClaudeDownloadFailed error) =>
      ClaudeUnavailable(
        error.message,
        detail: [
          ?error.detail,
          'Check the network (or the proxy in Settings), then try again; or '
              'install Claude Code yourself:\n$installCommand',
        ].join('\n\n'),
      );

  /// Claude Code's own install command for this machine, as its install
  /// guidance gives it.
  static String get installCommand => machinePlatform().os == 'win'
      ? 'irm https://claude.ai/install.ps1 | iex'
      : 'curl -fsSL https://claude.ai/install.sh | bash';
}
