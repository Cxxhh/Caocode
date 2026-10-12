import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/local.dart' show ClaudeEnvironment;
import 'package:path/path.dart' as p;

import '../../network/network_proxy_io.dart';
import '../../platform/child_process_registry.dart';
import '../../platform/data_dir.dart';
import 'codex_rpc.dart';
import 'codex_path_setting.dart';
import 'codex_transport.dart';

typedef WslProject = ({String distribution, String path, String prefix});

WslProject? wslProject(String? path) {
  if (path == null) return null;
  final normalized = path.replaceAll('\\', '/');
  final match = RegExp(
    r'^//(wsl\.localhost|wsl\$)/([^/]+)(/.*)?$',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (match == null) return null;
  return (
    distribution: match.group(2)!,
    path: match.group(3) ?? '/',
    prefix: '//${match.group(1)}/${match.group(2)}',
  );
}

String? codexServerPath(String? path) =>
    Platform.isWindows ? wslProject(path)?.path ?? path : path;

String codexClientPath(String path, String? project) {
  final wsl = Platform.isWindows ? wslProject(project) : null;
  return wsl != null && path.startsWith('/') ? '${wsl.prefix}$path' : path;
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
        r'exec "${1:-${CAOCODE_CODEX_PATH:-codex}}" app-server --listen stdio://',
        'caocode',
        CodexPathSetting.current() ?? '',
      ];
      workingDirectory =
          Platform.environment['USERPROFILE'] ?? Directory.current.path;
    } else {
      final launch = _findCli(environment);
      program = launch.$1;
      launchArguments = [...launch.$2, 'app-server', '--listen', 'stdio://'];
    }
    if (_closing) return;
    final process = await Process.start(
      program,
      launchArguments,
      workingDirectory: workingDirectory,
      environment: {...environment, ...proxy},
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

  static (String, List<String>) _findCli(Map<String, String> environment) {
    final override =
        CodexPathSetting.current() ?? environment['CAOCODE_CODEX_PATH'];
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
        return (candidate, const []);
      }
      // npm's Windows shim: run Node directly to keep stdio and cancellation.
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
        return (File(node).existsSync() ? node : 'node.exe', [script]);
      }
    }
    throw const CodexRpcException(
      '未找到 Codex CLI。请安装并登录 Codex，或设置 CAOCODE_CODEX_PATH。',
    );
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
