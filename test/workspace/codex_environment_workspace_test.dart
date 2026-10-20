import 'dart:async';

import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/kernel/codex/codex_environment.dart';
import 'package:caocode/kernel/mock/mock_kernels.dart';
import 'package:caocode/main.dart';
import 'package:caocode/sidebar/sidebar.dart';
import 'package:caocode/workspace/chat_grid.dart';
import 'package:caocode/workspace/preference_store.dart';
import 'package:caocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel/codex_environment_test.dart' show FakeCodexEnvironments;

const _windows = r'C:\work\windows-project';
const _ubuntu = '//wsl.localhost/Ubuntu/home/tester/linux-project';
const _debian = '//wsl.localhost/Debian/home/tester/debian-project';

SessionRecord _record(String id, String cwd) => SessionRecord(
  id: id,
  title: 'History $id',
  updatedAt: DateTime(2026, 10, 20),
  cwd: cwd,
);

class _Catalog implements SessionCatalog {
  _Catalog(this.environments);
  final CodexEnvironmentController environments;
  final records = <SessionRecord>[];
  final listed = <String>[];
  final opened = <String>[];
  Completer<void>? delay;

  @override
  Future<List<ProjectRecord>> projects() async {
    final target = environments.selected;
    listed.add(target.id);
    final waiting = delay;
    delay = null;
    await waiting?.future;
    return [
      for (final record in records)
        if (target.accepts(record.cwd))
          ProjectRecord(path: record.cwd, sessions: [record]),
    ];
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    opened.add(cwd);
    return records.where((record) => record.cwd == cwd).toList();
  }

  @override
  Future<void> delete(String id) async {}
}

