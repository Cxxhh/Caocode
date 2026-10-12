import 'dart:async';

import 'package:flutter/material.dart';

import '../../kernel/codex/codex_path_setting.dart';
import '../../l10n/l10n.dart';
import '../user_settings.dart';
import 'settings_widgets.dart';

/// The CLI owns credentials and model providers; the IDE picks its executable.
class CodexSettingsPage extends StatelessWidget {
  const CodexSettingsPage({super.key, this.settings});
  final UserSettings? settings;

  @override
  Widget build(BuildContext context) {
    final chinese = context.l10n.localeName.startsWith('zh');
    return AnimatedBuilder(
      animation: settings ?? const AlwaysStoppedAnimation(0),
      builder: (context, _) => SettingsPage(
        title: 'Codex CLI',
        description: chinese
            ? 'Caocode 使用已安装的 Codex CLI。账号、模型服务和工具配置由 Codex 管理。'
            : 'Caocode uses your installed Codex CLI. Codex manages accounts, model providers and tools.',
        children: [
          SettingsGroup(
            title: 'Codex CLI',
            children: [
              SettingsCard(
                children: [
                  SettingsRow(
                    label: chinese ? '可执行文件路径' : 'Executable path',
                    description: chinese
                        ? '留空时从 PATH 查找。打开 WSL 工程时使用该发行版中的 Linux Codex。修改后重启会话生效。'
                        : 'Leave empty to search PATH. WSL projects use Linux Codex in that distribution. Restart the session after changing this.',
                    trailing: SettingsTextField(
                      value:
                          CodexPathSetting.parse(
                            settings?[CodexPathSetting.settingKey],
                          ) ??
                          '',
                      hint: 'codex',
                      semanticLabel: 'Codex CLI path',
                      width: 260,
                      onSubmitted: (value) {
                        final saved = settings?.update(
                          CodexPathSetting.settingKey,
                          CodexPathSetting.parse(value),
                        );
                        if (saved != null) {
                          unawaited(
                            saved.catchError((Object error) {
                              debugPrint('Codex CLI path not kept: $error');
                            }),
                          );
                        }
                      },
                    ),
                  ),
                  SettingsRow(
                    label: chinese ? '登录与模型' : 'Sign in and models',
                    description: chinese
                        ? '在工程所在系统的终端运行 codex login。模型选择器自动读取 CLI 模型列表；“CLI 默认”使用当前 Codex 配置。'
                        : 'Run codex login in the terminal on the project host. Models are discovered from the CLI; CLI Default uses its configured model.',
                    below: const [
                      SelectableText('codex login\ncodex --version'),
                    ],
                  ),
                  SettingsRow(
                    label: chinese ? '配置与扩展' : 'Configuration and extensions',
                    description: chinese
                        ? 'Codex 读取 ~/.codex/config.toml、AGENTS.md 和 skills。可在终端通过 codex mcp 管理 MCP 服务。'
                        : 'Codex reads ~/.codex/config.toml, AGENTS.md and skills. Use codex mcp in the terminal to manage MCP servers.',
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
