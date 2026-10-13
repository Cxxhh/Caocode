import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:path/path.dart' as p;

import 'codex_host.dart';
import 'codex_config_file.dart';
import 'codex_provider_config.dart';

CodexConfigFile codexConfigFileAt(
  String path, {
  String? serverHome,
  String? distribution,
}) => _IoCodexConfigFile(
  path,
  serverHome: serverHome,
  distribution: distribution,
);
Future<CodexConfigFile> resolveCodexConfigFile({
  String? cwd,
  String? configPath,
  Map<String, String>? environment,
  bool? windows,
  Future<String> Function(String)? wslHome,
  Future<String> Function(String)? wslUserHome,
}) => _IoCodexConfigFile.resolve(
  cwd: cwd,
  configPath: configPath,
  environment: environment,
  windows: windows,
  wslHome: wslHome,
  wslUserHome: wslUserHome,
);

/// Resolves on the same host as app-server. Windows WSL projects read and
/// edit Linux files through their UNC path, never the Windows Codex home.
class _IoCodexConfigFile extends CodexConfigFile {
  _IoCodexConfigFile(this.path, {String? serverHome, this.distribution})
    : serverHome = serverHome ?? p.dirname(path);
  @override
  final String path;
  @override
  final String serverHome;
  final String? distribution;
  @override
  String get hostLabel =>
      distribution == null ? 'Codex' : 'WSL · $distribution';

  static Future<CodexConfigFile> resolve({
    String? cwd,
    String? configPath,
    Map<String, String>? environment,
    bool? windows,
    Future<String> Function(String)? wslHome,
    Future<String> Function(String)? wslUserHome,
  }) async {
    final win = windows ?? Platform.isWindows;
    final env = environment ?? await ClaudeEnvironment.of();
    final host = win ? wslProject(cwd) : null;
    final custom = configPath?.trim();
    if (host != null) {
      final home = await (wslHome ?? _wslHome)(host.distribution);
      String selected;
      if (custom == null || custom.isEmpty) {
        selected = p.posix.join(home, 'config.toml');
      } else {
        final unc = wslProject(custom);
        if (unc != null &&
            unc.distribution.toLowerCase() != host.distribution.toLowerCase()) {
          throw const FormatException('config.toml 必须属于当前工程的 WSL 发行版。');
        }
        selected = unc?.path ?? custom;
        if (selected.startsWith('~/')) {
          // CODEX_HOME may differ from HOME, so query the actual user home.
          final userHome = await (wslUserHome ?? _wslUserHome)(
            host.distribution,
          );
          selected = p.posix.join(userHome, selected.substring(2));
        }
        _validatePath(selected, p.posix);
      }
      selected = p.posix.normalize(selected);
      return _IoCodexConfigFile(
        '${host.prefix}$selected',
        serverHome: p.posix.dirname(selected),
        distribution: host.distribution,
      );
    }
    final context = win ? p.windows : p.posix;
    final userHome = env[win ? 'USERPROFILE' : 'HOME'];
    var selected = custom;
    if (selected == null || selected.isEmpty) {
      final home =
          env['CODEX_HOME'] ??
          (userHome == null ? null : context.join(userHome, '.codex'));
      if (home == null) throw const FileSystemException('无法找到 Codex 用户目录。');
      selected = context.join(home, 'config.toml');
    } else {
      if (selected.startsWith('~/') || selected.startsWith('~\\')) {
        if (userHome == null) throw const FileSystemException('无法展开用户目录。');
        selected = context.join(userHome, selected.substring(2));
      }
      if (win && wslProject(selected) != null) {
        throw const FormatException('请在 WSL 工程中设置 Linux Codex 配置路径。');
      }
      _validatePath(selected, context);
    }
    final absolute = context.normalize(
      context.isAbsolute(selected)
          ? selected
          : context.join(cwd ?? userHome ?? Directory.current.path, selected),
    );
    return _IoCodexConfigFile(absolute, serverHome: context.dirname(absolute));
  }

