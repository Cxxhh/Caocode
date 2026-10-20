import 'dart:convert';
import 'dart:io';

import 'package:caocode/kernel/codex/codex_environment.dart';
import 'package:caocode/kernel/codex/codex_environment_io.dart';
import 'package:caocode/kernel/codex/codex_host_settings.dart';
import 'package:caocode/kernel/codex/codex_host.dart';
import 'package:caocode/kernel/codex/codex_process.dart';
import 'package:caocode/kernel/codex/codex_rpc.dart';
import 'package:caocode/update/codex_cli_update_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class FakeCodexEnvironments implements CodexEnvironmentBackend {
  @override
  bool supported = true;
  final homes = <String, String>{
    'windows': r'C:\Users\tester',
    'wsl:Ubuntu': '//wsl.localhost/Ubuntu/home/tester',
    'wsl:Debian': '//wsl.localhost/Debian/home/tester',
  };
  final missing = <String>{};
  Object? discoveryError;
  @override
  Future<List<String>> distributions() async {
    if (discoveryError case final error?) throw error;
    return ['Ubuntu', 'Debian'];
  }

  @override
  Future<String> home(CodexEnvironment environment) async =>
      homes[environment.id]!;
  @override
  Future<bool> exists(String path) async => !missing.contains(path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'WSL2 listing decodes UTF16 and excludes WSL1 across localized states',
    () {
      const text =
          '  NAME                   STATE           VERSION\r\n'
          '* Ubuntu                 Running         2\r\n'
          '  OldLinux               Stopped         1\r\n'
          '  Debian                 已停止          2\r\n'
          '  My Linux               Running         2\r\n';
      final bytes = [
        255,
        254,
        for (final unit in text.codeUnits) ...[unit & 255, unit >> 8],
      ];
      expect(wsl2Distributions(decodeWslOutput(bytes)), [
        'Ubuntu',
        'Debian',
        'My Linux',
      ]);
      expect(decodeWslOutput(utf8.encode('Ubuntu')), 'Ubuntu');
    },
  );

  test(
    'each environment opens its own home and remembers its own project',
    () async {
      final backend = FakeCodexEnvironments();
      final controller = CodexEnvironmentController(backend: backend);
      addTearDown(controller.dispose);
      Map<String, Object?>? kept;
      controller.save = (value) async => kept = value;
      final initial = <String?>[];
      Future<String?> pick(String? path) async {
        initial.add(path);
        return path == r'C:\Users\tester'
            ? r'C:\work\win'
            : '//wsl.localhost/Ubuntu/home/tester/project';
      }

      expect(await controller.pick(pick), r'C:\work\win');
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      expect(
        await controller.pick(pick),
        '//wsl.localhost/Ubuntu/home/tester/project',
      );
      await controller.select(const CodexEnvironment.windows());
      await controller.pick((path) async {
        initial.add(path);
        return null;
      });
      expect(initial, [
        r'C:\Users\tester',
        '//wsl.localhost/Ubuntu/home/tester',
        r'C:\work\win',
      ]);
      final restored = CodexEnvironmentController(backend: backend)
        ..restore(kept);
      addTearDown(restored.dispose);
      await restored.select(const CodexEnvironment.wsl('Ubuntu'));
      await restored.pick((path) async {
        expect(path, '//wsl.localhost/Ubuntu/home/tester/project');
        return null;
      });
      backend.missing.add('//wsl.localhost/Ubuntu/home/tester/project');
      await restored.pick((path) async {
        expect(path, '//wsl.localhost/Ubuntu/home/tester');
        return null;
      });
    },
  );

  test(
    'wrong environment and cancelled picks never replace remembered projects',
    () async {
      final controller = CodexEnvironmentController(
        backend: FakeCodexEnvironments(),
      );
      addTearDown(controller.dispose);
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      for (final path in [r'C:\work', '//wsl.localhost/Debian/home/tester']) {
        await expectLater(
          controller.pick((_) async => path),
          throwsFormatException,
        );
      }
      expect(await controller.pick((_) async => null), isNull);
      await controller.pick((initial) async {
        expect(initial, '//wsl.localhost/Ubuntu/home/tester');
        return null;
      });
    },
  );

  test(
    'failed preference writes leave the previously selected environment active',
    () async {
      final controller = CodexEnvironmentController(
        backend: FakeCodexEnvironments(),
      );
      addTearDown(controller.dispose);
      controller.save = (_) async => throw StateError('read only');
      await expectLater(
        controller.select(const CodexEnvironment.wsl('Ubuntu')),
        throwsStateError,
      );
      expect(controller.selected.id, 'windows');
    },
  );

  test(
    'non-Windows keeps the original native directory picker contract',
    () async {
      final controller = CodexEnvironmentController(
        backend: FakeCodexEnvironments()..supported = false,
      );
      addTearDown(controller.dispose);
      expect(
        await controller.pick((initial) async {
          expect(initial, isNull);
          return '/project';
        }),
        '/project',
      );
    },
  );

  test(
    'CLI paths and configs are isolated by Windows and WSL distribution',
    () {
      const base = 'codexCli.path';
      final values = <String, Object?>{
        '$base.windows': r'C:\codex\codex.exe',
        '$base.wsl.Ubuntu': '/opt/codex/bin/codex',
        '$base.wsl.Debian': '',
      };
      String? value(String? cwd, [String? legacy]) => CodexHostSettings.value(
        base,
        cwd,
        legacy,
        windows: true,
        readSetting: (key) => values[key],
      );
      expect(value(r'C:\project'), r'C:\codex\codex.exe');
      expect(value('//wsl.localhost/Ubuntu/home/me'), '/opt/codex/bin/codex');
      expect(value(r'//wsl$/Debian/home/me', '/old/codex'), isNull);
      values.clear();
      expect(value(r'C:\project', '/linux/codex'), isNull);
      expect(value('//wsl.localhost/Ubuntu/home/me', r'C:\codex.exe'), isNull);
      expect(
        value(r'C:\project', r'C:\legacy\codex.exe'),
        r'C:\legacy\codex.exe',
      );
      expect(
        value('//wsl.localhost/Ubuntu/home/me', '/legacy/codex'),
        '/legacy/codex',
      );
      expect(
        CodexHostSettings.key(
          'codexCli.configPath',
          '//wsl.localhost/Ubuntu/',
          windows: true,
        ),
        'codexCli.configPath.wsl.Ubuntu',
      );
      expect(
        CodexHostSettings.value(
          base,
          '/project',
          '/original/codex',
          windows: false,
          readSetting: (_) => null,
        ),
        '/original/codex',
      );
    },
  );

  test('a new default does not reinterpret existing project paths', () {
    const linux = CodexEnvironment.wsl('Ubuntu');
    const windows = CodexEnvironment.windows();
    expect(linux.settingsLocation(r'C:\project'), r'\\wsl.localhost\Ubuntu\');
    expect(windows.settingsLocation('//wsl.localhost/Ubuntu/home/me'), isNull);
    expect(wslProject('//wsl.localhost/Ubuntu/home/me')?.path, '/home/me');
    expect(wslProject(r'C:\project'), isNull);
  });

  test(
    'Windows and WSL installations initialize app-server on their own host',
    () async {
      final backend = IoCodexEnvironmentBackend();
      final choices = [
        const CodexEnvironment.windows(),
        for (final name in await backend.distributions())
          CodexEnvironment.wsl(name),
      ];
      expect(choices.where((choice) => choice.isWsl), isNotEmpty);
      for (final target in choices) {
        final cwd = await backend.home(target);
        expect(await backend.exists(cwd), isTrue);
        final install = await IoCodexCliUpdateBackend(cwd: cwd).inspect();
        final rpc = CodexRpcClient(localCodexTransport(cwd: cwd));
        final sub = rpc.messages.listen((_) {}, onError: (Object _) {});
        try {
          await rpc.initialize().timeout(const Duration(seconds: 30));
          // No turn/start or model request: this only checks CLI transport.
          debugPrint('${target.label}: ${install.version} · $cwd');
        } finally {
          rpc.close();
          await sub.cancel();
          await rpc.stopped;
        }
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('CAOCODE_TEST_ENVIRONMENTS'),
  );
}
