import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../protocol.dart';
import '../rpc/rpc_peer.dart';
import 'remote_client.dart';
import 'ssh_askpass.dart';

export 'ssh_askpass.dart' show SshPrompt, SshPrompter;

/// A host to reach: an alias of `~/.ssh/config`, or `user@host`, with a
/// port after a colon (`dev:2222`, `me@10.0.0.2:2222`).
class SshTarget {
  SshTarget._(
    this.text,
    this.destination,
    this.port, [
    this.options = const [],
  ]);

  /// [text] reached by [destination], a `Host` of [configFile] (a server
  /// the user saved in the app; see [sshServersConfig]).
  SshTarget.configured(
    String text, {
    required String destination,
    required String configFile,
  }) : this._(text.trim(), destination, null, ['-F', configFile]);

  factory SshTarget.parse(String text) {
    text = text.trim();
    final colon = text.lastIndexOf(':');
    if (colon > 0 && !text.contains(']')) {
      final port = int.tryParse(text.substring(colon + 1));
      if (port != null) {
        return SshTarget._(text, text.substring(0, colon), port);
      }
    }
    return SshTarget._(text, text, null);
  }

  /// As the user gave it: what names the host in the app.
  final String text;

  /// `ssh`'s destination.
  final String destination;
  final int? port;

  /// `ssh`'s options for it (`-F` and its config).
  final List<String> options;

  /// Whether [text] could name a host: no spaces, no option.
  static bool isValid(String text) {
    text = text.trim();
    return text.isNotEmpty &&
        !text.startsWith('-') &&
        !text.contains(RegExp(r'\s'));
  }

  List<String> get arguments => [
    ...options,
    if (port case final port?) ...['-p', '$port'],
    destination,
  ];

  @override
  bool operator ==(Object other) => other is SshTarget && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => text;
}

/// Why connecting failed.
enum SshFailure {
  /// No `ssh` here.
  noSsh,

  /// The host would not have the key (or agent) offered, nor what was
  /// answered when asked (see [SshLauncher.prompter]), or that was
  /// cancelled.
  authentication,

  /// The host's key is unknown here, and not to be learned (the user's
  /// `StrictHostKeyChecking yes`).
  hostKey,

  /// The host's key is not the one known for it: the server was installed
  /// again, or someone is in between (see [SshLauncher.forgetHostKey]).
  hostKeyChanged,

  /// No such host, or it does not answer.
  unreachable,

  /// Not a Linux or macOS host on x64 or arm64.
  unsupported,

  /// The server could not be put there, or did not start.
  server,
}

class SshConnectException implements Exception {
  const SshConnectException(this.failure, this.message, {this.detail});

  final SshFailure failure;
  final String message;

  /// What `ssh` or the server said.
  final String? detail;

  @override
  String toString() => detail == null ? message : '$message\n$detail';
}

/// The server builds the app carries, one per platform.
abstract interface class RemoteServerBinaries {
  /// Names the build: where it goes on the host
  /// (`~/.caocode-server/<version>/`), so that each build is put there once.
  String get version;

  /// The build for [platform] (`linux-x64`, `darwin-arm64`, …; see
  /// [SshLauncher.platform]); null for none.
  Future<List<int>?> read(String platform);
}

/// Starts processes, as [Process.start] does: replaced under test.
typedef SshProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

/// A connection to a host's server: [client] over the stdin and stdout of
/// `ssh`, which ends with it.
class SshConnection {
  SshConnection._(this.target, Process process, this.client, this._stderr)
    : _ended = (() => process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill();
          return -1;
        },
      ));

  /// A connection over [client] without `ssh` (one in memory, under test);
  /// [ended] completes once its other end is gone after a shutdown.
  SshConnection.over(this.target, this.client, {Future<void> Function()? ended})
    : _stderr = const [],
      _ended = ended ?? (() async {});

  final SshTarget target;
  final RemoteClient client;
  final List<String> _stderr;
  final Future<void> Function() _ended;

  RemoteHello get hello => client.hello!;

  /// Completes once the connection is gone.
  Future<void> get done => client.peer.done;

  /// The last lines `ssh` and the server said on stderr.
  String get log => _stderr.join('\n');

  /// Ends the server (and all it runs), then `ssh`.
  Future<void> close() async {
    await client.shutdown();
    await _ended();
  }
}

