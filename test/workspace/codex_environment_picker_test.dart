import 'package:caocode/kernel/codex/codex_environment.dart';
import 'package:caocode/main.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/workspace/codex_environment_picker.dart';
import 'package:caocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel/codex_environment_test.dart' show FakeCodexEnvironments;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CodexEnvironmentController before;
  late CodexEnvironmentController controller;
  final calls = <MethodCall>[];
  String? chosen;

  setUp(() {
    before = CodexEnvironmentController.instance;
    controller = CodexEnvironmentController(backend: FakeCodexEnvironments());
    CodexEnvironmentController.instance = controller;
    calls.clear();
    chosen = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('caocode/window'), (
          call,
        ) async {
          if (call.method == 'pickDirectory') {
            calls.add(call);
            return chosen;
          }
          return null;
        });
  });
  tearDown(() {
    CodexEnvironmentController.instance = before;
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('caocode/window'), null);
  });

  testWidgets(
    'selecting WSL changes the directory passed by Open project, then Windows restores its own',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final workspace = Workspace();
      await tester.pumpWidget(CaocodeApp(workspace: workspace));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('codex-environment-picker')).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('WSL2 · Ubuntu').last);
      await tester.pumpAndSettle();
      expect(controller.selected.id, 'wsl:Ubuntu');
      final open = find.text(englishLocalizations.sidebarOpenProject).first;
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(
        (calls.last.arguments as Map)['directory'],
        r'\\wsl.localhost\Ubuntu\home\tester',
      );
      expect(workspace.current, isNull); // Cancel creates no project.
      await controller.select(const CodexEnvironment.windows());
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect((calls.last.arguments as Map)['directory'], r'C:\Users\tester');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'wrong-host selections show a recoverable error instead of opening a different CLI',
    (tester) async {
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      chosen = r'C:\project';
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickCodexProjectDirectory(context),
              child: const Text('Pick'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(find.text('无法打开项目目录'), findsOneWidget);
      expect(find.textContaining('所选目录不属于 WSL2'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(controller.selected.id, 'wsl:Ubuntu');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'Windows remains selectable when a saved WSL distribution cannot be enumerated',
    (tester) async {
      await controller.select(const CodexEnvironment.wsl('Ubuntu'));
      (controller.backend as FakeCodexEnvironments).discoveryError = StateError(
        'WSL unavailable',
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: CodexEnvironmentPicker()),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('codex-environment-picker')));
      await tester.pumpAndSettle();
      expect(find.textContaining('无法读取 WSL2'), findsOneWidget);
      await tester.tap(find.text('Windows · Codex'));
      await tester.pumpAndSettle();
      expect(controller.selected.id, 'windows');
      expect(tester.takeException(), isNull);
    },
  );
}