KernelDescriptor _kernel(_Catalog catalog) {
  final mock = MockKernels.claudeCode;
  return KernelDescriptor(
    id: mock.id,
    label: mock.label,
    icon: mock.icon,
    description: mock.description,
    create: mock.create,
    catalog: catalog,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CodexEnvironmentController controller;
  late _Catalog catalog;
  late Workspace workspace;

  setUp(() {
    controller = CodexEnvironmentController(backend: FakeCodexEnvironments());
    catalog = _Catalog(controller);
    workspace = Workspace(
      kernels: [_kernel(catalog)],
      environments: controller,
    );
  });
  tearDown(() {
    workspace.dispose();
    controller.dispose();
  });

  test(
    'switching hides other projects and loads history without a new chat',
    () async {
      catalog.records.addAll([
        _record('win', _windows),
        _record('linux', _ubuntu),
        _record('debian', _debian),
      ]);
      await workspace.load();
      final windowsChat = workspace.current;
      expect(workspace.sidebarProjects.map((p) => p.path), [_windows]);
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      expect(workspace.projects, isEmpty);
      expect(workspace.current, isNull);
      expect(workspace.grid.isEmpty, isTrue);
      await workspace.refresh();
      expect(workspace.sidebarProjects.map((p) => p.path), [_ubuntu]);
      expect(
        workspace.threads
            .where(workspace.listsInSidebar)
            .map((t) => t.record?.id),
        contains('linux'),
      );
      expect(
        workspace.threads
            .where(workspace.listsInSidebar)
            .map((t) => t.record?.id),
        isNot(contains('win')),
      );
      final linuxChat = workspace.current;
      await controller.select(const CodexEnvironment.wsl('Debian'));
      await workspace.refresh();
      expect(workspace.sidebarProjects.map((p) => p.path), [_debian]);
      await controller.select(const CodexEnvironment.windows());
      expect(workspace.current, same(windowsChat));
      await workspace.refresh();
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      expect(workspace.current, same(linuxChat));
      await workspace.refresh();
    },
  );

  test(
    'new Codex chats follow CLI configuration across environments',
    () async {
      workspace.dispose();
      final contexts = <KernelContext>[];
      final mock = MockKernels.codex;
      final descriptor = KernelDescriptor(
        id: mock.id,
        label: mock.label,
        icon: mock.icon,
        description: mock.description,
        catalog: catalog,
        create: (context) {
          contexts.add(context);
          return mock.create(context);
        },
      );
      workspace = Workspace(
        kernels: [descriptor],
        environments: controller,
        preferences: MemoryPreferenceStore({
          'settings': {
            'model': 'remembered-windows-model',
            'permission': 'auto',
          },
        }),
      );
      await workspace.load();
      await workspace.openFolder(_windows);
      expect(contexts.last.settings.containsKey('model'), false);
      expect(contexts.last.settings['permission'], 'auto');
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      await workspace.refresh();
      await workspace.openFolder(_ubuntu);
      expect(contexts.last.cwd, _ubuntu);
      expect(contexts.last.settings.containsKey('model'), false);
      expect(contexts.last.settings['permission'], 'auto');
    },
  );

  test(
    'an already known project re-reads its histories each time it opens',
    () async {
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      final first = await workspace.openFolder(_ubuntu);
      await pumpEventQueue();
      catalog.records.add(_record('new-external-chat', _ubuntu));
      expect(await workspace.openFolder(_ubuntu), same(first));
      await pumpEventQueue();
      expect(catalog.opened, [_ubuntu, _ubuntu]);
      expect(
        workspace.threads.map((t) => t.record?.id),
        contains('new-external-chat'),
      );
    },
  );

  test('rapid switches re-list the latest environment after an earlier read finishes', () async {
    catalog.records.addAll([
      _record('win', _windows),
      _record('linux', _ubuntu),
    ]);
    await workspace.load();
    final pending = catalog.delay = Completer<void>();
    await controller.select(const CodexEnvironment.wsl('Ubuntu'));
    await controller.select(const CodexEnvironment.windows());
    pending.complete();
    await workspace.refresh();
    expect(catalog.listed.last, 'windows');
    expect(workspace.current?.project.path, _windows);
    expect(workspace.sidebarProjects.map((p) => p.path), [_windows]);
  });

  test(
    'switching restores all panes and keeps project path spellings together',
    () async {
      final a = await workspace.openFolder(_windows);
      final b = await workspace.openFolder(r'C:\work\another');
      workspace.openBeside(a, b, PaneSide.right);
      final cells = workspace.grid.cells;
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      await workspace.refresh();
      await workspace.openFolder(_ubuntu);
      await workspace.openFolder(r'\\wsl$\ubuntu\home\tester\linux-project');
      expect(workspace.projects, hasLength(1));
      await controller.select(const CodexEnvironment.windows());
      expect(workspace.current, same(a));
      expect(workspace.grid.cells, cells);
      await workspace.refresh();
    },
  );

  test('loading one environment preserves marks and remembered projects from the other', () async {
    workspace.dispose();
    final store = MemoryPreferenceStore({
      'sidebar': {
        'folders': [_windows, _ubuntu],
        'pinned': ['windows-kept'],
        'names': {'windows-kept': 'Windows custom title'},
      },
    });
    await controller.select(const CodexEnvironment.wsl('Ubuntu'));
    workspace = Workspace(
      kernels: [_kernel(catalog)],
      environments: controller,
      preferences: store,
    );
    await workspace.load();
    expect(workspace.projects.map((p) => p.path), [_ubuntu]);
    final saved = await store.read();
    expect((saved['sidebar'] as Map)['folders'], contains(_windows));
    expect((saved['sidebar'] as Map)['pinned'], ['windows-kept']);
    catalog.records.add(_record('windows-kept', _windows));
    await controller.select(const CodexEnvironment.windows());
    await workspace.refresh();
    final kept = workspace.threads.firstWhere(
      (t) => t.record?.id == 'windows-kept',
    );
    expect(kept.pinned, isTrue);
    expect(kept.title, 'Windows custom title');
  });

  testWidgets(
    'the sidebar changes environment and shows histories immediately',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final previous = CodexEnvironmentController.instance;
      CodexEnvironmentController.instance = controller;
      addTearDown(() => CodexEnvironmentController.instance = previous);
      catalog.records.addAll([
        _record('win', _windows),
        _record('linux', _ubuntu),
      ]);
      await tester.pumpWidget(CaocodeApp(workspace: workspace));
      await tester.runAsync(workspace.load);
      await tester.pumpAndSettle();
      Finder history(String id) => find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('History $id'),
      );
      expect(history('win'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('codex-environment-picker')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('WSL2 · Ubuntu').last);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => pumpEventQueue());
        if (controller.selected.isWsl && !workspace.history.loading) break;
      }
      expect(workspace.history.loading, isFalse);
      await tester.pumpAndSettle();
      expect(history('win'), findsNothing);
      expect(history('linux'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      // CaocodeApp owns the workspace, so replace it before this test's teardown.
      workspace = Workspace(
        kernels: [_kernel(catalog)],
        environments: controller,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
