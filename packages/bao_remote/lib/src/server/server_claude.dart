import 'dart:async';
import 'dart:io';

import '../claude/claude_environment.dart';
import '../claude/claude_release.dart';
import '../claude/claude_runtime.dart';
import '../claude/claude_settings_file.dart';
import '../claude/claude_unavailable.dart';
import '../claude/cli_locator.dart';
import '../protocol.dart';
import '../rpc/rpc_peer.dart';
import 'remote_server.dart' show paramsOf;
import 'server_streams.dart';

/// The Claude Code the server runs: the newest of the user's and one it
/// installed ([ManagedClaude], see [ClaudeRuntime]), downloaded there ([RemoteProtocol.claudeInstall]) or
/// sent by the app from its own download where the host cannot reach the
/// downloads ([RemoteProtocol.claudeUpload]).
class ServerClaude {
  ServerClaude(
    RpcPeer peer,
    this._streams, {
    required this.managed,
    required this.platform,
  }) : _runtime = ClaudeRuntime(
         managed: managed,
         platform: platform,
         named: _named,
       ) {
    peer.handlers[RemoteProtocol.claudeInstall] = (_, _) => _install();
    peer.handlers[RemoteProtocol.claudeUpload] = (params, _) =>
        _upload(paramsOf(params));
  }

  final ServerStreams _streams;
  final ManagedClaude managed;
  final ClaudeRuntime _runtime;

  /// The release's name for this machine (`linux-x64`, …).
  final String platform;

  /// Names another build to run on the host instead of those installed,
  /// e.g. set in the user's environment there to try a fork. (In the app,
  /// it is a setting.)
  static const pathVariable = 'CAOCODE_CLAUDE_PATH';

  static ({String path, String undo})? _named(Map<String, String> env) =>
      switch (env[pathVariable]) {
        final path? when path.isNotEmpty => (
          path: path,
          undo: 'Unset $pathVariable to run the installed Claude Code.',
        ),
        _ => null,
      };

  /// The server's argument that has it run Caocode's own core instead
  /// (bin/caocode_server.dart): `agent`, then the CLI's arguments.
  static const agentCommand = 'agent';

  /// How this server is run again, as the core: its executable (and its
  /// script, when run from source). Another under test.
  static List<String> Function() selfCommand = () => [
    Platform.resolvedExecutable,
    if (Platform.script.path.endsWith('.dart')) Platform.script.toFilePath(),
  ];

  /// Claude Code as Caocode's own core: this server run as [agentCommand]
  /// with the CLI's [arguments], in [cwd], with the user's environment
  /// there, [cleared] emptied and [environment] over it, and flag
  /// [settings] in a file only the user reads. Without a key it says how
  /// to set one up, as its first turn's error.
  static Future<Process> startBuiltin({
    required String cwd,
    required List<String> arguments,
    Map<String, Object?>? settings,
    List<String> cleared = const [],
    Map<String, String> environment = const {},
  }) async {
    final user = await ClaudeEnvironment.of();
    final env = {
      ...user,
      for (final name in cleared) name: '',
      ...environment,
      ...ClaudeEnvironment.stateDirectory(user),
    };
    final file = settings == null
        ? null
        : await ClaudeSettingsFile.write(settings);
    final [executable, ...self] = selfCommand();
    final Process process;
    try {
      process = await Process.start(
        executable,
        [
          ...self,
          agentCommand,
          ...arguments,
          if (file != null) ...['--settings', file],
        ],
        workingDirectory: cwd,
        environment: env,
        includeParentEnvironment: false,
      );
    } on Object {
      if (file != null) await ClaudeSettingsFile.delete(file);
      rethrow;
    }
    if (file != null) {
      unawaited(process.exitCode.then((_) => ClaudeSettingsFile.delete(file)));
    }
    return process;
  }

  /// The CLI to run: the newest of the user's and the one installed here
  /// (see [ClaudeRuntime]). None is installed by this: the app asks for
  /// it, and sends it where the host cannot download it.
  Future<ClaudeCli> locate() => _runtime.locate();

