import 'dart:convert';
import 'dart:io';

import 'codex_environment.dart';
import 'codex_host.dart';

CodexEnvironmentBackend codexEnvironmentBackend() =>
    IoCodexEnvironmentBackend();

/// WSL writes its distribution list as UTF-16 on Windows, while commands
/// executed inside a distribution use UTF-8.
String decodeWslOutput(List<int> bytes) {
  if (bytes.contains(0) ||
      (bytes.length >= 2 && bytes[0] == 255 && bytes[1] == 254)) {
    return String.fromCharCodes([
      for (
        var i = bytes.length >= 2 && bytes[0] == 255 && bytes[1] == 254 ? 2 : 0;
        i + 1 < bytes.length;
        i += 2
      )
        bytes[i] | bytes[i + 1] << 8,
    ]).replaceAll('\ufeff', '');
  }
  return utf8.decode(bytes, allowMalformed: true).replaceAll('\ufeff', '');
}

List<String> wsl2Distributions(String output) => [
  for (final line in output.split('\n'))
    if (RegExp(r'^\s*\*?\s*(.+?)\s{2,}\S+\s+2\s*$').firstMatch(line)
        case final match?)
      match.group(1)!.trim(),
];

class IoCodexEnvironmentBackend implements CodexEnvironmentBackend {
  @override
  bool get supported => Platform.isWindows;

  @override
  Future<List<String>> distributions() async {
    try {
      final result = await Process.run(
        'wsl.exe',
        ['--list', '--verbose'],
        stdoutEncoding: null,
        stderrEncoding: null,
      ).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) {
        throw const FileSystemException('无法列出 WSL2 发行版，请确认 WSL2 已安装。');
      }
      return wsl2Distributions(decodeWslOutput(result.stdout as List<int>));
    } on ProcessException {
      // Windows Codex remains available on machines without WSL installed.
      return const [];
    }
  }

  @override
  Future<String> home(CodexEnvironment environment) async {
    if (!environment.isWsl) {
      final home = Platform.environment['USERPROFILE'];
      if (home == null || home.isEmpty) {
        throw const FileSystemException('无法读取 Windows 用户目录。');
      }
      return home;
    }
    final result = await Process.run('wsl.exe', [
      '--distribution',
      environment.distribution!,
      '--exec',
      'bash',
      '-lic',
      r'printf "__CAOCODE_HOME__\n%s\n" "$HOME"',
    ]).timeout(const Duration(seconds: 30));
    final home = '${result.stdout}'.split('__CAOCODE_HOME__\n').last.trim();
    if (result.exitCode != 0 || !home.startsWith('/') || home.contains('\n')) {
      throw const FileSystemException('无法打开 WSL2 用户目录，请确认所选发行版可以启动。');
    }
    return wslWindowsPath('//wsl.localhost/${environment.distribution}$home');
  }

  @override
  Future<bool> exists(String path) => Directory(path).exists();
}