/// Connects to hosts with the system's `ssh` (so that `~/.ssh/config`,
/// ProxyJump, the agent and known_hosts are the user's own): asks the host
/// what it is, puts the server there if this build of it is not yet (by
/// stdin, written to a temporary file and moved into place), then starts it
/// and talks to it over the connection. A host key not known yet is
/// learned, as one accepts it in a terminal the first time (unless the
/// user's config says otherwise); a changed one is refused.
class SshLauncher {
  SshLauncher({
    required this.ssh,
    required this.binaries,
    SshProcessStarter? start,
    this.options = defaultOptions,
    this.prompter,
    SshAskpass? askpass,
  }) : _start = start ?? Process.start,
       _askpass = askpass ?? SshAskpass();

  /// The `ssh` executable.
  final String ssh;
  final RemoteServerBinaries binaries;
  final SshProcessStarter _start;
  final List<String> options;

  /// Answers what `ssh` asks while signing in (a password, a key's
  /// passphrase); without one, or with an `ssh` older than OpenSSH 8.4 on
  /// Windows, nothing is asked and a host that wants a password refuses.
  /// Whether to accept a host key is not asked (see [connect]).
  final SshPrompter? prompter;
  final SshAskpass _askpass;

  /// Whether what `ssh` asks is answered (by [SshAskpass]'s script).
  bool get _prompts => prompter != null && (!_askpass.windows || _forced);

  /// On Windows, whether `ssh` takes `SSH_ASKPASS_REQUIRE=force` (OpenSSH
  /// 8.4 and later): one older reads a password from its console, which
  /// none would answer. Known once [_checkForced] is done.
  bool _forced = false;
  Future<void>? _checked;

  /// What `ssh -V` said, for an [SshFailure.authentication] too old to be
  /// asked.
  String? _version;

  Future<void> _checkForced() => _checked ??= () async {
    try {
      final result = await Process.run(ssh, const ['-V']);
      _version = '${result.stderr}${result.stdout}'.trim();
      _forced = takesForcedAskpass(_version!);
    } on ProcessException {
      // No ssh: said when it is started.
    }
  }();

  /// Whether `ssh -V`'s [version] is OpenSSH 8.4 or later.
  static bool takesForcedAskpass(String version) {
    final match = RegExp(r'OpenSSH_(?:for_Windows_)?(\d+)\.(\d+)')
        .firstMatch(version);
    if (match == null) return false;
    final (major, minor) = (int.parse(match[1]!), int.parse(match[2]!));
    return major > 8 || (major == 8 && minor >= 4);
  }

  /// No prompts (a password fails instead), keepalives
  /// that notice a dead connection, and no escape character on the binary
  /// stream. With a [prompter], `BatchMode` is off for it to be asked.
  static const defaultOptions = [
    '-T',
    '-o',
    'BatchMode=yes',
    '-o',
    'ServerAliveInterval=15',
    '-o',
    'ServerAliveCountMax=3',
    '-o',
    'ConnectTimeout=20',
    '-e',
    'none',
  ];

  /// [SshConnectException.message] when the user cancelled signing in.
  static const cancelledMessage = 'Signing in was cancelled.';

  /// Where the server's builds go on the host, from its home folder.
  static const serverRoot = '.caocode-server';

  String get _folder => '$serverRoot/${binaries.version}';

  /// The server's path on the host, from the home folder.
  String get serverPath => '$_folder/caocode-server';

  /// `ssh`'s arguments to run [command] on [target], with [extra] options
  /// (see [hostKeyOptions]).
  List<String> arguments(
    SshTarget target,
    String command, {
    List<String> extra = const [],
  }) => [
    for (final option in options)
      option == 'BatchMode=yes' && _prompts ? 'BatchMode=no' : option,
    ...extra,
    ...target.arguments,
    command,
  ];