  static void _validatePath(String path, p.Context context) {
    if (!context.isAbsolute(path) || context.basename(path) != 'config.toml') {
      throw const FormatException('请填写绝对路径或 ~/ 路径，文件名必须为 config.toml。');
    }
  }

  static Future<String> _wslHome(String distribution) =>
      _wslPath(distribution, r'printf "%s" "${CODEX_HOME:-$HOME/.codex}"');
  static Future<String> _wslUserHome(String distribution) =>
      _wslPath(distribution, r'printf "%s" "$HOME"');
  static Future<String> _wslPath(String distribution, String script) async {
    final result = await Process.run('wsl.exe', [
      '--distribution',
      distribution,
      '--exec',
      'bash',
      '-lic',
      script,
    ]);
    final path = '${result.stdout}'.trim();
    if (result.exitCode != 0 || !p.posix.isAbsolute(path)) {
      throw const FileSystemException('无法读取 WSL 中的 Codex 配置目录。');
    }
    return path;
  }

  @override
  Future<String> read() async {
    final file = File(path);
    return await file.exists() ? await file.readAsString() : '';
  }

  @override
  Future<String?> importKey() async {
    final config = CodexProviderConfig(await read());
    if (config.apiKey != null) return config.apiKey;
    if (config.official ||
        config.table.containsKey('env_key') ||
        config.table.containsKey('auth') ||
        config.table.containsKey('http_headers')) {
      return null;
    }
    final file = File(p.join(p.dirname(path), 'auth.json'));
    if (!await file.exists()) return null;
    try {
      final auth = jsonDecode(await file.readAsString());
      return auth is Map && auth['OPENAI_API_KEY'] is String
          ? auth['OPENAI_API_KEY']
          : null;
    } catch (_) {
      throw const FormatException('auth.json 无法解析，请先修复后再导入供应商。');
    }
  }

  static final _writes = <String, Future<void>>{};
  Future<void> _serialized(Future<void> Function() action) {
    final previous = _writes[path] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .then((_) => action(), onError: (Object _) => action())
        .whenComplete(() {
          if (identical(_writes[path], next)) _writes.remove(path);
        });
    _writes[path] = next;
    return next;
  }

  @override
  Future<void> ensureExists() => _serialized(() async {
    if (await File(path).exists()) return;
    await _write('', '# Codex configuration\n');
  });

  @override
  Future<void> activate(
    CodexProviderConfig provider, {
    String? apiKey,
    CodexProviderConfig? outgoing,
  }) => _serialized(() async {
    provider.validate();
    final original = await read();
    final updated = provider.applyTo(
      original,
      apiKey: apiKey,
      outgoing: outgoing,
    );
    await _write(original, updated);
  });

  Future<void> _private(File file) async {
    final args = distribution == null
        ? ['600', file.path]
        : [
            '--distribution',
            distribution!,
            '--exec',
            'chmod',
            '600',
            wslProject(file.path)?.path ??
                p.posix.join(serverHome, p.basename(file.path)),
          ];
    if (Platform.isWindows && distribution == null) return;
    final result = await Process.run(
      distribution == null ? 'chmod' : 'wsl.exe',
      args,
    );
    if (result.exitCode != 0) throw const FileSystemException('无法设置配置文件的访问权限。');
  }

  Future<void> _write(String original, String updated) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    // Follow an existing symlink rather than replacing the link itself.
    final target = await file.exists()
        ? File(await file.resolveSymbolicLinks())
        : file;
    final temporary = File(
      '${target.path}.caocode-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.create(exclusive: true);
      await _private(temporary);
      await temporary.writeAsString(updated, flush: true);
      if (await read() != original) {
        throw const FileSystemException('config.toml 已被其他程序修改，请刷新后重试。');
      }
      if (await file.exists()) {
        final backup = File('$path.caocode.bak');
        await backup.create();
        await _private(backup);
        await backup.writeAsString(original, flush: true);
      }
      if (await read() != original) {
        throw const FileSystemException('config.toml 已被其他程序修改，请刷新后重试。');
      }
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
