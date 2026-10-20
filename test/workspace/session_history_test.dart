import 'dart:async';
import 'dart:io';

import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/kernel/codex/codex_catalog.dart';
import 'package:caocode/kernel/codex/codex_environment.dart';
import 'package:caocode/kernel/codex/codex_environment_io.dart';
import 'package:caocode/kernel/codex/codex_process.dart';
import 'package:caocode/kernel/mock/mock_kernels.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/workspace/preference_store.dart';
import 'package:caocode/workspace/session_history_status.dart';
import 'package:caocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel/codex_environment_test.dart' show FakeCodexEnvironments;

SessionRecord record(String id, {bool linux = false}) => SessionRecord(
  id: id,
  title: 'Chat $id',
  updatedAt: DateTime(2026, 10, 20),
  cwd: linux ? '//wsl.localhost/Ubuntu/home/tester/project' : 'C:/project',
);

KernelDescriptor kernel(SessionCatalog catalog) => KernelDescriptor(
  id: 'codex',
  label: 'Codex',
  icon: Icons.bolt,
  description: '',
  create: MockKernels.codex.create,
  catalog: catalog,
);

class PagedCatalog implements ProgressiveSessionCatalog {
  PagedCatalog(this.controller);
  final CodexEnvironmentController controller;
  final calls = <(String, String?)>[];
  final blocked = <String, Completer<void>>{};
  Object? error;
  @override
  String get cacheKey => controller.selected.id;
  @override
  Future<ProjectCatalogPage> projectPage({String? cursor}) async {
    final host = controller.selected.id;
    calls.add((host, cursor));
    await blocked[host]?.future;
    if (error case final failure?) throw failure;
    final session = record(
      '$host-${cursor ?? 'recent'}',
      linux: host.startsWith('wsl:'),
    );
    return ProjectCatalogPage([
      ProjectRecord(path: session.cwd, sessions: [session]),
    ], nextCursor: cursor == null ? 'older' : null);
  }

  @override
  Stream<List<ProjectRecord>> projectPages() async* {
    yield (await projectPage()).projects;
  }