  /// What `ssh -G` makes of [target]'s configuration: each keyword, in
  /// lowercase, and its value; empty when it would not say.
  Future<Map<String, String>> configOf(SshTarget target) async {
    final Process process;
    try {
      process = await _start(ssh, ['-G', ...target.arguments]);
    } on ProcessException {
      return const {};
    }
    unawaited(process.stdin.close().catchError((Object _) {}));
    final stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    final code = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    if (code != 0) return const {};
    final config = <String, String>{};
    for (final line in const LineSplitter().convert(await stdout)) {
      final space = line.indexOf(' ');
      if (space <= 0) continue;
      config.putIfAbsent(
        line.substring(0, space).toLowerCase(),
        () => line.substring(space + 1).trim(),
      );
    }
    return config;
  }

  /// The options [target] is reached with, its host key considered: one
  /// not known yet is learned (`StrictHostKeyChecking=accept-new`), unless
  /// the user's config says what to do with it; one changed is refused
  /// all the same. `ask`, ssh's default, would ask in a terminal there is
  /// none of here.
  Future<List<String>> hostKeyOptions(SshTarget target) async {
    final strict = (await configOf(target))['stricthostkeychecking'];
    return strict == null || strict == 'ask'
        ? const ['-o', 'StrictHostKeyChecking=accept-new']
        : const [];
  }

  /// Forgets the key known for [target]'s host, in the user's known_hosts
  /// files (`ssh-keygen -R`), for the next connection to learn the one it
  /// has now: after the server was installed again
  /// ([SshFailure.hostKeyChanged]).
  Future<void> forgetHostKey(SshTarget target) async {
    final config = await configOf(target);
    final host = config['hostkeyalias'] ?? config['hostname'];
    if (host == null) {
      throw SshConnectException(
        SshFailure.server,
        'ssh did not say which host ${target.text} is',
      );
    }
    final port = config['port'];
    final name = port == null || port == '22' ? host : '[$host]:$port';
    final keygen = _beside(ssh, 'ssh-keygen');
    for (final file in knownHostsFiles(config['userknownhostsfile'] ?? '')) {
      final Process process;
      try {
        process = await _start(keygen, ['-R', name, '-f', file]);
      } on ProcessException catch (error) {
        throw SshConnectException(
          SshFailure.noSsh,
          'ssh-keygen could not be started',
          detail: error.message,
        );
      }
      unawaited(process.stdin.close().catchError((Object _) {}));
      unawaited(process.stdout.drain<void>().catchError((Object _) {}));
      final stderr = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      // 0, or 1 when the file had no key for it.
      if (await process.exitCode > 1) {
        throw SshConnectException(
          SshFailure.server,
          'The old host key could not be removed from $file',
          detail: _tail(await stderr),
        );
      }
    }
  }

  /// The files of `ssh -G`'s [value] for known_hosts files that there
  /// are: their paths joined by spaces, unquoted, so that one with a space
  /// in it (`C:\Users\John Doe\.ssh\known_hosts`) is told by its file.
  static List<String> knownHostsFiles(String value) {
    final words = value.split(' ');
    final files = <String>[];
    var i = 0;
    while (i < words.length) {
      // The most words from here that make a file (`/tmp/a b/known_hosts`
      // over a `/tmp/a` there may be); none, a word that starts no file.
      var next = i + 1;
      for (var j = words.length - 1; j >= i; j--) {
        final path = words.sublist(i, j + 1).join(' ');
        if (path.isNotEmpty && File(path).existsSync()) {
          files.add(path);
          next = j + 1;
          break;
        }
      }
      i = next;
    }
    return files;
  }

