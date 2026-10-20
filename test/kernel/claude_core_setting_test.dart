@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:caocode/kernel/claude_code/claude_code_transport.dart';
import 'package:caocode/kernel/claude_code/claude_core_setting.dart';
import 'package:caocode/kernel/claude_code/claude_environment.dart';
import 'package:caocode/kernel/claude_code/claude_path_setting.dart';
import 'package:caocode/kernel/claude_code/dart_core_transport_io.dart';
import 'package:caocode/kernel/claude_code/process_transport_io.dart';
import 'package:caocode/network/network_proxy_io.dart';
import 'package:caocode/network/proxy_settings.dart';
import 'package:caocode/remote/remote_claude.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('the core: as picked; unset, the CLI where Claude Code is '
      'installed, else built-in', () {
    expect(ClaudeCore.parse(null), ClaudeCore.builtin);
    expect(ClaudeCore.parse('builtin'), ClaudeCore.builtin);
    expect(ClaudeCore.parse('cli'), ClaudeCore.cli);
    expect(ClaudeCore.parse('nonsense'), ClaudeCore.builtin);
    expect(ClaudeCore.parse(true), ClaudeCore.builtin);

    ClaudeCore.cliInstalled = () => true;
    addTearDown(() => ClaudeCore.cliInstalled = () => false);
    expect(ClaudeCore.parse(null), ClaudeCore.cli);
    expect(ClaudeCore.parse('nonsense'), ClaudeCore.cli);
    expect(ClaudeCore.parse('builtin'), ClaudeCore.builtin);
    expect(ClaudeCore.parse('cli'), ClaudeCore.cli);
  });

  group('what runs a session here', () {
    late Directory root;
    late String cwd;
    late File args;

    setUp(() {
      root = Directory.systemTemp.createTempSync('caocode-core-');
      cwd = p.join(root.resolveSymbolicLinksSync(), 'project');
      Directory(cwd).createSync();
      args = File(p.join(root.path, 'args'));
      // A CLI that says what it was started with, and ends.
      final fake = File(p.join(root.path, 'claude'))
        ..writeAsStringSync('#!/bin/sh\nprintf "%s\\n" "\$@" > ${args.path}\n');
      Process.runSync('chmod', ['+x', fake.path]);
      ClaudePathSetting.current = () => fake.path;
      ProcessTransport.registry = ClaudeProcessRegistry(
        file: File(p.join(root.path, 'processes.json')),
        lookup: (_) async => null,
        signal: (_) => false,
      );
      NetworkProxy.instance.follow(
        ValueNotifier(0),
        (key) => key == ProxyMode.settingKey ? ProxyMode.off.value : null,
      );
    });

    tearDown(() {
      ClaudePathSetting.current = () => null;
      ClaudeCore.current = () => ClaudeCore.fallback;
      ClaudeEnvironment.use(null);
      root.deleteSync(recursive: true);
    });

    void environment({String? key}) => ClaudeEnvironment.use({
      'HOME': root.path,
      'PATH': '/usr/bin:/bin',
      ClaudeEnvironment.dataPathVariable: p.join(root.path, 'config'),
      'ANTHROPIC_API_KEY': ?key,
    });

    Future<ClaudeCodeTransport> start({Map<String, String>? env}) async {
      final transport = await startClaude(ClaudeLaunch(cwd: cwd, env: env));
      addTearDown(() async {
        transport.close();
        await transport.exited.timeout(const Duration(seconds: 20));
      });
      return transport;
    }

    test('the built-in core, on a provider\'s model', () async {
      environment();
      ClaudeCore.current = () => ClaudeCore.builtin;
      expect(
        await start(env: {'ANTHROPIC_AUTH_TOKEN': 'token'}),
        isA<DartCoreTransport>(),
      );
      expect(args.existsSync(), isFalse);
    });

    test('the built-in core on none: not started on the machine\'s own '
        'setup, key or not; told where to add one', () async {
      environment(key: 'sk-user');
      ClaudeCore.current = () => ClaudeCore.builtin;
      await expectLater(
        startClaude(ClaudeLaunch(cwd: cwd)),
        throwsA(
          isA<ClaudeUnavailable>().having(
            (error) => error.message,
            'message',
            allOf(contains('Settings → Models'), contains('CLI')),
          ),
        ),
      );
      expect(args.existsSync(), isFalse);
    });

    test('the CLI picked: the CLI, key or not', () async {
      environment(key: 'sk-user');
      ClaudeCore.current = () => ClaudeCore.cli;
      expect(await start(), isA<ProcessTransport>());
      await _until(args.existsSync);
      expect(
        args.readAsLinesSync(),
        containsAllInOrder(['-p', '--input-format', 'stream-json']),
      );
    });
  });
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue);
}
