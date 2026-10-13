import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'claude_environment.dart';
import 'claude_release.dart';
import 'cli_locator.dart';

/// Of how far a download is: the bytes so far, and all of them.
typedef ClaudeDownloadProgress = void Function(int received, int size);

/// The Claude Code to run on a machine: the newest of the user's builds
/// and the one Caocode installed there ([managed]), the user's where they
/// are as new. A machine with none is given one, when asked to.
///
/// What each of the user's builds is, it is asked (`--version`) once per
/// file: kept, by its size and time, in [managed]'s folder.
///
/// The one installed does not update itself (that would put it in the
/// user's `~/.local`): this does, now and then, for the next start.
class ClaudeRuntime {
  ClaudeRuntime({
    required this.managed,
    required this.platform,
    this.named = _none,
  });

  final ManagedClaude managed;

  /// The build the user named to run, in the environment it is found in,
  /// and how they undo that, to say where it is not there; null for none.
  final ({String path, String undo})? Function(Map<String, String> environment)
  named;

  static ({String path, String undo})? _none(Map<String, String> _) => null;

  /// The release's name for this machine (`darwin-arm64`, `win32-x64`, …).
  final String platform;

  /// How often the installed build looks for a newer one.
  static const updateEvery = Duration(days: 1);

  /// How long a build is given to say its version.
  @visibleForTesting
  static Duration askTimeout = const Duration(seconds: 10);

  /// The versions asked, by the build's real path: with the file's stamp
  /// they were asked of.
  Map<String, ({String stamp, String? version})>? _versions;

  /// The builds found too old, by their stamp.
  final Set<String> _tooOld = {};

  /// The newest version found too old: none at it or under it is run.
  List<int>? _floor;

  Future<void>? _installing;

  File get _versionsFile => File(p.join(managed.directory, 'versions.json'));

  /// The CLI to run: the one the user [named], else the newest of theirs
  /// and the installed one. With none, [onDownload] given,
  /// the current one is installed (its progress told to it); else this
  /// throws ClaudeNotInstalled.
  Future<ClaudeCli> locate({ClaudeDownloadProgress? onDownload}) async {
    final environment = await ClaudeEnvironment.of();
    if (named(environment) case (:final path, :final undo)?) {
      return CliLocator.named(path, environment, undo: undo);
    }
    final users = CliLocator.installed(environment);
    final own = _own(environment);
    final options = [...users, ?own];
    if (options.isEmpty) {
      if (onDownload == null) throw CliLocator.notInstalled(environment);
      await fetch(onProgress: onDownload);
      return _own(environment) ?? (throw CliLocator.notInstalled(environment));
    }
    final ClaudeCli chosen;
    if (options.length == 1 && _floor == null && _tooOld.isEmpty) {
      chosen = options.single;
    } else {
      final versions = await Future.wait([
        for (final cli in users) _versionOf(cli),
        if (own != null) Future.value(_parse(managed.version)),
      ]);
      ClaudeCli? best;
      List<int>? newest;
      for (final (index, cli) in options.indexed) {
        final version = versions[index];
        if (cli != own && _rejected(cli.executable, version)) continue;
        // The first of the newest: the user's before the installed one.
        if (best == null ||
            (version != null &&
                (newest == null || _compare(version, newest) > 0))) {
          best = cli;
          newest = version;
        }
      }
      if (best == null) {
        if (onDownload == null) throw CliLocator.notInstalled(environment);
        await fetch(onProgress: onDownload);
        return _own(environment) ??
            (throw CliLocator.notInstalled(environment));
      }
      chosen = best;
    }
    if (chosen == own) unawaited(_updateNowAndThen());
    return chosen;
  }

  /// The installed build, as it is run: its updater off.
  ClaudeCli? _own(Map<String, String> environment) =>
      switch (managed.installed) {
        final path? => ClaudeCli(path, {
          ...environment,
          'DISABLE_AUTOUPDATER': '1',
        }),
        null => null,
      };

  /// [executable] refused an option Caocode starts Claude Code with: it is
  /// passed over from now on, with every build of the user's no newer.
  /// Whether another may be tried: for the installed one, whether a newer
  /// one was installed in its place (its progress told to [onDownload]).
  Future<bool> rejectTooOld(
    String executable, {
    ClaudeDownloadProgress? onDownload,
  }) async {
    final installed = managed.installed;
    if (installed != null && p.equals(installed, executable)) {
      try {
        final before = managed.version;
        await fetch(onProgress: onDownload);
        return managed.version != before;
      } on Object {
        return false;
      }
    }
    final real = _realPath(executable);
    if (_stampOf(real) case final stamp?) _tooOld.add(stamp);
    final version = _parse(_versions?[real]?.version);
    if (version != null && (_floor == null || _compare(version, _floor!) > 0)) {
      _floor = version;
    }
    return true;
  }