  /// The [tool] of OpenSSH's beside [ssh] (`ssh-keygen`), else on PATH.
  static String _beside(String ssh, String tool) {
    final windows = ssh.toLowerCase().endsWith('.exe');
    final separator = ssh.lastIndexOf(RegExp(r'[/\\]'));
    if (separator < 0) return tool;
    final path =
        '${ssh.substring(0, separator + 1)}$tool${windows ? '.exe' : ''}';
    return File(path).existsSync() ? path : tool;
  }

  /// Starts `ssh` for [target] running [command] with [extra] options,
  /// what it asks answered by [prompter] until [AskpassRun.close].
  Future<(Process, AskpassRun?)> _startSsh(
    SshTarget target,
    String command,
    List<String> extra,
  ) async {
    final prompter = this.prompter;
    if (prompter != null && _askpass.windows) await _checkForced();
    final askpass = prompter != null && _prompts
        ? await _askpass.start(target, prompter)
        : null;
    try {
      final process = await _start(
        ssh,
        arguments(target, command, extra: extra),
        environment: askpass?.environment,
      );
      // Cancelled: ended, lest it ask again (up to NumberOfPasswordPrompts
      // times for each way of signing in).
      askpass?.onCancelled = process.kill;
      return (process, askpass);
    } on ProcessException catch (error) {
      await askpass?.close();
      throw SshConnectException(
        SshFailure.noSsh,
        'ssh could not be started',
        detail: error.message,
      );
    }
  }

  /// What the host is asked first: its system and architecture, whether
  /// this build of the server is there, and whether it can unpack gzip.
  String get probeScript =>
      '''
printf 'CAOCODE-PROBE %s %s\\n' "\$(uname -s)" "\$(uname -m)"
if [ -x '$serverPath' ]; then echo CAOCODE-PRESENT; fi
if command -v gzip >/dev/null 2>&1; then echo CAOCODE-GZIP; fi
exit 0
''';

  /// The command that writes the server from stdin ([gzip]ped or not):
  /// to a file of its own first, then moved into place, so that a cut
  /// connection leaves no half of one.
  String uploadCommand(String nonce, {required bool gzip}) {
    final temporary = '$_folder/.upload-$nonce';
    final write = gzip ? 'gzip -dc > $temporary' : 'cat > $temporary';
    return "sh -c 'mkdir -p $_folder && $write && chmod 755 $temporary && "
        "mv -f $temporary $serverPath'";
  }

  /// [uname -m] as mason names it; null for one there is no build for.
  static String? architecture(String machine) => switch (machine) {
    'x86_64' || 'amd64' => 'x64',
    'aarch64' || 'arm64' => 'arm64',
    _ => null,
  };

  /// [uname -s] and [uname -m] as the server's builds are named
  /// (`linux-x64`, `darwin-arm64`); null for a host there is none for.
  static String? platform(String system, String machine) {
    final os = switch (system) {
      'Linux' => 'linux',
      'Darwin' => 'darwin',
      _ => null,
    };
    final arch = architecture(machine);
    return os == null || arch == null ? null : '$os-$arch';
  }

  /// [platform] for people: `Linux x64`, `macOS arm64`.
  static String describe(String platform) {
    final parts = platform.split('-');
    return '${parts.first == 'darwin' ? 'macOS' : 'Linux'} ${parts.last}';
  }

