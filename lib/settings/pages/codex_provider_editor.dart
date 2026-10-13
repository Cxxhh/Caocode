import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_input.dart';
import '../../ide/ide_menu.dart';
import '../../kernel/codex/codex_provider_config.dart';
import '../../kernel/codex/codex_providers.dart';
import '../../l10n/l10n.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

class CodexProviderEditor extends StatefulWidget {
  const CodexProviderEditor({
    super.key,
    required this.provider,
    required this.apiKey,
    required this.onCancel,
    required this.onSave,
    this.busy = false,
    this.error,
  });
  final CodexProvider provider;
  final String apiKey;
  final VoidCallback onCancel;
  final void Function(CodexProvider provider, String key, bool activate) onSave;
  final bool busy;
  final String? error;

  @override
  State<CodexProviderEditor> createState() => _CodexProviderEditorState();
}

class _CodexProviderEditorState extends State<CodexProviderEditor> {
  late final _name = TextEditingController(text: widget.provider.name);
  late final _key = TextEditingController(text: widget.apiKey);
  late final _config = TextEditingController(text: widget.provider.config);
  final _url = TextEditingController();
  final _model = TextEditingController();
  String _effort = '';
  bool _official = false;
  bool _advanced = false;
  bool _showKey = false;
  String? _error;
  String _preset = 'custom';
  bool get _zh => context.l10n.localeName.startsWith('zh');
  String _label(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _takeConfig();
  }

  void _takeConfig() {
    final parsed = CodexProviderConfig(_config.text);
    if (parsed.apiKey != null) _key.text = parsed.apiKey!;
    _official = parsed.builtIn;
    _url.text = parsed.baseUrl ?? '';
    _model.text = parsed.model ?? '';
    _effort = parsed.effort ?? '';
    _preset = parsed.official ? 'official' : 'custom';
  }

  CodexProviderConfig _fromFields() => CodexProviderConfig(_config.text)
      .withFields(
        name: _name.text,
        model: _model.text,
        baseUrl: _url.text,
        effort: _effort,
      );

  void _toggleAdvanced(bool value) {
    try {
      if (value) {
        _config.text = _fromFields().text;
      } else {
        _takeConfig();
      }
      setState(() {
        _advanced = value;
        _error = null;
      });
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  void _choose(CodexProvider preset) => setState(() {
    _name.text = preset.id == 'custom'
        ? _label('自定义供应商', 'Custom provider')
        : preset.name;
    _config.text = preset.config;
    _key.clear();
    _takeConfig();
    _preset = preset.id;
    _advanced = false;
    _error = null;
  });
  void _save(bool activate) {
    try {
      final config = _advanced
          ? CodexProviderConfig(_config.text)
          : _fromFields();
      config.validate();
      if (_name.text.trim().isEmpty) throw const FormatException('请填写供应商名称。');
      setState(() => _error = null);
      widget.onSave(
        CodexProvider(
          id: widget.provider.id,
          name: _name.text.trim(),
          config: config.text,
        ),
        _key.text,
        activate,
      );
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  void dispose() {
    for (final controller in [_name, _key, _config, _url, _model]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? hint,
  }) => SettingsRow(
    label: label,
    below: [
      IdeInputBox(
        controller: controller,
        semanticsLabel: label,
        placeholder: hint,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final preset = CodexProvider.presets.firstWhere((p) => p.id == _preset);
    return SettingsPage(
      title: _label('配置 Codex 供应商', 'Configure Codex provider'),
      description: _label(
        '填写供应商支持的 Responses API 地址和模型。官方账号继续使用 Codex 登录。',
        'Enter the provider’s Responses API endpoint and model. Official accounts use the existing Codex login.',
      ),
      children: [
        SettingsCard(
          children: [
            SettingsRow(
              label: _label('预设', 'Preset'),
              trailing: SettingsDropdown(
                current: preset.name,
                semanticLabel: _label('供应商预设', 'Provider preset'),
                entries: () => [
                  for (final preset in CodexProvider.presets)
                    IdeMenuAction(
                      preset.name,
                      checked: _preset == preset.id,
                      onSelected: () => _choose(preset),
                    ),
                ],
              ),
            ),
            _field(_label('名称', 'Name'), _name),
            if (!_official)
              SettingsRow(
                label: 'API Key',
                description: _label(
                  '使用环境变量或本地服务时可留空。',
                  'Leave empty for an environment variable or a local service.',
                ),
                below: [
                  IdeInputBox(
                    controller: _key,
                    semanticsLabel: 'Codex provider API Key',
                    obscureText: !_showKey,
                  ),
                  IdeButton(
                    label: _showKey
                        ? _label('隐藏密钥', 'Hide key')
                        : _label('显示密钥', 'Show key'),
                    secondary: true,
                    onPressed: () => setState(() => _showKey = !_showKey),
                  ),
                ],
              ),
            if (!_advanced) ...[
              if (!_official)
                _field(
                  _label('API 地址', 'API endpoint'),
                  _url,
                  hint: 'https://api.example.com/v1',
                ),
              _field(
                _label('模型 ID', 'Model ID'),
                _model,
                hint: _official
                    ? _label('留空使用 CLI 默认模型', 'Leave empty for the CLI default')
                    : null,
              ),
              SettingsRow(
                label: _label('推理强度', 'Reasoning effort'),
                trailing: SettingsDropdown(
                  current: _effort.isEmpty
                      ? _label('CLI 默认', 'CLI default')
                      : _effort,
                  semanticLabel: 'Codex provider reasoning effort',
                  entries: () => [
                    for (final effort in [
                      '',
                      'none',
                      'minimal',
                      'low',
                      'medium',
                      'high',
                      'xhigh',
                    ])
                      IdeMenuAction(
                        effort.isEmpty
                            ? _label('CLI 默认', 'CLI default')
                            : effort,
                        checked: _effort == effort,
                        onSelected: () => setState(() => _effort = effort),
                      ),
                  ],
                ),
              ),
            ],
            SettingsRow(
              label: _label('编辑 TOML 配置片段', 'Edit TOML fragment'),
              description: _label(
                '配置片段保存供应商参数。MCP、项目和其他全局设置请通过“打开 config.toml”编辑。',
                'The fragment stores provider options. Edit MCP, projects and other global settings through Open config.toml.',
              ),
              trailing: SettingsSwitch(
                value: _advanced,
                semanticLabel: 'Codex provider advanced TOML',
                onChanged: _toggleAdvanced,
              ),
              below: _advanced
                  ? [
                      IdeInputBox(
                        controller: _config,
                        semanticsLabel: 'Codex provider TOML',
                        minLines: 10,
                        maxLines: 22,
                      ),
                    ]
                  : [],
            ),
          ],
        ),
        if (_error ?? widget.error case final error?)
          SelectableText(
            error,
            style: SettingsText.description.copyWith(color: Colors.redAccent),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            IdeButton(
              label: _label('保存', 'Save'),
              onPressed: widget.busy ? null : () => _save(false),
            ),
            IdeButton(
              label: _label('保存并启用', 'Save and activate'),
              onPressed: widget.busy ? null : () => _save(true),
            ),
            IdeButton(
              label: context.l10n.commonCancel,
              secondary: true,
              onPressed: widget.busy ? null : widget.onCancel,
            ),
          ],
        ),
      ],
    );
  }
}
