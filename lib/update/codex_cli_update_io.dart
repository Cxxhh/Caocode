import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:path/path.dart' as p;

import '../kernel/codex/codex_cli_io.dart';
import '../kernel/codex/codex_host.dart';
import '../kernel/codex/codex_path_setting.dart';
import '../network/network_proxy_io.dart';
import 'codex_cli_update.dart';
import 'version.dart';

CodexCliUpdateService codexCliUpdates({String? cwd}) =>
    CodexCliUpdateService(IoCodexCliUpdateBackend(cwd: cwd));

typedef CliProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
  Duration timeout,
);

class IoCodexCliUpdateBackend implements CodexCliUpdateBackend {
  IoCodexCliUpdateBackend({
    this.cwd,
    Future<Map<String, String>> Function()? environment,
    Future<Map<String, String>> Function()? proxy,
    CliProcessRunner? run,
    bool? windows,
  }) : _environment = environment ?? ClaudeEnvironment.of,
       _proxy = proxy ?? (() => NetworkProxy.instance.environment()),
       _run = run ?? _runProcess,
       _windows = windows ?? Platform.isWindows;

  final String? cwd;
  final Future<Map<String, String>> Function() _environment;
  final Future<Map<String, String>> Function() _proxy;
  final CliProcessRunner _run;
  final bool _windows;
  _CliTarget? _target;

  @override
  Future<CodexCliInstallation> inspect() async {
    final environment = {...await _environment(), ...await _proxy()};
    final wsl = _windows ? wslProject(cwd) : null;
    final CodexCli cli;
    final String real;
    if (wsl == null) {
      cli = CodexCli.locate(environment, cwd: cwd);
      real = await File(cli.arguments.isEmpty ? cli.path : cli.arguments.first)
          .resolveSymbolicLinks();
    } else {
      final result = await _run(
        'wsl.exe',
        [
          '--distribution',
          wsl.distribution,
          '--cd',
          wsl.path,
          '--exec',
          'bash',
          '-lic',
          r'cli=$(command -v -- "${1:-${CAOCODE_CODEX_PATH:-codex}}") || exit 1; '
              r'printf "__CAOCODE_CLI__\n%s\n%s\n" "$cli" "$(readlink -f -- "$cli")"',
          'caocode',
          CodexPathSetting.forLocation(cwd, windows: _windows) ?? '',
        ],
        environment,
        const Duration(seconds: 20),
      );
      _requireSuccess(result);
      final lines = '${result.stdout}'
          .split('__CAOCODE_CLI__\n')
          .last
          .trim()
          .split('\n');
      if (lines.length != 2 ||
          !p.posix.isAbsolute(lines.first) ||
          !p.posix.isAbsolute(lines.last)) {
        throw const FormatException('无法确定 WSL 中的 Codex CLI 路径。');
      }
      cli = CodexCli(lines.first, lines.first, const []);
      real = lines.last;
    }
    final target = _CliTarget(cli, environment, wsl, _run);
    final versionResult = await target.runCli(['--version']);
    _requireSuccess(versionResult);
    final versionMatch = RegExp(
      r'^codex-cli\s+(\S+)',
      multiLine: true,
    ).firstMatch('${versionResult.stdout}'.trim());
    final version = AppVersion.tryParse(versionMatch?.group(1) ?? '');
    if (version == null) throw const FormatException('无法读取 Codex CLI 版本。');
    target.npm = await _npmCommand(real, target);
    if (target.npm == null) {
      final help = await target.runCli(['--help']);
      target.selfUpdate =
          help.exitCode == 0 &&
          RegExp(r'^\s+update\s+', multiLine: true).hasMatch('${help.stdout}');
    }
    _target = target;
    return CodexCliInstallation(
      path: cli.path,
      host: wsl == null
          ? (_windows ? 'Windows' : Platform.operatingSystem)
          : 'WSL · ${wsl.distribution}',
      version: version,
      canUpdate: target.npm != null || target.selfUpdate,
    );
  }

