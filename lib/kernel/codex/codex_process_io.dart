import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;

import '../../network/network_proxy_io.dart';
import '../../platform/child_process_registry.dart';
import '../../platform/data_dir.dart';
import 'codex_rpc.dart';
import 'codex_cli_io.dart';
import 'codex_path_setting.dart';
import 'codex_config_setting.dart';
import 'codex_config_file.dart';
import 'codex_host.dart';
import 'codex_transport.dart';
export 'codex_host.dart';

String? codexServerPath(String? path) =>
    Platform.isWindows ? wslProject(path)?.path ?? path : path;

String codexClientPath(String path, String? project) {
  final wsl = Platform.isWindows ? wslProject(project) : null;
  return wsl != null && path.startsWith('/')
      ? wslWindowsPath('${wsl.prefix}$path')
      : path;
}

CodexTransport localCodexTransport({String? cwd}) =>
    CodexProcessTransport(cwd: cwd);

Future<void> reapCodexProcesses() => CodexProcessTransport.registry.reaped;
Future<void> stopCodexProcesses() => CodexProcessTransport.stopAll();

/// Start on first RPC write, so hidden and unused conversations hold no process.
class CodexProcessTransport implements CodexTransport, CodexTransportLifecycle {
  CodexProcessTransport({this.cwd, this.executable, this.arguments = const []});

  final String? cwd;
  final String? executable;
  final List<String> arguments;
  final _messages = StreamController<Map<String, Object?>>.broadcast();
  final _stopped = Completer<void>();
  final List<String> _queued = [];
  final List<String> _stderr = [];
  Process? _process;
  bool _launching = false;
  bool _closing = false;
  Timer? _killTimer;

  static final _live = <CodexProcessTransport>{};
  static final registry = ChildProcessRegistry(
    file: File(DataDirectory.current.processRegistryFile('codex')),
    recognizes: (command) =>
        command.contains('codex') && command.contains('app-server'),
  );

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  Future<void> get stopped => _stopped.future;

  @override
  void write(Map<String, Object?> message) {
    if (_closing) throw const CodexRpcException('Codex CLI 连接已关闭');
    final line = jsonEncode(message);
    if (_process case final process?) {
      process.stdin.writeln(line);
    } else {
      _queued.add(line);
      if (!_launching) {
        _launching = true;
        unawaited(
          _launch()
              .catchError((Object error, StackTrace stack) {
                if (!_closing) _messages.addError(error, stack);
                close();
              })
              .whenComplete(() {
                if (!_stopped.isCompleted && _process == null) {
                  _stopped.complete();
                }
              }),
        );
      }
    }
  }

  Future<void> _launch() async {
    await registry.reaped;
    if (_closing) return;
    final wsl = Platform.isWindows ? wslProject(cwd) : null;
    var workingDirectory =
        cwd ??
        Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ??
        Directory.current.path;
    if (!Directory(workingDirectory).existsSync()) {
      throw CodexRpcException('工程目录不存在：$workingDirectory');
    }
    final environment = await ClaudeEnvironment.of();
    final proxy = await NetworkProxy.instance.environment();
    final configPath = CodexConfigSetting.forLocation(
      cwd,
      windows: Platform.isWindows,
    );
    final config = configPath == null
        ? null
        : await CodexConfigFile.resolve(
            cwd: cwd,
            configPath: configPath,
            environment: environment,
          );
    String program;
    List<String> launchArguments;
    if (executable != null) {
      program = executable!;
      launchArguments = arguments;
    } else if (wsl != null) {
      program = 'wsl.exe';
      launchArguments = [
        '--distribution',
        wsl.distribution,
        '--cd',
        wsl.path,
        '--exec',
        'bash',
        '-lic',
        r'if [ -n "$2" ]; then export CODEX_HOME="$2"; fi; '
            r'exec "${1:-${CAOCODE_CODEX_PATH:-codex}}" app-server --listen stdio://',
        'caocode',
        CodexPathSetting.forLocation(cwd, windows: true) ?? '',
        config?.serverHome ?? '',
      ];
      workingDirectory =
          Platform.environment['USERPROFILE'] ?? Directory.current.path;
    } else {
      final launch = CodexCli.locate(environment, cwd: cwd);
      program = launch.executable;
      launchArguments = [
        ...launch.arguments,
        'app-server',
        '--listen',
        'stdio://',
      ];
    }
    if (_closing) return;
    final process = await Process.start(
      program,
      launchArguments,
      workingDirectory: workingDirectory,
      environment: {
        ...environment,
        ...proxy,
        if (config != null && wsl == null) 'CODEX_HOME': config.serverHome,
      },
      includeParentEnvironment: Platform.isWindows,
    );
    _process = process;
    if (_closing) {
      process.kill();
      await process.exitCode;
      if (!_messages.isClosed) unawaited(_messages.close());
      if (!_stopped.isCompleted) _stopped.complete();
      return;
    }
    _live.add(this);
    unawaited(registry.add(process.pid));
    final stderrDone = Completer<void>();
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) {
            _stderr.add(line);
            if (_stderr.length > 20) _stderr.removeAt(0);
          },
          onError: (Object error) {
            _stderr.add('$error');
          },
          onDone: stderrDone.complete,
        );
    final stdoutDone = Completer<void>();
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final value = jsonDecode(line);
              if (value is Map<String, Object?> && !_messages.isClosed) {
                _messages.add(value);
              }
            } on FormatException {
              // Startup diagnostics are not part of the RPC stream.
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!_closing) _messages.addError(error, stack);
          },
          onDone: stdoutDone.complete,
        );
    for (final line in _queued) {
      process.stdin.writeln(line);
    }
    _queued.clear();
    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone.future, stderrDone.future]);
    _killTimer?.cancel();
    _live.remove(this);
    unawaited(registry.remove(process.pid));
    if (!_closing && !_messages.isClosed) {
      _messages.addError(
        CodexRpcException(
          'Codex CLI 已退出（$exitCode）'
          '${_stderr.isEmpty ? '' : '\n${_stderr.join('\n')}'}',
        ),
      );
    }
    if (!_messages.isClosed) unawaited(_messages.close());
    if (!_stopped.isCompleted) _stopped.complete();
  }

  @override
  void close() {
    if (_closing) return;
    _closing = true;
    _queued.clear();
    final process = _process;
    if (process == null) {
      if (!_messages.isClosed) unawaited(_messages.close());
      if (!_launching && !_stopped.isCompleted) {
        _stopped.complete();
      }
      return;
    }
    unawaited(process.stdin.close().catchError((Object _) {}));
    _killTimer = Timer(const Duration(seconds: 3), () {
      process.kill();
      _killTimer = Timer(const Duration(seconds: 2), () {
        process.kill(ProcessSignal.sigkill);
      });
    });
  }

  static Future<void> stopAll() async {
    for (final transport in [..._live]) {
      transport.close();
    }
    await Future.wait([
      for (final transport in [..._live]) transport.stopped,
    ]);
    await registry.flush();
  }
}
