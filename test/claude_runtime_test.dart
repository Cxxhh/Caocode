@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/client.dart' show RemotePlatform;
import 'package:bao_remote/local.dart';
import 'package:caocode/kernel/claude_code/claude_install_progress.dart';
import 'package:caocode/kernel/claude_code/claude_path_setting.dart';
import 'package:caocode/kernel/claude_code/local_claude_io.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/remote/remote_status.dart';
import 'package:caocode/settings/pages/general_page.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The Claude Code run on a machine: the newest of the user's builds and
/// the one Caocode downloaded for them, downloaded where there is none
/// that runs, or only ones too old.
void main() {
  late Directory home;
  late Directory data;
  late _FakeReleases releases;
  late ClaudeRuntime runtime;
  const platform = 'darwin-arm64';

  setUp(() async {
    // flutter_test answers every HttpClient request with a 400.
    HttpOverrides.global = null;
    home = Directory.systemTemp.createTempSync('caocode-runtime-');
    data = Directory(p.join(home.path, 'data'))..createSync();
    releases = await _FakeReleases.start(platform);
    ClaudeRelease.baseOverride = releases.base;
    final environment = {'PATH': '/usr/bin:/bin', 'HOME': home.path};
    CliLocator.candidatesOverride = (_) => const [];
    CliLocator.use(environment);
    runtime = ClaudeRuntime(
      managed: ManagedClaude(p.join(data.path, 'claude')),
      platform: platform,
    );
  });
  tearDown(() async {
    ClaudeRelease.baseOverride = null;
    CliLocator.candidatesOverride = null;
    CliLocator.use(null);
    LocalClaude.runtime = null;
    ClaudePathSetting.current = () => null;
    await releases.close();
    home.deleteSync(recursive: true);
  });

  /// A build of the user's at [name] that says it is [version], and counts
  /// how often it is asked.
  String build(String name, String? version) {
    final file = File(p.join(home.path, name, 'claude'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '#!/bin/sh\n'
        'echo asked >> "${p.join(home.path, name, 'asked')}"\n'
        '${version == null ? 'exit 3' : 'echo "$version (Claude Code)"'}\n',
      );
    Process.runSync('chmod', ['+x', file.path]);
    return file.path;
  }

  int asked(String name) {
    final file = File(p.join(home.path, name, 'asked'));
    return file.existsSync() ? file.readAsLinesSync().length : 0;
  }

  void install(String version) {
    final managed = runtime.managed;
    managed.binaryOf(version)
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    Process.runSync('chmod', ['+x', managed.binaryOf(version).path]);
    File(p.join(managed.directory, 'CURRENT')).writeAsStringSync('$version\n');
  }

  test('the newest of the user\'s builds, the first of them where they '
      'are as new; each asked once', () async {
    final old = build('old', '1.0.5');
    final newer = build('newer', '2.1.0');
    final same = build('same', '2.1.0');
    CliLocator.candidatesOverride = (_) => [old, newer, same];
    expect((await runtime.locate()).executable, newer);
    expect((await runtime.locate()).executable, newer);
    // Kept across runs, by the file.
    final again = ClaudeRuntime(managed: runtime.managed, platform: platform);
    expect((await again.locate()).executable, newer);
    expect([asked('old'), asked('newer'), asked('same')], [1, 1, 1]);
    // Replaced (updated): asked again.
    build('old', '3.0.0');
    expect((await again.locate()).executable, old);
    expect(asked('old'), 2);
  });

  test('a single build is run without being asked', () async {
    final only = build('only', '1.0.0');
    CliLocator.candidatesOverride = (_) => [only];
    expect((await runtime.locate()).executable, only);
    expect(asked('only'), 0);
  });

  test('the one installed where it is newer, its updater off; the user\'s '
      'where it is as new', () async {
    final own = build('own', '2.0.0');
    CliLocator.candidatesOverride = (_) => [own];
    install('2.5.0');
    final cli = await runtime.locate();
    expect(cli.executable, runtime.managed.installed);
    expect(cli.environment['DISABLE_AUTOUPDATER'], '1');
    install('2.0.0');
    expect((await runtime.locate()).executable, own);
  });

  test(
    'one that cannot say its version is passed over for one that can',
    () async {
      final broken = build('broken', null);
      CliLocator.candidatesOverride = (_) => [broken];
      install('1.0.0');
      expect((await runtime.locate()).executable, runtime.managed.installed);
    },
  );

  test('none: the release\'s current one is downloaded, checked, with its '
      'progress, then run', () async {
    final seen = <(int, int)>[];
    final cli = await runtime.locate(
      onDownload: (received, size) => seen.add((received, size)),
    );
    expect(cli.executable, p.join(data.path, 'claude', 'claude-9.9.9'));
    expect(File(cli.executable).readAsBytesSync(), releases.binary);
    expect(seen.first, (0, releases.binary.length));
    expect(seen.last, (releases.binary.length, releases.binary.length));
    // Not without being asked to.
    runtime.managed.binaryOf('9.9.9').deleteSync();
    await expectLater(runtime.locate(), throwsA(isA<ClaudeNotInstalled>()));
  });

  test('one too old is passed over, with all no newer; the current one is '
      'downloaded in their place', () async {
    final newer = build('newer', '1.2.0');
    final old = build('old', '1.1.0');
    CliLocator.candidatesOverride = (_) => [old, newer];
    expect((await runtime.locate()).executable, newer);
    expect(await runtime.rejectTooOld(newer), isTrue);
    final cli = await runtime.locate(onDownload: (_, _) {});
    expect(cli.executable, runtime.managed.installed);
    expect(releases.served, contains('/9.9.9/$platform/claude'));
  });

  test('the installed one too old: a newer one of the release installed '
      'in its place, else none to try', () async {
    install('1.0.0');
    final installed = runtime.managed.installed!;
    expect(await runtime.rejectTooOld(installed), isTrue);
    expect(runtime.managed.version, '9.9.9');
    expect(
      File(installed).existsSync(),
      isFalse,
      reason: 'the one it replaced is removed',
    );
    expect(await runtime.rejectTooOld(runtime.managed.installed!), isFalse);
  });

  test('the one the user named is run as it is, nothing compared; one '
      'not there says how to undo it', () async {
    final named = build('named', '0.1.0');
    install('9.0.0');
    var path = named;
    final runtime = ClaudeRuntime(
      managed: ManagedClaude(p.join(data.path, 'claude')),
      platform: platform,
      named: (_) => (path: path, undo: 'Clear it.'),
    );
    expect((await runtime.locate()).executable, named);
    expect(asked('named'), 0);
    path = p.join(home.path, 'gone');
    await expectLater(
      runtime.locate(onDownload: (_, _) {}),
      throwsA(
        isA<ClaudeUnavailable>()
            .having((e) => e.message, 'message', contains(path))
            .having((e) => e.detail, 'detail', contains('Clear it.')),
      ),
    );
    expect(releases.served, isEmpty);
  });

  test('Settings name the one to run here, `~` the home; '
      'CAOCODE_CLAUDE_PATH in the environment is not read', () async {
    final named = build('named', '0.1.0');
    final other = build('other', '1.0.0');
    CliLocator.candidatesOverride = (_) => [other];
    CliLocator.use({
      'PATH': '/usr/bin:/bin',
      'HOME': home.path,
      'CAOCODE_CLAUDE_PATH': named,
    });
    LocalClaude.runtime = null;
    expect((await LocalClaude.locate(install: false)).executable, other);
    ClaudePathSetting.current = () => '~/named/claude';
    expect((await LocalClaude.locate(install: false)).executable, named);
    ClaudePathSetting.current = () => '~/missing/claude';
    final status = await LocalClaude.status();
    expect(
      status,
      isA<LocalClaudeFailed>().having(
        (s) => s.message,
        'message',
        contains('Settings → General → Claude Code'),
      ),
    );
  });

  test('its status: the one run, its version, whether Caocode downloaded '
      'it; none yet', () async {
    LocalClaude.runtime = runtime;
    expect(await LocalClaude.status(), isA<LocalClaudeMissing>());
    install('2.0.0');
    expect(
      await LocalClaude.status(),
      isA<LocalClaudeFound>()
          .having((s) => s.version, 'version', '2.0.0')
          .having((s) => s.downloaded, 'downloaded', isTrue),
    );
    final own = build('own', '2.0.0');
    CliLocator.candidatesOverride = (_) => [own];
    expect(
      await LocalClaude.status(),
      isA<LocalClaudeFound>()
          .having((s) => s.path, 'path', own)
          .having((s) => s.version, 'version', '2.0.0')
          .having((s) => s.downloaded, 'downloaded', isFalse),
    );
  });

  testWidgets('Settings → General: the path set, and the one in use under '
      'it', (tester) async {
    Future<void> show(LocalClaudeStatus status) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: GeneralSettingsPage(claudeStatus: () async => status),
          ),
        ),
      );
      await tester.pump();
    }

    await show(const LocalClaudeFound('/usr/local/bin/claude', '2.1.3'));
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('In use: /usr/local/bin/claude (2.1.3)'), findsOneWidget);
    await show(
      const LocalClaudeFound('/data/claude-2.1.4', '2.1.4', downloaded: true),
    );
    expect(
      find.text('In use: Claude Code 2.1.4, downloaded by Caocode'),
      findsOneWidget,
    );
    await show(const LocalClaudeMissing());
    expect(find.textContaining('None found yet'), findsOneWidget);
  });

  test('a download refused says how to install it by hand', () async {
    LocalClaude.runtime = runtime;
    releases.refuse = true;
    await expectLater(
      LocalClaude.locate(),
      throwsA(
        isA<ClaudeUnavailable>().having(
          (e) => e.detail,
          'detail',
          contains('https://claude.ai/install.sh'),
        ),
      ),
    );
    expect(LocalClaudeInstall.instance.progress, isNull);
  });

  test('Windows\' builds are named as the release names them', () {
    expect(
      ClaudeRelease.platformOf(const RemotePlatform('win', 'x64')),
      'win32-x64',
    );
    expect(
      ClaudeRelease.platformOf(const RemotePlatform('win', 'arm64')),
      'win32-arm64',
    );
    expect(
      ClaudeRelease.platformOf(
        const RemotePlatform('linux', 'x64', libc: 'musl'),
      ),
      'linux-x64-musl',
    );
    expect(
      ClaudeRelease.platformOf(const RemotePlatform('darwin', 'arm64')),
      'darwin-arm64',
    );
    expect(ClaudeRelease.fileOf('win32-x64'), 'claude.exe');
    expect(ClaudeRelease.fileOf('linux-x64'), 'claude');
  });

  testWidgets('its download\'s progress over the chat of a local project', (
    tester,
  ) async {
    final local = LocalClaudeInstall.instance;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ClaudeInstallBanner(location: home.path, local: local),
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    local.progress = const ClaudeInstallProgress(50, 200);
    await tester.pump();
    expect(find.text('Downloading Claude Code… 25%'), findsOneWidget);
    local.progress = null;
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}

/// downloads.claude.ai as the installer reads it: `/stable`, a version's
/// `manifest.json`, and its build for [platform].
class _FakeReleases {
  _FakeReleases._(this._server, this.platform);

  static Future<_FakeReleases> start(String platform) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final releases = _FakeReleases._(server, platform);
    server.listen(releases._serve);
    return releases;
  }

  final HttpServer _server;
  final String platform;
  final List<String> served = [];
  final List<int> binary = utf8.encode('#!/bin/sh\necho "9.9.9"\n');

  /// Every request refused, as for a machine without the internet.
  bool refuse = false;

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> _serve(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    if (refuse) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    served.add(path);
    if (path == '/stable') {
      response.write('9.9.9\n');
    } else if (path == '/9.9.9/manifest.json') {
      response.write(
        jsonEncode({
          'version': '9.9.9',
          'platforms': {
            platform: {
              'checksum': sha256.convert(binary).toString(),
              'size': binary.length,
            },
          },
        }),
      );
    } else if (path == '/9.9.9/$platform/claude') {
      response.add(binary);
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}