  Future<SshConnection> connect(
    SshTarget target, {
    void Function(String message)? onProgress,
  }) async {
    final progress = onProgress ?? (_) {};
    progress('Connecting to ${target.text}');
    final extra = await hostKeyOptions(target);
    final probe = await _run(
      target,
      'sh -s',
      extra,
      stdin: utf8.encode(probeScript),
    );
    final lines = const LineSplitter().convert(probe.stdout);
    final header = lines.firstWhere(
      (line) => line.startsWith('CAOCODE-PROBE '),
      orElse: () => '',
    );
    final parts = header.split(' ');
    if (parts.length < 3) {
      throw SshConnectException(
        SshFailure.server,
        'The host gave no answer the app understands',
        detail: _tail('${probe.stdout}\n${probe.stderr}'),
      );
    }
    final (system, machine) = (parts[1], parts[2]);
    final platform = SshLauncher.platform(system, machine);
    if (platform == null) {
      throw SshConnectException(
        SshFailure.unsupported,
        'Only Linux and macOS hosts on x64 or arm64 are supported, not '
        '$system $machine',
      );
    }
    if (!lines.contains('CAOCODE-PRESENT')) {
      progress('Installing the Caocode server on ${target.text}');
      final binary = await binaries.read(platform);
      if (binary == null) {
        throw SshConnectException(
          SshFailure.server,
          'This build of the app has no server for ${describe(platform)}',
        );
      }
      final gzip = lines.contains('CAOCODE-GZIP');
      final upload = await _run(
        target,
        uploadCommand(_nonce(), gzip: gzip),
        extra,
        stdin: gzip ? GZipCodec(level: 6).encode(binary) : binary,
      );
      if (upload.exitCode != 0) {
        throw SshConnectException(
          SshFailure.server,
          'The server could not be installed on ${target.text}',
          detail: _tail(upload.stderr),
        );
      }
    }
    progress('Starting the Caocode server on ${target.text}');
    return _launch(target, extra);
  }

  Future<SshConnection> _launch(SshTarget target, List<String> extra) async {
    final (process, askpass) = await _startSsh(target, serverPath, extra);
    final stderr = <String>[];
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          stderr.add(line);
          if (stderr.length > 50) stderr.removeAt(0);
        }, onError: (Object _) {});
    process.stdin.done.then<void>((_) {}, onError: (Object _) {});
    final peer = RpcPeer(
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter()),
      (line) => process.stdin.writeln(line),
    );
    final client = RemoteClient(peer);
    final connection = SshConnection._(target, process, client, stderr);
    unawaited(process.exitCode.then((_) => peer.close()));
    try {
      // 30 seconds, and as long as the user is asked to sign in.
      final initialized = client.initialize();
      const wait = Duration(seconds: 30);
      while (true) {
        try {
          await initialized.timeout(wait);
          break;
        } on TimeoutException {
          if (!(askpass?.busy(wait) ?? false)) rethrow;
        }
      }
    } on Object catch (error) {
      process.kill();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
      throw _failure(
        code,
        stderr.join('\n'),
        fallback: 'The server on ${target.text} did not start: $error',
        cancelled: askpass?.cancelled ?? false,
      );
    } finally {
      // Signed in, or not to be.
      await askpass?.close();
    }
    return connection;
  }

  Future<({int exitCode, String stdout, String stderr})> _run(
    SshTarget target,
    String command,
    List<String> extra, {
    List<int>? stdin,
  }) async {
    final (process, askpass) = await _startSsh(target, command, extra);
    final stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    process.stdin.done.then<void>((_) {}, onError: (Object _) {});
    if (stdin != null) process.stdin.add(stdin);
    await process.stdin.close().catchError((Object _) {});
    final int code;
    try {
      code = await process.exitCode.timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
    } finally {
      await askpass?.close();
    }
    final result = (exitCode: code, stdout: await stdout, stderr: await stderr);
    final cancelled = askpass?.cancelled ?? false;
    // ssh's own failure: the connection, not the command; or ended, the
    // signing in cancelled.
    if (code == 255 || cancelled) {
      throw _failure(code, result.stderr, cancelled: cancelled);
    }
    return result;
  }

  static String _nonce() {
    final random = Random.secure();
    return [for (var i = 0; i < 6; i++) random.nextInt(256).toRadixString(16)]
        .join();
  }

  static String _tail(String text) {
    final lines = const LineSplitter()
        .convert(text.trim())
        .where((line) => line.trim().isNotEmpty)
        .toList();
    return lines.skip(max(0, lines.length - 12)).join('\n');
  }

  /// What `ssh` exiting with [code] and saying [stderr] means.
  SshConnectException _failure(
    int code,
    String stderr, {
    String? fallback,
    bool cancelled = false,
  }) {
    final detail = _tail(stderr);
    final failure = switch (stderr) {
      // Ended when cancelled, before ssh could say it was refused.
      _ when cancelled => SshFailure.authentication,
      _
          when stderr.contains('REMOTE HOST IDENTIFICATION HAS CHANGED') ||
              RegExp(r'Host key for \S+ has changed').hasMatch(stderr) =>
        SshFailure.hostKeyChanged,
      _ when stderr.contains('Permission denied') => SshFailure.authentication,
      _
          when stderr.contains('Host key verification failed') ||
              stderr.contains('No ED25519 host key is known') ||
              stderr.contains('host key is known') =>
        SshFailure.hostKey,
      _
          when stderr.contains('Could not resolve hostname') ||
              stderr.contains('Connection refused') ||
              stderr.contains('timed out') ||
              stderr.contains('No route to host') ||
              stderr.contains('Network is unreachable') ||
              stderr.contains('Connection closed by') ||
              stderr.contains('kex_exchange_identification') =>
        SshFailure.unreachable,
      _ => code == 255 ? SshFailure.unreachable : SshFailure.server,
    };
    final message = switch (failure) {
      SshFailure.authentication when cancelled => cancelledMessage,
      SshFailure.authentication when _prompts =>
        'The host refused to sign in: the key, or the password given.',
      SshFailure.authentication when prompter != null && _version != null =>
        'The host refused the key, and this ssh ($_version) cannot be '
            'asked for a password: OpenSSH 8.4 or later can. Update it, or '
            'set up a key or ssh-agent.',
      SshFailure.authentication =>
        'The host refused the key: no password is asked here. Set up a key '
            'or ssh-agent for it.',
      SshFailure.hostKey =>
        'The host key is unknown, and the ssh config says not to learn it. '
            'Connect once with ssh in a terminal to check and accept it.',
      SshFailure.hostKeyChanged =>
        'The host key changed since the last connection: the server was '
            'installed again, or someone is in between.',
      SshFailure.unreachable => 'The host could not be reached.',
      _ => fallback ?? 'ssh failed (exit $code).',
    };
    return SshConnectException(
      failure,
      message,
      detail: detail.isEmpty ? null : detail,
    );
  }
}