  bool _rejected(String executable, List<int>? version) {
    if (_tooOld.contains(_stampOf(_realPath(executable)))) return true;
    final floor = _floor;
    return version != null && floor != null && _compare(version, floor) <= 0;
  }

  /// Installs the current build of the release (or [version]), unless it
  /// is the one installed: one at a time, however often asked.
  Future<void> fetch({String? version, ClaudeDownloadProgress? onProgress}) =>
      _installing ??= _fetch(version, onProgress).whenComplete(() {
        _installing = null;
      });

  Future<void> _fetch(
    String? version,
    ClaudeDownloadProgress? onProgress,
  ) async {
    final release = ClaudeRelease();
    version ??= await release.version();
    if (managed.version == version) return;
    final build = await release.build(version, platform);
    final part = managed.partOf(build);
    onProgress?.call(0, build.size);
    await release.download(
      build,
      part,
      onProgress: onProgress == null
          ? null
          : (received) => onProgress(received, build.size),
    );
    await managed.install(build, part);
  }

  /// Installs a newer build, if there is one, at most once per
  /// [updateEvery]; quietly, whatever goes wrong.
  Future<void> _updateNowAndThen() async {
    final checked = File(p.join(managed.directory, '.checked'));
    try {
      if (checked.existsSync() &&
          DateTime.now().difference(checked.lastModifiedSync()) < updateEvery) {
        return;
      }
      checked.writeAsStringSync('');
      // Those that were running at the last update are not now.
      managed.prune();
      await fetch();
    } on Object {
      // Tried again tomorrow.
    }
  }

  /// Whether [cli] is the installed one.
  bool isInstalled(ClaudeCli cli) => switch (managed.installed) {
    final installed? => p.equals(installed, cli.executable),
    null => false,
  };

  /// [cli]'s version (`2.1.3`), asked as [locate] asks it; null when it
  /// does not say.
  Future<String?> versionOf(ClaudeCli cli) async {
    final version = isInstalled(cli)
        ? _parse(managed.version)
        : await _versionOf(cli);
    return version?.join('.');
  }

  // --- Versions ---------------------------------------------------------------

  /// [cli]'s version: asked once per file, [askTimeout] given to say it.
  Future<List<int>?> _versionOf(ClaudeCli cli) async {
    final real = _realPath(cli.executable);
    final stamp = _stampOf(real);
    if (stamp == null) return null;
    final versions = _versions ??= _readVersions();
    if (versions[real] case final known? when known.stamp == stamp) {
      return _parse(known.version);
    }
    final version = await askVersion(cli);
    versions[real] = (stamp: stamp, version: version);
    _writeVersions(versions);
    return _parse(version);
  }

  /// What `[cli] --version` says it is (`2.1.3`), or null if it does not.
  @visibleForTesting
  static Future<String?> askVersion(ClaudeCli cli) async {
    try {
      final process = await Process.start(
        cli.executable,
        const ['--version'],
        environment: cli.environment,
        includeParentEnvironment: Platform.isWindows,
        runInShell: cli.throughShell,
      );
      unawaited(process.stdin.close().catchError((_) {}));
      unawaited(process.stderr.drain<void>().catchError((_) {}));
      final output = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final code = await process.exitCode.timeout(
        askTimeout,
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      if (code != 0) return null;
      final text = await output.timeout(
        const Duration(seconds: 1),
        onTimeout: () => '',
      );
      return RegExp(r'^\s*(\d+\.\d+\.\d+)').firstMatch(text)?.group(1);
    } on ProcessException {
      return null;
    }
  }

  Map<String, ({String stamp, String? version})> _readVersions() {
    try {
      final json = jsonDecode(_versionsFile.readAsStringSync());
      if (json is! Map) return {};
      return {
        for (final entry in json.entries)
          if (entry case MapEntry(
            key: final String path,
            value: {'stamp': final String stamp, 'version': final String? v},
          ))
            path: (stamp: stamp, version: v),
      };
    } on Object {
      return {};
    }
  }

  void _writeVersions(Map<String, ({String stamp, String? version})> versions) {
    try {
      final file = _versionsFile;
      file.parent.createSync(recursive: true);
      final part = File('${file.path}.part')
        ..writeAsStringSync(
          jsonEncode({
            for (final MapEntry(:key, :value) in versions.entries)
              key: {'stamp': value.stamp, 'version': value.version},
          }),
        );
      part.renameSync(file.path);
    } on FileSystemException {
      // Asked again next time.
    }
  }

  static String _realPath(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return path;
    }
  }

  /// The file at [path] as it is now: another once it is replaced.
  static String? _stampOf(String path) {
    final stat = FileStat.statSync(path);
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '${stat.size}:${stat.modified.millisecondsSinceEpoch}';
  }

  static List<int>? _parse(String? version) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)')
        .firstMatch(version?.trim() ?? '');
    if (match == null) return null;
    return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return a.length.compareTo(b.length);
  }
}