  /// Where the `claude` of the build installed here is, for the terminals'
  /// PATH: only when it is the one run, the user having none of their own.
  Future<String?> commandDirectory() async {
    try {
      final environment = await ClaudeEnvironment.of();
      if (_named(environment) != null) return null;
      if (CliLocator.installed(environment).isNotEmpty) return null;
      return managed.command();
    } on Object {
      return null;
    }
  }

  /// [arguments] as Claude Code starts with them run with [environment],
  /// as root where [root]: there it will not start where skipping the
  /// permissions is allowed at all, unless told it is in a sandbox
  /// (`IS_SANDBOX=1`, or bubblewrap's). The allowing flag is left out
  /// then; full access asked for is refused, saying why.
  static List<String> argumentsFor(
    List<String> arguments, {
    required bool root,
    required Map<String, String> environment,
  }) {
    final sandboxed =
        environment['IS_SANDBOX'] == '1' ||
        (environment['CLAUDE_CODE_BUBBLEWRAP'] ?? '').isNotEmpty;
    if (!root || sandboxed) return arguments;
    final mode = arguments.indexOf('--permission-mode');
    if (mode >= 0 &&
        mode + 1 < arguments.length &&
        arguments[mode + 1] == 'bypassPermissions') {
      throw const ClaudeUnavailable(
        'Claude Code does not run with full access as root',
        detail:
            'It refuses to skip the permission checks with root privileges. '
            'Pick another access mode, or connect as a user other than '
            'root.\n\nOn a host that is a disposable sandbox, IS_SANDBOX=1 '
            'in its environment lifts this.',
      );
    }
    return [
      for (final argument in arguments)
        if (argument != '--allow-dangerously-skip-permissions') argument,
    ];
  }

  /// Whether the server runs as root: `/proc/self/status`'s real user id.
  static bool get runsAsRoot {
    try {
      final status = File('/proc/self/status').readAsStringSync();
      final uid = RegExp(r'^Uid:\s+(\d+)', multiLine: true).firstMatch(status);
      return uid?.group(1) == '0';
    } on FileSystemException {
      return false;
    }
  }

  /// Downloads and installs the current build unless one is: its progress,
  /// `{received, size}`, as a stream.
  int _install() {
    final progress = StreamController<Object?>();
    unawaited(() async {
      try {
        if (managed.installed == null) {
          var reported = -1;
          await _runtime.fetch(
            onProgress: (received, size) {
              if (reported >= 0 &&
                  received - reported < 1 << 20 &&
                  received < size) {
                return;
              }
              reported = received;
              progress.add({'received': received, 'size': size});
            },
          );
        }
      } on Object catch (error, stack) {
        progress.addError(error, stack);
      } finally {
        await progress.close();
      }
    }());
    return _streams.open(progress.stream);
  }

  /// A piece of the build the app downloaded: `{build, offset, data}`,
  /// in order; installed once whole and checked. The installed path then.
  Future<String?> _upload(Map<String, Object?> args) async {
    final build = ClaudeBuild.fromJson(
      (args['build'] as Map).cast<String, Object?>(),
    );
    if (!RegExp(r'^[0-9A-Za-z.+-]+$').hasMatch(build.version) ||
        build.platform != platform) {
      throw ClaudeDownloadFailed(
        'Not a build of Claude Code for this host',
        detail: '${build.version} for ${build.platform}; this is $platform.',
      );
    }
    final offset = args['offset'] as int;
    final data = decodeBytes(args['data']);
    final part = managed.partOf(build);
    if (offset == 0) {
      part.parent.createSync(recursive: true);
      part.writeAsBytesSync(const []);
    } else if (!part.existsSync() || part.lengthSync() != offset) {
      throw const ClaudeDownloadFailed(
        'Claude Code was not uploaded whole',
        detail: 'A piece of it is missing.',
      );
    }
    part.writeAsBytesSync(data, mode: FileMode.append, flush: true);
    if (offset + data.length < build.size) return null;
    if (!await ClaudeRelease.holds(part, build)) {
      part.deleteSync();
      throw const ClaudeDownloadFailed(
        'Claude Code was not uploaded whole',
        detail: 'Its size or checksum is not the one in the manifest.',
      );
    }
    return managed.install(build, part);
  }
}
