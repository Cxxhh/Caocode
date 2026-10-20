import 'dart:async';

import 'package:caocode/chat/chat_session.dart';
import 'package:caocode/chat/composer/composer.dart';
import 'package:caocode/chat/composer/composer_picker.dart';
import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/kernel/codex/codex_kernel.dart';
import 'package:caocode/kernel/codex/codex_transport.dart';
import 'package:caocode/kernel/mock/mock_kernels.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpComposer(WidgetTester tester, ChatSession session) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          ...AppLocalizations.localizationsDelegates,
          FlutterQuillLocalizations.delegate,
        ],
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ListenableBuilder(
              listenable: session,
              builder: (context, _) =>
                  ChatComposer(session: session, draft: session.draft),
            ),
          ),
        ),
      ),
    );
    session.attach();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Fast toolbar shares command state without sending or changing the draft',
    (tester) async {
      final session = ChatSession(
        kernel: MockKernels.codex,
        kernels: [MockKernels.codex],
        historyCount: 0,
      );
      addTearDown(session.dispose);
      await pumpComposer(tester, session);
      session.draft.restore('尚未发送的草稿', const []);
      await tester.pumpAndSettle();
      final draft = session.draft.content!.toJson();
      final toggle = find.byKey(const ValueKey('composer-fast-mode'));
      expect(tester.widget<IconButton>(toggle).isSelected, false);
      expect(find.bySemanticsLabel('开启 Fast（当前已关闭）'), findsOneWidget);
      expect(find.text('Fast off'), findsNothing);
      final pickerCount = find.byType(ComposerPicker).evaluate().length;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(session.fastMode!.fastEnabled, true);
      expect(tester.widget<IconButton>(toggle).isSelected, true);
      expect(find.bySemanticsLabel('关闭 Fast（当前已开启）'), findsOneWidget);
      expect(find.byType(ComposerPicker), findsNWidgets(pickerCount));
      expect(session.itemCount, 0);
      expect(session.draft.content!.toJson(), draft);

      session.send(const ComposerMessage(text: '/fast off'));
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(toggle).isSelected, false);
      session.send(const ComposerMessage(text: '/Fast on'));
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(toggle).isSelected, true);
      final count = session.itemCount;
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(session.itemCount, count);
      expect(session.fastMode!.fastEnabled, false);
      expect(session.draft.content!.toJson(), draft);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Fast toolbar handles narrow layouts and unsupported models', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 750);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = ChatSession(
      kernel: MockKernels.codex,
      kernels: [MockKernels.codex],
      historyCount: 0,
    );
    addTearDown(session.dispose);
    await pumpComposer(tester, session);
    final toggle = find.byKey(const ValueKey('composer-fast-mode'));
    expect(toggle.hitTestable(), findsOneWidget);
    expect(tester.getSize(toggle), const Size(24, 22));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(session.fastMode!.fastEnabled, true);
    final models = session.models!;
    models.onSelected(
      models.options.singleWhere((model) => model.id == 'gpt-5.5-mini'),
    );
    await tester.pumpAndSettle();
    expect(toggle, findsOneWidget);
    expect(tester.widget<IconButton>(toggle).onPressed, isNull);
    expect(find.bySemanticsLabel('Fast 不可用'), findsOneWidget);
    expect(find.text('Fast 不可用'), findsNothing);
    expect(session.fastMode!.fastEnabled, false);
    expect(session.fastMode!.fastAvailable, false);
    models.onSelected(
      models.options.singleWhere((model) => model.id == 'gpt-5.5-codex'),
    );
    await tester.pumpAndSettle();
    expect(toggle, findsOneWidget);
    expect(tester.widget<IconButton>(toggle).isSelected, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'resumed third-party conversation keeps Fast after off and model picks',
    (tester) async {
      final server = _ThirdPartyCodexTransport();
      late final KernelDescriptor codex;
      codex = KernelDescriptor(
        id: 'codex',
        label: 'Codex',
        icon: Icons.data_object_rounded,
        description: 'Codex',
        create: (context) => CodexKernel(codex, server, context: context),
      );
      final session = ChatSession(
        kernel: codex,
        kernels: [codex],
        kernelContext: KernelContext(
          resume: SessionRecord(
            id: 'saved',
            title: 'Saved',
            updatedAt: DateTime(2026),
            cwd: '/project',
          ),
          settings: const {'model': 'gpt-5.6-sol'},
        ),
        historyCount: 0,
      );
      addTearDown(session.dispose);
      await pumpComposer(tester, session);
      session.draft.restore('旧对话中的未发送草稿', const []);
      await tester.pumpAndSettle();
      final draft = session.draft.content!.toJson();
      final count = session.itemCount;
      final toggle = find.byKey(const ValueKey('composer-fast-mode'));
      expect(tester.widget<IconButton>(toggle).isSelected, true);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(toggle, findsOneWidget);
      expect(tester.widget<IconButton>(toggle).isSelected, false);
      expect(tester.widget<IconButton>(toggle).onPressed, isNotNull);

      for (final id in ['gpt-6.1-sol', 'gpt-6-sol', 'gpt-5.6-sol']) {
        final modelPicker = find.byWidgetPredicate(
          (widget) => widget is ComposerPicker && widget.settingsOf != null,
        );
        await tester.tap(modelPicker);
        await tester.pumpAndSettle();
        await tester.tap(find.text(id).last);
        await tester.pumpAndSettle();
        expect(session.models!.selected.id, id);
        expect(toggle, findsOneWidget);
        expect(tester.widget<IconButton>(toggle).onPressed, isNotNull);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<IconButton>(toggle).isSelected, true);
        final update = server.calls.last;
        expect(update['method'], 'thread/settings/update');
        expect((update['params'] as Map)['model'], id);
        expect((update['params'] as Map)['serviceTier'], 'fast');
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(toggle, findsOneWidget);
        expect(tester.widget<IconButton>(toggle).isSelected, false);
        expect(tester.widget<IconButton>(toggle).onPressed, isNotNull);
        expect(find.bySemanticsLabel('开启 Fast（当前已关闭）'), findsOneWidget);
      }
      expect(session.itemCount, count);
      expect(session.draft.content!.toJson(), draft);
      expect(
        server.calls.where((call) => call['method'] == 'turn/start'),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('other kernels do not show the Fast toolbar control', (
    tester,
  ) async {
    final session = ChatSession(
      kernel: MockKernels.claudeCode,
      kernels: [MockKernels.claudeCode],
      historyCount: 0,
    );
    addTearDown(session.dispose);
    await pumpComposer(tester, session);
    expect(find.byKey(const ValueKey('composer-fast-mode')), findsNothing);
  });

  for (final resumed in [false, true]) {
    testWidgets(
      'Fast stays visible when model labels grow (${resumed ? 'saved' : 'new'})',
      (tester) async {
        final server = _ThirdPartyCodexTransport();
        late final KernelDescriptor codex;
        codex = KernelDescriptor(
          id: 'codex',
          label: 'Codex',
          icon: Icons.data_object_rounded,
          description: 'Codex',
          create: (context) => CodexKernel(codex, server, context: context),
        );
        final session = ChatSession(
          kernel: codex,
          kernels: [codex],
          kernelContext: KernelContext(
            resume: resumed
                ? SessionRecord(
                    id: 'saved',
                    title: 'Saved',
                    updatedAt: DateTime(2026),
                    cwd: '/project',
                  )
                : null,
            settings: const {'model': 'gpt-6-sol', 'permission': 'full-access'},
          ),
          historyCount: 0,
        );
        addTearDown(session.dispose);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await pumpComposer(tester, session);
        final toggle = find.byKey(const ValueKey('composer-fast-mode'));
        for (final width in [320.0, 390.0, 800.0]) {
          tester.view.physicalSize = Size(width, 750);
          for (final id in ['gpt-6-sol', 'gpt-6.1-sol', 'gpt-5.6-sol']) {
            final models = session.models!;
            models.onSelected(
              models.options.singleWhere((model) => model.id == id),
            );
            await tester.pumpAndSettle();
            expect(
              toggle.hitTestable(),
              findsOneWidget,
              reason: '$id at width $width must be clickable without scrolling',
            );
            final before = session.fastMode!.fastEnabled;
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            expect(session.fastMode!.fastEnabled, !before);
            expect(toggle.hitTestable(), findsOneWidget);
            await tester.tap(toggle);
            await tester.pumpAndSettle();
            expect(session.fastMode!.fastEnabled, before);
            expect(toggle.hitTestable(), findsOneWidget);
          }
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Codex composer offers localized effort and four permissions', (
    tester,
  ) async {
    final session = ChatSession(
      kernel: MockKernels.codex,
      kernels: [MockKernels.codex],
      historyCount: 0,
    );
    addTearDown(session.dispose);
    await pumpComposer(tester, session);
    expect(session.modes, isNull);
    expect(find.text('请求批准'), findsOneWidget);
    expect(find.text('中'), findsOneWidget);
    final effortPicker = find.byWidgetPredicate(
      (widget) => widget is ComposerPicker && widget.tooltip == '推理强度',
    );
    await tester.tap(effortPicker);
    await tester.pumpAndSettle();
    expect(find.text('推理强度'), findsOneWidget);
    await tester.tap(find.text('高'));
    await tester.pumpAndSettle();
    expect(session.selected(KernelChoiceKind.effort), 'high');
    expect(find.text('高'), findsOneWidget);

    await tester.tap(find.text('请求批准'));
    await tester.pumpAndSettle();
    expect(find.text('应如何批准 Codex 操作？'), findsOneWidget);
    expect(find.text('帮我批准'), findsOneWidget);
    expect(find.text('完全访问权限'), findsOneWidget);
    expect(find.text('自定义 (config.toml)'), findsOneWidget);
    expect(find.text('编辑外部文件和使用互联网时始终询问'), findsOneWidget);
    await tester.tap(find.text('完全访问权限'));
    await tester.pumpAndSettle();
    expect(session.selected(KernelChoiceKind.permission), 'full-access');
    final permissionPicker = tester.widget<ComposerPicker>(
      find.byWidgetPredicate(
        (widget) =>
            widget is ComposerPicker && widget.selected.id == 'full-access',
      ),
    );
    expect(permissionPicker.selected.caution, isTrue);

    await tester.tap(find.text('完全访问权限'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义 (config.toml)'));
    await tester.pumpAndSettle();
    expect(session.selected(KernelChoiceKind.permission), 'custom');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Codex model menu only picks models; effort stays in the toolbar',
    (tester) async {
      final session = ChatSession(
        kernel: MockKernels.codex,
        kernels: [MockKernels.codex],
        historyCount: 0,
      );
      addTearDown(session.dispose);
      await pumpComposer(tester, session);
      expect(session.models!.selected.id, 'gpt-5.5-codex');
      expect(find.text('CLI 默认'), findsNothing);
      final modelPicker = find.byWidgetPredicate(
        (widget) => widget is ComposerPicker && widget.settingsOf != null,
      );
      final picker = tester.widget<ComposerPicker>(modelPicker);
      expect(picker.label, 'GPT-5.5 Codex');
      for (final model in picker.options) {
        expect(picker.settingsOf!(model), isEmpty);
        expect(model.id, isNot('default'));
      }
      await tester.tap(modelPicker);
      await tester.pumpAndSettle();
      expect(find.text('CLI 默认'), findsNothing);
      expect(find.text('推理强度'), findsNothing);
      await tester.tap(find.text('GPT-5.5 mini').last);
      await tester.pumpAndSettle();
      expect(session.models!.selected.id, 'gpt-5.5-mini');
      expect(
        find.byWidgetPredicate(
          (widget) => widget is ComposerPicker && widget.tooltip == '推理强度',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

// The Windows CLI's custom-provider catalog exposes empty speed-tier lists.
class _ThirdPartyCodexTransport implements CodexTransport {
  final _output = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final calls = <Map<String, Object?>>[];

  @override
  Stream<Map<String, Object?>> get messages => _output.stream;

  @override
  void write(Map<String, Object?> message) {
    calls.add(message);
    if (!message.containsKey('id')) return;
    final result = switch (message['method']) {
      'config/read' => {
        'config': {'model_provider': 'custom', 'service_tier': 'fast'},
      },
      'model/list' => {
        'data': [
          for (final id in ['gpt-6.1-sol', 'gpt-6-sol', 'gpt-5.6-sol'])
            {
              'model': id,
              'displayName': id,
              'isDefault': id == 'gpt-6-sol',
              'serviceTiers': <Object>[],
              'additionalSpeedTiers': <Object>[],
              'supportedReasoningEfforts': [
                {'reasoningEffort': 'high'},
              ],
            },
        ],
      },
      'thread/resume' => {
        'modelProvider': 'custom',
        'serviceTier': 'fast',
        'thread': {'id': 'saved', 'turns': <Object>[]},
      },
      _ => <String, Object?>{},
    };
    _output.add({'id': message['id'], 'result': result});
  }

  @override
  void close() => unawaited(_output.close());
}
