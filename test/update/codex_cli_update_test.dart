import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:caocode/kernel/codex/codex_path_setting.dart';
import 'package:caocode/update/codex_cli_update.dart';
import 'package:caocode/update/codex_cli_update_io.dart';
import 'package:caocode/update/version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

// Explicit opt-in live checks use real HTTP instead of flutter_test's 400 stub.
class _LiveNetwork extends HttpOverrides {}

class FakeCliUpdates implements CodexCliUpdateBackend {
  String version = '0.162.1';
  String path = '/opt/codex';
  bool supported = true;
  bool replace = true;
  Object? problem;
  int updates = 0;
  Completer<AppVersion>? checking;

  @override
  Future<CodexCliInstallation> inspect() async => CodexCliInstallation(
    path: path,
    host: 'Linux',
    version: AppVersion.parse(version),
    canUpdate: supported,
  );

  @override
  Future<AppVersion> latestVersion() async {
    if (problem case final error?) throw error;
    return checking == null ? AppVersion.parse('0.163.0') : checking!.future;
  }

  @override
  Future<void> update(
    CodexCliInstallation installation,
    AppVersion target,
  ) async {
    updates++;
    if (problem case final error?) throw error;
    if (replace) version = target.marketing;
  }
}

void main() {
  test('installed CLI and latest stable can be checked without updating', () async {
    final io = IoCodexCliUpdateBackend(
      cwd: Platform.environment['CAOCODE_TEST_CLI_CWD'],
    );
    final installed = await io.inspect();
    final latest = await HttpOverrides.runWithHttpOverrides(
      io.latestVersion,
      _LiveNetwork(),
    );
    expect(installed.version.major, greaterThanOrEqualTo(0));
    expect(installed.canUpdate, isTrue);
    debugPrint(
      'CLI ${installed.version.marketing} · ${installed.host} · ${installed.path}; latest ${latest.marketing}',
    );
  }, skip: !const bool.fromEnvironment('CAOCODE_TEST_CLI_UPDATES'));

  test(
    'reading installed version is offline; checking enables manual update',
    () async {
      final backend = FakeCliUpdates();
      final service = CodexCliUpdateService(backend);
      addTearDown(service.dispose);
      await service.load();
      expect(service.installation!.version.marketing, '0.162.1');
      expect(service.latest, isNull);
      await service.update();
      expect(backend.updates, 0);
      await service.check();
      expect(service.status, CodexCliUpdateStatus.available);
      expect(service.canUpdate, isTrue);
      await service.update();
      expect(service.status, CodexCliUpdateStatus.updated);
      expect(service.installation!.version.marketing, '0.163.0');
      expect(service.canUpdate, isFalse);
    },
  );

  test(
    'failure is retryable; preview versions ahead of stable are not downgraded',
    () async {
      final backend = FakeCliUpdates()..problem = StateError('offline');
      final service = CodexCliUpdateService(backend);
      addTearDown(service.dispose);
      await service.check();
      expect(service.status, CodexCliUpdateStatus.failed);
      expect(service.canUpdate, isFalse);
      backend
        ..problem = null
        ..version = '0.164.0-alpha.1';
      await service.check();
      expect(service.status, CodexCliUpdateStatus.upToDate);
      expect(service.error, isNull);
      expect(service.canUpdate, isFalse);
    },
  );

  test('unsupported installs can check but never run an updater', () async {
    final backend = FakeCliUpdates()..supported = false;
    final service = CodexCliUpdateService(backend);
    addTearDown(service.dispose);
    await service.check();
    await service.update();
    expect(service.latest!.marketing, '0.163.0');
    expect(service.canUpdate, isFalse);
    expect(backend.updates, 0);
  });

  test(
    'a successful command cannot claim success if actual version is unchanged',
    () async {
      final backend = FakeCliUpdates()..replace = false;
      final service = CodexCliUpdateService(backend);
      addTearDown(service.dispose);
      await service.check();
      await service.update();
      expect(service.status, CodexCliUpdateStatus.failed);
      expect(service.error.toString(), contains('0.163.0'));
      expect(service.installation!.version.marketing, '0.162.1');
    },
  );

  test(
    'duplicate checks are ignored and closing the page during a check is safe',
    () async {
      final backend = FakeCliUpdates()..checking = Completer<AppVersion>();
      final service = CodexCliUpdateService(backend);
      final pending = service.check();
      await service.check();
      expect(service.busy, isTrue);
      service.dispose();
      backend.checking!.complete(AppVersion.parse('0.163.0'));
      await pending;
    },
  );

  group('CLI host and installation selection', () {
    late Directory folder;
    late String selected;
    late String version;
    late List<({String program, List<String> args})> calls;
    late String? Function() before;

    Future<ProcessResult> run(
      String program,
      List<String> args,
      Map<String, String> environment,
      Duration timeout,
    ) async {
      calls.add((program: program, args: args));
      if (args.last == '--version') {
        return ProcessResult(1, 0, 'codex-cli $version\n', '');
      }
      if (args.last == '--help') {
        return ProcessResult(1, 0, 'Commands:\n  update  Update Codex\n', '');
      }
      if (args.last == 'update' || args.contains('install')) {
        version = '0.163.0';
        return ProcessResult(1, 0, 'updated', '');
      }
      if (program == 'wsl.exe') {
        return ProcessResult(
          1,
          0,
          '__CAOCODE_CLI__\n$selected\n/home/user/.codex/packages/standalone/current/bin/codex\n',
          '',
        );
      }
      throw StateError('unexpected command: $program $args');
    }

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('caocode cli update ');
      selected = p.join(folder.path, 'custom codex');
      await File(selected).writeAsString('fixture');
      version = '0.162.1';
      calls = [];
      before = CodexPathSetting.current;
      CodexPathSetting.current = () => selected;
    });
    tearDown(() async {
      CodexPathSetting.current = before;
      await folder.delete(recursive: true);
    });

    IoCodexCliUpdateBackend backend({String? cwd, bool? windows}) =>
        IoCodexCliUpdateBackend(
          cwd: cwd,
          windows: windows,
          environment: () async => {'HOME': folder.path, 'PATH': ''},
          proxy: () async => {},
          run: run,
        );

    test('custom executable is probed and updated at its exact path', () async {
      final io = backend();
      final installed = await io.inspect();
      expect(installed.path, selected);
      await io.update(installed, AppVersion.parse('0.163.0'));
      expect(calls.last.program, selected);
      expect(calls.last.args, ['update']);
      expect((await io.inspect()).version.marketing, '0.163.0');
    });

    test(
      'changing the CLI path after checking blocks the old update',
      () async {
        final io = backend();
        final installed = await io.inspect();
        selected = p.join(folder.path, 'other codex');
        await File(selected).writeAsString('fixture');
        await expectLater(
          io.update(installed, AppVersion.parse('0.163.0')),
          throwsStateError,
        );
        expect(calls.where((call) => call.args.contains('update')), isEmpty);
      },
    );

    test(
      'npm updates retain the original global prefix rather than PATH npm',
      () async {
        final prefix = p.join(folder.path, 'node-v22');
        final root = p.join(prefix, 'lib', 'node_modules', '@openai', 'codex');
        await Directory(p.join(root, 'bin')).create(recursive: true);
        await File(p.join(root, 'package.json'))
            .writeAsString(jsonEncode({'name': '@openai/codex'}));
        final script = p.join(root, 'bin', 'codex.js');
        await File(script).writeAsString('fixture');
        await Directory(p.join(prefix, 'bin')).create(recursive: true);
        await File(p.join(prefix, 'bin', 'npm')).writeAsString('fixture');
        await File(selected).delete();
        await Link(selected).create(script);
        final io = backend();
        final installed = await io.inspect();
        await io.update(installed, AppVersion.parse('0.163.0'));
        expect(calls.last.program, p.join(prefix, 'bin', 'npm'));
        expect(calls.last.args, [
          'install',
          '--global',
          '--prefix',
          prefix,
          '@openai/codex@0.163.0',
          '--no-audit',
          '--no-fund',
        ]);
      },
    );

    test(
      'WSL host, selected path and arguments survive spaces and shell syntax',
      () async {
        selected = '/home/user/codex cli \$(literal)';
        final io = backend(
          cwd: r'\\wsl.localhost\Ubuntu\home\user\my project',
          windows: true,
        );
        final installed = await io.inspect();
        expect(installed.host, 'WSL · Ubuntu');
        expect(installed.path, selected);
        expect(calls.first.args.last, selected);
        expect(calls.first.args[8], isNot(contains(selected)));
        await io.update(installed, AppVersion.parse('0.163.0'));
        expect(calls.last.program, 'wsl.exe');
        expect(calls.last.args.sublist(calls.last.args.length - 2), [
          selected,
          'update',
        ]);
        expect(calls.last.args.take(4), [
          '--distribution',
          'Ubuntu',
          '--cd',
          '/home/user/my project',
        ]);
      },
    );
  });
}
