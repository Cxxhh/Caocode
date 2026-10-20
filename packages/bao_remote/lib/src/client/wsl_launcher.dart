import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../rpc/rpc_peer.dart';
import 'remote_client.dart';
import 'ssh_launcher.dart' show RemoteServerBinaries;

/// A local WSL connection, using the same file protocol as SSH, without
/// a network listener, credentials, or an sshd inside the distribution.
class WslConnection {
  WslConnection(this.client, this._process);

  final RemoteClient client;
  final Process _process;

  void abort() {
    client.peer.close();
    _process.kill();
  }

  Future<void> close() async {
    try {
      await client.shutdown().timeout(const Duration(seconds: 2));
      await _process.exitCode.timeout(const Duration(seconds: 2));
    } finally {
      abort();
    }
  }

  static Future<WslConnection> start(
    String distribution,
    RemoteServerBinaries binaries,
  ) async {
    final version = binaries.version;
    if (!RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(version)) {
      throw const FormatException('无效的 WSL 文件服务版本');
    }
    List<String> command(String script) => [
      '--distribution',
      distribution,
      '--cd',
      '/',
      '--exec',
      'sh',
      '-c',
      script,
      'caocode',
      version,
    ];
    final probe = await _run(
      command(r'uname -m; test -x "$HOME/.caocode-server/$1/caocode-server"'),
    );
    final architecture = probe.stdout.toString().trim();
    final platform = switch (architecture) {
      'x86_64' => 'linux-x64',
      'aarch64' => 'linux-arm64',
      _ => throw FileSystemException('无法识别 WSL 架构：$architecture', distribution),
    };
    if (probe.exitCode != 0) {
      final bytes = await binaries.read(platform);
      if (bytes == null) {
        throw FileSystemException('此版本未包含 $platform 文件服务，请重新构建应用。');
      }
      final installed = await _run(
        command(
          r'set -eu; dir="$HOME/.caocode-server/$1"; '
          r'mkdir -p "$dir"; tmp=$(mktemp "$dir/.install.XXXXXX"); '
          r'''trap 'rm -f "$tmp"' EXIT; cat > "$tmp"; '''
          r'chmod 700 "$tmp"; mv -f "$tmp" "$dir/caocode-server"',
        ),
        input: bytes,
      );
      if (installed.exitCode != 0) {
        throw FileSystemException(
          'WSL 文件服务安装失败：${installed.stderr}',
          distribution,
        );
      }
    }
    final process = await Process.start(
      'wsl.exe',
      command(r'exec "$HOME/.caocode-server/$1/caocode-server"'),
      workingDirectory: Platform.environment['USERPROFILE'],
    );
    final errors = <String>[];
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          errors.add(line);
          if (errors.length > 20) errors.removeAt(0);
        });
    process.stdin.done.ignore();
    final peer = RpcPeer(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      process.stdin.writeln,
    );
    final connection = WslConnection(RemoteClient(peer), process);
    unawaited(process.exitCode.then((_) => peer.close()));
    try {
      await connection.client.initialize().timeout(const Duration(seconds: 15));
      return connection;
    } catch (error) {
      connection.abort();
      throw FileSystemException(
        'WSL 文件服务启动失败：$error\n${errors.join('\n')}',
        distribution,
      );
    }
  }

  static Future<ProcessResult> _run(
    List<String> arguments, {
    List<int>? input,
  }) async {
    final process = await Process.start(
      'wsl.exe',
      arguments,
      workingDirectory: Platform.environment['USERPROFILE'],
    );
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final errors = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      if (input != null) process.stdin.add(input);
      await process.stdin.close().timeout(const Duration(seconds: 15));
      final code = await process.exitCode.timeout(const Duration(seconds: 15));
      return ProcessResult(process.pid, code, await output, await errors);
    } finally {
      process.kill();
    }
  }
}
