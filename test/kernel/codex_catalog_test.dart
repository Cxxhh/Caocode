import 'dart:async';
import 'dart:io';

import 'package:caocode/kernel/codex/codex_catalog.dart';
import 'package:caocode/kernel/codex/codex_environment.dart';
import 'package:caocode/kernel/codex/codex_environment_io.dart';
import 'package:caocode/kernel/codex/codex_host.dart';
import 'package:caocode/kernel/codex/codex_transport.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'codex_environment_test.dart' show FakeCodexEnvironments;

class _HistoryTransport implements CodexTransport {
  final requests = <Map<String, Object?>>[];
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );
  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;
  @override
  void close() => unawaited(_messages.close());
  @override
  void write(Map<String, Object?> message) {
    if (!message.containsKey('id')) return;
    requests.add(message);
    final params = message['params'] as Map;
    _messages.add({
      'id': message['id'],
      'result': message['method'] == 'thread/list'
          ? {
              'data': [
                {
                  'id': params['cursor'] == null ? 'one' : 'two',
                  'cwd': '/home/tester/project',
                  'preview': 'An existing CLI conversation',
                },
              ],
              if (params['cursor'] == null) 'nextCursor': 'page-two',
            }
          : <String, Object?>{},
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('projects launch in the selected host and list all pages without filtering its root', () async {
    final controller = CodexEnvironmentController(
      backend: FakeCodexEnvironments(),
    );
    addTearDown(controller.dispose);
    final locations = <String?>[];
    final connections = <_HistoryTransport>[];
    final catalog = CodexCatalog(
      environments: controller,
      transport: (cwd) {
        locations.add(cwd);
        final connection = _HistoryTransport();
        connections.add(connection);
        return connection;
      },
    );
    await controller.select(const CodexEnvironment.wsl('Ubuntu'));
    final projects = await catalog.projects();
    expect(projects.single.sessions.map((s) => s.id), ['one', 'two']);
    expect(locations, [r'\\wsl.localhost\Ubuntu\']);
    final lists = connections.single.requests.where(
      (m) => m['method'] == 'thread/list',
    );
    expect(lists, hasLength(2));
    expect(
      lists.every((m) => !(m['params'] as Map).containsKey('cwd')),
      isTrue,
    );
    expect(
      connections.single.requests.any((m) => m['method'] == 'turn/start'),
      isFalse,
    );
    await controller.select(const CodexEnvironment.windows());
    await catalog.projects();
    expect(locations.last, isNull);
  });

  test('opening a project uses its own host and retains the selected path spelling', () async {
    final controller = CodexEnvironmentController(
      backend: FakeCodexEnvironments(),
    );
    addTearDown(controller.dispose);
    _HistoryTransport? connection;
    String? location;
    final catalog = CodexCatalog(
      environments: controller,
      transport: (cwd) {
        location = cwd;
        return connection = _HistoryTransport();
      },
    );
    const project = r'\\wsl.localhost\Ubuntu\home\tester\project';
    final records = await catalog.sessionsIn(project);
    expect(location, project);
    expect(records.every((r) => r.cwd == project), isTrue);
    expect(
      connection!.requests
          .where((m) => m['method'] == 'thread/list')
          .every((m) => (m['params'] as Map).containsKey('cwd')),
      isTrue,
    );
  });

  test(
    'a page stops at its cursor; an explicit older page keeps the same host',
    () async {
      final controller = CodexEnvironmentController(
        backend: FakeCodexEnvironments(),
      );
      addTearDown(controller.dispose);
      final connections = <_HistoryTransport>[];
      final catalog = CodexCatalog(
        environments: controller,
        transport: (_) {
          final connection = _HistoryTransport();
          connections.add(connection);
          return connection;
        },
      );
      final first = await catalog.projectPage();
      expect(first.projects.single.sessions.single.id, 'one');
      expect(first.nextCursor, 'page-two');
      expect(
        connections.single.requests.where((m) => m['method'] == 'thread/list'),
        hasLength(1),
      );
      final second = await catalog.projectPage(cursor: first.nextCursor);
      expect(second.projects.single.sessions.single.id, 'two');
      expect(second.nextCursor, isNull);
    },
  );

  test(
    'real Windows and WSL histories are listed from the selected host',
    () async {
      final controller = CodexEnvironmentController(
        backend: IoCodexEnvironmentBackend(),
      );
      addTearDown(controller.dispose);
      final catalog = CodexCatalog(environments: controller);
      for (final environment in await controller.choices()) {
        await controller.select(environment);
        final projects = await catalog.projects();
        for (final project in projects) {
          expect(environment.accepts(project.path), isTrue);
          if (environment.isWsl) {
            expect(
              wslProject(project.path)?.distribution,
              environment.distribution,
            );
          }
        }
        debugPrint(
          '${environment.label}: ${projects.length} projects, ${projects.fold<int>(0, (n, p) => n + p.sessions.length)} sessions',
        );
        if (projects.isNotEmpty) {
          final first = projects.first;
          final records = await catalog.sessionsIn(first.path);
          expect(
            records.map((r) => r.id),
            containsAll(first.sessions.map((r) => r.id)),
          );
          debugPrint(
            '${environment.label}: reopened project lists ${records.length} sessions',
          );
        }
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('CAOCODE_TEST_ENVIRONMENTS'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
