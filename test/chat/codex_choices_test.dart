import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_picker.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Codex composer offers localized effort and four permissions', (
    tester,
  ) async {
    final session = ChatSession(
      kernel: MockKernels.codex,
      kernels: [MockKernels.codex],
      historyCount: 0,
    );
    addTearDown(session.dispose);
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
}
