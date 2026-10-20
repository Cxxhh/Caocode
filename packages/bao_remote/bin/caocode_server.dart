// The server of a remote project: started over SSH by the app, it answers
// JSON-RPC on stdin and stdout (see RemoteProtocol), logs on stderr, and
// ends, with every process it started, when the connection does.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show runAgentCommandLine;
import 'package:bao_remote/server.dart';

/// The Caocode version the server came with (`-Dcaocode.version=…`).
const _version = String.fromEnvironment('caocode.version');

Future<void> main(List<String> arguments) async {
  // `agent <claude's arguments>`: Caocode's own core, run here as the CLI
  // would be (see ServerClaude.startBuiltin).
  if (arguments.firstOrNull == ServerClaude.agentCommand) {
    exit(
      await runAgentCommandLine(
        arguments.sublist(1),
        input: stdin,
        output: stdout,
        errors: stderr,
        cwd: Directory.current.path,
        environment: Platform.environment,
      ),
    );
  }
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  final dataDir = arguments.length >= 2 && arguments.first == '--data'
      ? arguments[1]
      : '$home/.caocode-server/data';
  Directory(dataDir).createSync(recursive: true);
  // A key Claude Code is given stays in memory where there is a place for
  // it, not on disk.
  final runtime = Platform.environment['XDG_RUNTIME_DIR'];
  if (runtime != null &&
      runtime.isNotEmpty &&
      Directory(runtime).existsSync()) {
    ClaudeSettingsFile.parent = Directory(runtime);
  }
  void log(String message) => stderr.writeln('caocode-server: $message');

  final peer = RpcPeer(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
    stdout.writeln,
  );
  final server = RemoteServer(
    peer,
    dataDir: dataDir,
    version: _version,
    log: log,
  );
  Future<void> exitWith(int code) async {
    await server.shutdown();
    await stdout.flush();
    exit(code);
  }

  // The connection gone: sshd hangs up the session.
  for (final signal in [ProcessSignal.sighup, ProcessSignal.sigterm]) {
    signal.watch().listen((_) => unawaited(exitWith(0)));
  }
  await peer.done;
  await exitWith(0);
}