  @override
  Future<List<ProjectRecord>> projects() => throw StateError('Must use pages');
  @override
  Stream<List<SessionRecord>> sessionPages(String cwd) async* {
    yield [];
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => [];
  @override
  Future<void> delete(String id) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CodexEnvironmentController controller;
  late PagedCatalog catalog;
  late Workspace workspace;
  late MemoryPreferenceStore cache;
  setUp(() {
    controller = CodexEnvironmentController(backend: FakeCodexEnvironments());
    catalog = PagedCatalog(controller);
    cache = MemoryPreferenceStore();
    workspace = Workspace(
      kernels: [kernel(catalog)],
      environments: controller,
      historyCache: cache,
    );
  });
  tearDown(() {
    workspace.dispose();
    controller.dispose();
  });

  test(
    'loads only the first page until explicitly asked for older chats',
    () async {
      await workspace.load();
      expect(catalog.calls, [('windows', null)]);
      expect(workspace.historyCount, 1);
      expect(workspace.history.hasMore, isTrue);
      await workspace.loadMoreHistory();
      expect(catalog.calls, [('windows', null), ('windows', 'older')]);
      expect(workspace.historyCount, 2);
      expect(workspace.history.hasMore, isFalse);
      await workspace.refresh();
      expect(workspace.historyCount, 2); // Older cached rows stay available.
    },
  );

  test(
    'a cached Windows switch does not wait for an unfinished WSL read',
    () async {
      await workspace.load();
      final was = workspace.current;
      final blocked = catalog.blocked['wsl:Ubuntu'] = Completer<void>();
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      expect(workspace.history.loading, isTrue);
      final clock = Stopwatch()..start();
      await controller.select(const CodexEnvironment.windows());
      expect(workspace.current, same(was));
      expect(workspace.loading, isFalse);
      expect(clock.elapsedMilliseconds, lessThan(2000));
      expect(catalog.calls.where((c) => c.$1 == 'windows'), hasLength(1));
      blocked.complete();
      await pumpEventQueue();
      expect(workspace.current, same(was));
      expect(workspace.history.loading, isFalse);
    },
  );

  test(
    'a restarted workspace displays persisted metadata before its CLI replies',
    () async {
      await workspace.load();
      await workspace.loadMoreHistory();
      workspace.dispose();
      final waiting = catalog.blocked['windows'] = Completer<void>();
      workspace = Workspace(
        kernels: [kernel(catalog)],
        environments: controller,
        historyCache: cache,
      );
      final clock = Stopwatch()..start();
      final loading = workspace.load();
      await pumpEventQueue();
      expect(workspace.historyCount, 2);
      expect(workspace.current, isNotNull);
      expect(workspace.history.loading, isTrue);
      expect(clock.elapsedMilliseconds, lessThan(2000));
      waiting.complete();
      await loading;
      expect(workspace.historyCount, 2);
    },
  );

  test('failures preserve cached rows and retry clears the error', () async {
    await workspace.load();
    catalog.error = StateError('CLI unavailable');
    await workspace.refresh();
    expect(workspace.history.loading, isFalse);
    expect(workspace.history.error, isNotNull);
    expect(workspace.historyCount, 1);
    catalog.error = null;
    await workspace.refresh();
    expect(workspace.history.error, isNull);
    expect(workspace.history.loading, isFalse);
  });

  test('deleted metadata is removed from the persistent snapshot', () async {
    await workspace.load();
    workspace.delete(
      workspace.threads.firstWhere((thread) => thread.record != null),
    );
    await pumpEventQueue();
    final snapshots = (cache.preferences['catalogs'] as Map).values.expand(
      (v) => v as List,
    );
    expect(snapshots, isEmpty);
  });

  testWidgets(
    'loading, pagination, error and retry are visible and actionable',
    (tester) async {
      final waiting = catalog.blocked['windows'] = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 240,
              child: SessionHistoryStatus(workspace: workspace),
            ),
          ),
        ),
      );
      final pending = workspace.refresh();
      await tester.pump();
      expect(find.text('Loading chats…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.runAsync(() async {
        waiting.complete();
        await pumpEventQueue();
      });
      await tester.pump();
      await pending;
      await tester.pumpAndSettle();
      expect(find.text('Load older chats'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('session-history-more')));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(find.text('2 chats'), findsOneWidget);
      expect(find.text('Load older chats'), findsNothing);
      catalog.error = StateError('CLI unavailable');
      await tester.tap(find.byKey(const ValueKey('session-history-refresh')));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(find.text('Could not load chats'), findsOneWidget);
      expect(find.byTooltip('Retry loading chats'), findsOneWidget);
      catalog.error = null;
      await tester.tap(find.byKey(const ValueKey('session-history-refresh')));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(find.text('Could not load chats'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('a silent CLI times out and releases the loading state', () async {
    workspace.dispose();
    workspace = Workspace(
      kernels: [kernel(catalog)],
      environments: controller,
      historyTimeout: const Duration(milliseconds: 25),
    );
    final waiting = catalog.blocked['windows'] = Completer<void>();
    await workspace.refresh();
    expect(workspace.history.loading, isFalse);
    expect(workspace.history.error, isA<TimeoutException>());
    waiting.complete();
    await pumpEventQueue();
    // Late data cannot replace an already failed read.
    expect(workspace.historyCount, 0);
  });

  test(
    'real first page, hot switching and disk snapshot timings',
    () async {
      workspace.dispose();
      controller.dispose();
      controller = CodexEnvironmentController(
        backend: IoCodexEnvironmentBackend(),
      );
      final connections = <String>[];
      final real = CodexCatalog(
        environments: controller,
        transport: (cwd) {
          connections.add(cwd ?? 'windows');
          return localCodexTransport(cwd: cwd);
        },
      );
      final temp = await Directory.systemTemp.createTemp('caocode-history-');
      final disk = PreferenceStore.file('${temp.path}/metadata.json');
      workspace = Workspace(
        kernels: [kernel(real)],
        environments: controller,
        historyCache: disk,
      );
      try {
        final windows = Stopwatch()..start();
        await workspace.load();
        expect(workspace.history.error, isNull);
        debugPrint(
          'Windows first page: ${windows.elapsedMilliseconds} ms, ${workspace.historyCount} records',
        );
        final wsl = (await controller.choices()).firstWhere((e) => e.isWsl);
        final linux = Stopwatch()..start();
        await controller.select(wsl);
        await workspace.refresh();
        expect(workspace.history.error, isNull);
        expect(workspace.historyCount, lessThanOrEqualTo(100));
        debugPrint(
          'WSL first page: ${linux.elapsedMilliseconds} ms, ${workspace.historyCount} records; more=${workspace.history.hasMore}',
        );
        final calls = connections.length;
        final hot = Stopwatch()..start();
        for (var i = 0; i < 5; i++) {
          await controller.select(const CodexEnvironment.windows());
          expect(workspace.history.loading, isFalse);
          await controller.select(wsl);
          expect(workspace.history.loading, isFalse);
        }
        expect(connections.length, calls);
        debugPrint(
          '10 cached switches: ${hot.elapsedMilliseconds} ms, 0 additional CLI starts',
        );
        workspace.dispose();
        workspace = Workspace(
          kernels: [kernel(real)],
          environments: controller,
          historyCache: disk,
        );
        final restored = Completer<int>();
        final clock = Stopwatch()..start();
        void observe() {
          if (!restored.isCompleted && workspace.historyCount > 0) {
            restored.complete(clock.elapsedMilliseconds);
          }
        }

        workspace.addListener(observe);
        final reload = workspace.load();
        final visibleAt = await restored.future.timeout(
          const Duration(seconds: 2),
        );
        debugPrint('Disk snapshot visible: $visibleAt ms');
        await reload;
        workspace.removeListener(observe);
        expect(workspace.history.error, isNull);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
        !const bool.fromEnvironment('CAOCODE_TEST_ENVIRONMENTS'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