/// The `ssh` to connect with: the system's ([findSsh]), but on Windows
/// [bundled] (the app's own OpenSSH) where the system's is missing or too
/// old to be asked for a password (before 8.4, as Windows 10's 8.1; see
/// [SshLauncher.takesForcedAskpass]). Null when there is none.
Future<String?> chooseSsh(
  Map<String, String> environment, {
  String? bundled,
}) async {
  final system = findSsh(environment);
  if (!Platform.isWindows || bundled == null || !File(bundled).existsSync()) {
    return system;
  }
  if (system == null) return bundled;
  try {
    final result = await Process.run(system, const ['-V']);
    final version = '${result.stderr}${result.stdout}';
    return SshLauncher.takesForcedAskpass(version) ? system : bundled;
  } on ProcessException {
    return bundled;
  }
}

/// The system's `ssh`: OpenSSH in System32 on Windows, else the first on
/// [environment]'s PATH (`/usr/bin/ssh` on macOS); null when there is none.
String? findSsh(Map<String, String> environment) {
  if (Platform.isWindows) {
    final root =
        environment['SystemRoot'] ?? environment['SYSTEMROOT'] ?? r'C:\Windows';
    for (final candidate in [
      '$root\\System32\\OpenSSH\\ssh.exe',
      '$root\\Sysnative\\OpenSSH\\ssh.exe',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
  }
  final separator = Platform.isWindows ? ';' : ':';
  final name = Platform.isWindows ? 'ssh.exe' : 'ssh';
  for (final dir in [
    ...(environment['PATH'] ?? environment['Path'] ?? '').split(separator),
    if (!Platform.isWindows) ...[
      '/usr/bin',
      '/usr/local/bin',
      '/opt/homebrew/bin',
    ],
  ]) {
    if (dir.isEmpty) continue;
    final candidate = '$dir${Platform.pathSeparator}$name';
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