  /// Match npm's actual package tree, retaining its global prefix (e.g. nvm).
  Future<({String executable, List<String> arguments})?> _npmCommand(
    String real,
    _CliTarget target,
  ) async {
    final windows = _windows && target.wsl == null;
    final paths = windows ? p.windows : p.posix;
    final root = paths.dirname(paths.dirname(real));
    if (paths.basename(root) != 'codex' ||
        paths.basename(paths.dirname(root)) != '@openai' ||
        paths.basename(paths.dirname(paths.dirname(root))) != 'node_modules') {
      return null;
    }
    final manifest = File(target.localPath(paths.join(root, 'package.json')));
    if (!await manifest.exists()) return null;
    if ((jsonDecode(await manifest.readAsString()) as Map)['name'] !=
        '@openai/codex') {
      return null;
    }
    var prefix = paths.dirname(paths.dirname(paths.dirname(root)));
    if (!windows) {
      if (paths.basename(prefix) != 'lib') return null;
      prefix = paths.dirname(prefix);
    }
    if (windows) {
      final script = paths.join(
        prefix,
        'node_modules',
        'npm',
        'bin',
        'npm-cli.js',
      );
      if (!await File(script).exists()) return null;
      return (
        executable: target.cli.executable,
        arguments: [script, 'install', '--global', '--prefix', prefix],
      );
    }
    final npm = paths.join(prefix, 'bin', 'npm');
    if (!await File(target.localPath(npm)).exists()) return null;
    return (
      executable: npm,
      arguments: ['install', '--global', '--prefix', prefix],
    );
  }

  @override
  Future<AppVersion> latestVersion() async {
    final route = await NetworkProxy.instance.resolve();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..findProxy = route.findProxy;
    try {
      final request = await client
          .getUrl(Uri.parse('https://registry.npmjs.org/@openai/codex/latest'))
          .timeout(const Duration(seconds: 20));
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Codex 版本检查失败：HTTP ${response.statusCode}');
      }
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 20));
      final version = AppVersion.tryParse(
        (jsonDecode(body) as Map)['version'] as String? ?? '',
      );
      if (version == null) throw const FormatException('Codex 版本信息无效。');
      return version;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> update(
    CodexCliInstallation installation,
    AppVersion version,
  ) async {
    // A path setting may have changed since the user checked. Do not upgrade
    // the previous installation, nor silently substitute the new one.
    final now = await inspect();
    if (now.path != installation.path || now.host != installation.host) {
      throw StateError('Codex CLI 路径已更改，请重新检查更新。');
    }
    final target = _target!;
    final npm = target.npm;
    final ProcessResult result;
    if (npm != null) {
      result = await target.run(npm.executable, [
        ...npm.arguments,
        '@openai/codex@${version.marketing}',
        '--no-audit',
        '--no-fund',
      ], timeout: const Duration(minutes: 5));
    } else if (target.selfUpdate) {
      result = await target.runCli([
        'update',
      ], timeout: const Duration(minutes: 5));
    } else {
      throw UnsupportedError('此安装不支持自动更新，请使用原安装方式升级 Codex CLI。');
    }
    _requireSuccess(result);
  }
}

class _CliTarget {
  _CliTarget(this.cli, this.environment, this.wsl, this.runner);
  final CodexCli cli;
  final Map<String, String> environment;
  final WslProject? wsl;
  final CliProcessRunner runner;
  ({String executable, List<String> arguments})? npm;
  bool selfUpdate = false;

  String localPath(String path) => wsl == null ? path : '${wsl!.prefix}$path';

  Future<ProcessResult> runCli(
    List<String> args, {
    Duration timeout = const Duration(seconds: 20),
  }) => run(cli.executable, [...cli.arguments, ...args], timeout: timeout);

  Future<ProcessResult> run(
    String program,
    List<String> args, {
    required Duration timeout,
  }) {
    if (wsl case final host?) {
      return runner(
        'wsl.exe',
        [
          '--distribution',
          host.distribution,
          '--cd',
          host.path,
          '--exec',
          'bash',
          '-lic',
          r'exec "$1" "${@:2}"',
          'caocode',
          program,
          ...args,
        ],
        environment,
        timeout,
      );
    }
    return runner(program, args, environment, timeout);
  }
}

void _requireSuccess(ProcessResult result) {
  if (result.exitCode == 0) return;
  final output = '${result.stderr}\n${result.stdout}'.trim();
  throw ProcessException(
    'Codex CLI',
    const [],
    output.isEmpty ? '命令执行失败' : output,
    result.exitCode,
  );
}

Future<ProcessResult> _runProcess(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
  Duration timeout,
) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
  );
  unawaited(process.stdin.close());
  final stdout = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final stderr = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  try {
    final result = await Future.wait<Object>([process.exitCode, stdout, stderr])
        .timeout(timeout);
    return ProcessResult(process.pid, result[0] as int, result[1], result[2]);
  } on TimeoutException {
    process.kill();
    throw TimeoutException('Codex CLI 命令超时，请检查网络后重试。', timeout);
  }
}
