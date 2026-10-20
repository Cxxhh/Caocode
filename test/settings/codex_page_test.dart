import 'dart:io';

import 'package:caocode/ide/ide_input.dart';
import 'package:caocode/kernel/codex/cc_switch_providers.dart';
import 'package:caocode/kernel/codex/codex_config_file.dart';
import 'package:caocode/kernel/codex/codex_config_setting.dart';
import 'package:caocode/kernel/codex/codex_environment.dart';
import 'package:caocode/kernel/codex/codex_path_setting.dart';
import 'package:caocode/kernel/codex/codex_provider_config.dart';
import 'package:caocode/kernel/codex/codex_providers.dart';
import 'package:caocode/l10n/app_localizations.dart';
import 'package:caocode/settings/pages/codex_page.dart';
import 'package:caocode/settings/pages/codex_provider_editor.dart';
import 'package:caocode/settings/pages/settings_widgets.dart';
import 'package:caocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../kernel/codex_environment_test.dart' show FakeCodexEnvironments;

void main() {
  late Directory directory;
  late UserSettings settings;
  late CodexProviders providers;
  late CodexConfigFile config;
  final opened = <String>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('caocode-codex-page-');
    settings = UserSettings(p.join(directory.path, 'settings.json'));
    await settings.load();
    providers = CodexProviders.memory();
    config = CodexConfigFile.at(p.join(directory.path, 'config.toml'));
    opened.clear();
  });
  tearDown(() async {
    settings.dispose();
    providers.dispose();
    await directory.delete(recursive: true);
  });
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> pump(
    WidgetTester tester, {
    double width = 1100,
    Future<CcSwitchSnapshot> Function(String?)? readCcSwitch,
  }) async {
    tester.view.physicalSize = Size(width, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CodexSettingsPage(
            settings: settings,
            providers: providers,
            onOpenFile: opened.add,
            resolveConfig: (path) async =>
                path == null ? config : CodexConfigFile.at(path),
            readCcSwitch: readCcSwitch,
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> click(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(finder.first));
    await settle(tester);
  }

  Future<void> type(WidgetTester tester, String label, String value) async {
    final box = find.widgetWithText(IdeInputBox, label);
    final finder = box.evaluate().isEmpty
        ? find.byWidgetPredicate(
            (widget) => widget is IdeInputBox && widget.semanticsLabel == label,
          )
        : box;
    final input = find.descendant(
      of: finder,
      matching: find.byType(EditableText),
    );
    await tester.ensureVisible(input);
    await tester.enterText(input, value);
    await tester.pump();
  }

  Map<String, Object?> ccsRow(String name, String token) => {
    'id': 'ccs-one',
    'name': name,
    'settings_config': {
      'config':
          'model_provider = "custom"\nmodel = "ccs-model"\n'
          '[model_providers.custom]\nname = "CCS"\n'
          'base_url = "https://ccs.example/v1"\nwire_api = "responses"\n',
      'auth': {'OPENAI_API_KEY': token},
    },
  };

  testWidgets(
    'environment switch keeps Windows and WSL CLI paths independent',
    (tester) async {
      final before = CodexEnvironmentController.instance;
      final environments = CodexEnvironmentController(
        backend: FakeCodexEnvironments(),
      );
      CodexEnvironmentController.instance = environments;
      addTearDown(() {
        CodexEnvironmentController.instance = before;
        environments.dispose();
      });
      await tester.runAsync(() async {
        await settings.update(
          '${CodexPathSetting.settingKey}.windows',
          r'C:\tools\codex.exe',
        );
        await settings.update(
          '${CodexPathSetting.settingKey}.wsl.Ubuntu',
          '/opt/codex',
        );
      });
      await pump(tester);
      Finder pathInput() => find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is SettingsTextField &&
              widget.semanticLabel == 'Codex CLI path',
        ),
        matching: find.byType(EditableText),
      );
      expect(
        tester.widget<EditableText>(pathInput()).controller.text,
        r'C:\tools\codex.exe',
      );
      await environments.select(const CodexEnvironment.wsl('Ubuntu'));
      await settle(tester);
      expect(
        tester.widget<EditableText>(pathInput()).controller.text,
        '/opt/codex',
      );
      await tester.enterText(pathInput(), '/home/tester/.local/bin/codex');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(
        settings['${CodexPathSetting.settingKey}.wsl.Ubuntu'],
        '/home/tester/.local/bin/codex',
      );
      expect(
        settings['${CodexPathSetting.settingKey}.windows'],
        r'C:\tools\codex.exe',
      );
      await environments.select(const CodexEnvironment.windows());
      await settle(tester);
      expect(
        tester.widget<EditableText>(pathInput()).controller.text,
        r'C:\tools\codex.exe',
      );
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'CCS links, refreshes, activates and explicitly imports local copies',
    (tester) async {
      var rows = [ccsRow('CCS gateway', 'original-key')];
      final reads = <String?>[];
      await pump(
        tester,
        readCcSwitch: (path) async {
          reads.add(path);
          return CcSwitchSnapshot.fromRows('/ccs.db', rows);
        },
      );
      await click(tester, '连接 CCS');
      expect(settings[CcSwitchSnapshot.pathSettingKey], '/ccs.db');
      expect(providers.providers, isEmpty);
      expect(find.text('CCS gateway'), findsOneWidget);
      await click(tester, '启用');
      expect(
        CodexProviderConfig((await tester.runAsync(config.read))!).apiKey,
        'original-key',
      );
      expect(providers.providers, isEmpty);

      rows = [ccsRow('Renamed in CCS', 'rotated-key')];
      await click(tester, '刷新 CCS');
      expect(find.text('Renamed in CCS'), findsOneWidget);
      expect(find.textContaining('CCS gateway'), findsNothing);
      await click(tester, '启用');
      expect(
        CodexProviderConfig((await tester.runAsync(config.read))!).apiKey,
        'rotated-key',
      );
      expect(providers.providers, isEmpty);
      expect(
        await tester.runAsync(() => File(settings.path).readAsString()),
        isNot(contains('rotated-key')),
      );

      await click(tester, '导入为本地副本');
      expect(find.byType(CodexProviderEditor), findsOneWidget);
      await click(tester, '保存');
      expect(providers.providers.single.name, 'Renamed in CCS (副本)');
      expect(await providers.key(providers.providers.single.id), 'rotated-key');
      rows = [];
      await click(tester, '刷新 CCS');
      expect(find.text('CCS 中没有可直连的 Codex 供应商。'), findsOneWidget);
      expect(providers.providers, hasLength(1));
      expect(reads, ['', '/ccs.db', '/ccs.db']);
      await click(tester, '断开连接');
      expect(settings[CcSwitchSnapshot.pathSettingKey], isNull);
      expect(
        CodexProviderConfig((await tester.runAsync(config.read))!).apiKey,
        'rotated-key',
      );
    },
  );

  testWidgets(
    'saved CCS link reloads and failed refresh removes stale entries',
    (tester) async {
      await tester.runAsync(
        () => settings.update(CcSwitchSnapshot.pathSettingKey, '/saved-ccs.db'),
      );
      var fails = false;
      await pump(
        tester,
        width: 390,
        readCcSwitch: (path) async {
          expect(path, '/saved-ccs.db');
          if (fails) {
            throw const FormatException('CCS test database unavailable');
          }
          return CcSwitchSnapshot.fromRows('/saved-ccs.db', [
            ccsRow('Linked provider', 'secret'),
          ]);
        },
      );
      await tester.ensureVisible(find.text('Linked provider'));
      expect(tester.takeException(), isNull);
      fails = true;
      await click(tester, '刷新 CCS');
      expect(find.text('Linked provider'), findsNothing);
      expect(
        find.textContaining('CCS test database unavailable'),
        findsOneWidget,
      );
      expect(providers.providers, isEmpty);
    },
  );

  testWidgets('CCS connects the edited path without requiring Enter first', (
    tester,
  ) async {
    String? requested;
    await pump(
      tester,
      readCcSwitch: (path) async {
        requested = path;
        return CcSwitchSnapshot(path: path!, providers: const []);
      },
    );
    final input = find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is SettingsTextField &&
            widget.semanticLabel == 'CCS database path',
      ),
      matching: find.byType(EditableText),
    );
    await tester.ensureVisible(input);
    await tester.enterText(input, '/custom/cc-switch.db');
    await click(tester, '连接 CCS');
    expect(requested, '/custom/cc-switch.db');
    expect(settings[CcSwitchSnapshot.pathSettingKey], '/custom/cc-switch.db');
  });

  testWidgets('Open config.toml hands the existing file to Fast IDE', (
    tester,
  ) async {
    await tester.runAsync(
      () => File(config.path).writeAsString('# my configuration\n'),
    );
    await pump(tester);
    await click(tester, '打开 config.toml');
    expect(opened, [config.path]);
    expect(await tester.runAsync(config.read), '# my configuration\n');
  });

  testWidgets('custom path is saved and the same file opens', (tester) async {
    await pump(tester);
    final custom = p.join(directory.path, 'custom', 'config.toml');
    final input = find.descendant(
      of: find.bySemanticsLabel('Codex config.toml path'),
      matching: find.byType(EditableText),
    );
    await tester.enterText(input.first, custom);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(settings[CodexConfigSetting.settingKey], custom);
    await click(tester, '打开 config.toml');
    expect(
      opened,
      [custom],
      reason: tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((widget) => widget.data)
          .join('\n'),
    );
    expect(await tester.runAsync(() => File(custom).exists()), true);
  });

  testWidgets(
    'add, activate, duplicate, import and restore the official provider',
    (tester) async {
      await tester.runAsync(
        () => File(config.path)
            .writeAsString('# retain\n[mcp_servers.files]\ncommand = "node"\n'),
      );
      await pump(tester);
      await click(tester, '添加供应商');
      await type(tester, '名称', 'Example gateway');
      await type(tester, 'API 地址', 'https://gateway.example/v1');
      await type(tester, '模型 ID', 'gateway-model');
      await type(tester, 'Codex provider API Key', 'ui-test-token');
      await click(tester, '保存并启用');
      expect(
        find.byType(CodexProviderEditor),
        findsNothing,
        reason: tester
            .widgetList<SelectableText>(find.byType(SelectableText))
            .map((widget) => widget.data)
            .join('\n'),
      );
      expect(providers.providers.single.name, 'Example gateway');
      final applied = CodexProviderConfig(
        (await tester.runAsync(config.read))!,
      );
      expect(applied.model, 'gateway-model');
      expect(applied.apiKey, 'ui-test-token');
      expect(applied.values['mcp_servers']['files']['command'], 'node');

      await click(tester, '复制');
      await click(tester, '保存');
      expect(providers.providers, hasLength(2));
      expect(providers.providers.last.name, 'Example gateway (副本)');
      await click(tester, '启用');
      expect(find.text('Example gateway (副本) · 已启用'), findsOneWidget);
      await click(tester, '导入当前配置');
      expect(find.byType(CodexProviderEditor), findsOneWidget);
      final modelInput = find.byWidgetPredicate(
        (widget) => widget is IdeInputBox && widget.semanticsLabel == '模型 ID',
      );
      expect(
        tester.widget<IdeInputBox>(modelInput).controller.text,
        'gateway-model',
      );
      await click(tester, '取消');
      await click(tester, '使用 OpenAI 官方');
      expect(
        CodexProviderConfig((await tester.runAsync(config.read))!).official,
        true,
      );
      expect(providers.providers, hasLength(2));
    },
  );

  testWidgets('narrow settings and provider editor do not overflow', (
    tester,
  ) async {
    await pump(tester, width: 390);
    expect(tester.takeException(), isNull);
    await click(tester, '添加供应商');
    await tester.ensureVisible(find.byType(SettingsSwitch));
    await tester.tap(find.byType(SettingsSwitch));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalid TOML stays editable and cannot replace live configuration',
    (tester) async {
      await tester.runAsync(
        () => File(config.path).writeAsString('# existing\n'),
      );
      await pump(tester);
      await click(tester, '添加供应商');
      await tester.ensureVisible(find.byType(SettingsSwitch));
      await tester.tap(find.byType(SettingsSwitch));
      await settle(tester);
      await type(tester, 'Codex provider TOML', '[broken');
      await click(tester, '保存并启用');
      expect(find.byType(CodexProviderEditor), findsOneWidget);
      expect(find.textContaining('不是有效的 TOML'), findsOneWidget);
      expect(await tester.runAsync(config.read), '# existing\n');
      expect(providers.providers, isEmpty);
    },
  );
}
