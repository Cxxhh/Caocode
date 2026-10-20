import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_dialog.dart';
import '../../kernel/codex/cc_switch_providers.dart';
import '../../kernel/codex/codex_config_file.dart';
import '../../kernel/codex/codex_config_setting.dart';
import '../../kernel/codex/codex_environment.dart';
import '../../kernel/codex/codex_host_settings.dart';
import '../../kernel/codex/codex_path_setting.dart';
import '../../kernel/codex/codex_provider_config.dart';
import '../../kernel/codex/codex_providers.dart';
import '../../l10n/l10n.dart';
import '../user_settings.dart';
import '../../workspace/codex_environment_picker.dart';
import 'codex_provider_editor.dart';
import 'settings_widgets.dart';

/// Settings → Models: the CLI, its user configuration, and saved providers.
class CodexSettingsPage extends StatefulWidget {
  const CodexSettingsPage({
    super.key,
    this.settings,
    this.cwd,
    this.onOpenFile,
    this.providers,
    this.resolveConfig,
    this.readCcSwitch,
  });
  final UserSettings? settings;
  final String? cwd;
  final FutureOr<void> Function(String)? onOpenFile;
  final CodexProviders? providers;
  final Future<CodexConfigFile> Function(String? configPath)? resolveConfig;
  final Future<CcSwitchSnapshot> Function(String? path)? readCcSwitch;

  @override
  State<CodexSettingsPage> createState() => _CodexSettingsPageState();
}

class _CodexSettingsPageState extends State<CodexSettingsPage> {
  late final _providers =
      widget.providers ??
      (widget.settings == null
          ? CodexProviders.memory()
          : CodexProviders.settings(widget.settings!));
  CodexConfigFile? _file;
  String? _source;
  String? _active;
  String? _error;
  String? _notice;
  bool _busy = false;
  CodexProvider? _editing;
  String _editingKey = '';
  CcSwitchSnapshot? _ccSwitch;
  String? _ccSwitchError;
  late String? _ccSwitchPath =
      widget.settings?[CcSwitchSnapshot.pathSettingKey] as String?;
  late String _ccSwitchDraft = _ccSwitchPath ?? '';
  Future<void> _actions = Future<void>.value();

  bool get _zh => context.l10n.localeName.startsWith('zh');
  String _label(String zh, String en) => _zh ? zh : en;
  String? get _cwd => CodexEnvironmentController.instance.supported
      ? CodexEnvironmentController.instance.selected.settingsLocation(
          widget.cwd,
        )
      : widget.cwd;
  String _key(String base) => CodexHostSettings.key(base, _cwd);
  String? _value(String base) => CodexHostSettings.value(
    base,
    _cwd,
    CodexConfigSetting.parse(widget.settings?[base]),
    readSetting: (key) => widget.settings?[key],
  );
  String? get _configPath => _value(CodexConfigSetting.settingKey);

  @override
  void initState() {
    super.initState();
    _providers.addListener(_changed);
    widget.settings?.addListener(_changed);
    CodexEnvironmentController.instance.addListener(_environmentChanged);
    if (widget.settings != null || widget.resolveConfig != null) {
      unawaited(_run(_reloadAll));
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _environmentChanged() {
    if (mounted) unawaited(_run(_reloadAll));
  }

  @override
  void dispose() {
    widget.settings?.removeListener(_changed);
    CodexEnvironmentController.instance.removeListener(_environmentChanged);
    _providers.removeListener(_changed);
    if (widget.providers == null) _providers.dispose();
    super.dispose();
  }

  /// A field losing focus just before Open must finish saving its path first.
  Future<void> _run(Future<void> Function() action) {
    _actions = _actions.then((_) async {
      if (!mounted) return;
      setState(() {
        _busy = true;
        _error = null;
        _notice = null;
      });
      try {
        await action();
      } catch (error) {
        if (mounted) setState(() => _error = '$error');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    });
    return _actions;
  }

  Future<CodexConfigFile> _resolve() =>
      widget.resolveConfig?.call(_configPath) ??
      CodexConfigFile.resolve(cwd: _cwd, configPath: _configPath);

  List<CodexProvider> get _allProviders => [
    ..._providers.providers,
    for (final entry in _ccSwitch?.providers ?? const <CcSwitchProvider>[])
      entry.provider,
  ];

  Future<String?> _keyFor(String id) async {
    final linked = _ccSwitch?.providers
        .where((entry) => entry.provider.id == id)
        .firstOrNull;
    return linked == null ? _providers.key(id) : linked.apiKey;
  }

  Future<CcSwitchSnapshot> _readCcSwitch(String? path) =>
      (widget.readCcSwitch ?? CcSwitchSnapshot.read)(path);

  Future<void> _reloadAll() async {
    if (_ccSwitchPath != null) await _refreshCcSwitch();
    await _reload();
  }

  Future<void> _connectCcSwitch() async {
    final snapshot = await _readCcSwitch(_ccSwitchDraft);
    await widget.settings?.update(
      CcSwitchSnapshot.pathSettingKey,
      snapshot.path,
    );
    _ccSwitchPath = snapshot.path;
    _ccSwitchDraft = snapshot.path;
    _ccSwitch = snapshot;
    _ccSwitchError = null;
    await _reload();
    _notice = _label(
      '已连接 CCS，读取 ${snapshot.providers.length} 个 Codex 供应商。',
      'Connected to CCS: ${snapshot.providers.length} Codex providers.',
    );
  }

  Future<void> _refreshCcSwitch() async {
    _ccSwitch = null;
    _ccSwitchError = null;
    try {
      _ccSwitch = await _readCcSwitch(_ccSwitchPath);
    } catch (error) {
      _ccSwitchError = '$error';
    }
  }

  Future<void> _disconnectCcSwitch() async {
    await widget.settings?.update(CcSwitchSnapshot.pathSettingKey, null);
    _ccSwitch = null;
    _ccSwitchPath = null;
    _ccSwitchDraft = '';
    _ccSwitchError = null;
    await _reload();
    _notice = _label(
      '已断开 CCS；当前 Codex 配置保持不变。',
      'Disconnected from CCS. The active Codex configuration is unchanged.',
    );
  }

  Future<void> _reload() async {
    _file = null;
    _source = null;
    _active = null;
    final file = await _resolve();
    _file = file;
    final source = await file.read();
    CodexProviderConfig.decode(source);
    _source = source;
    _active = (await _findActive(file, source))?.id;
    if (mounted) setState(() {});
  }

  Future<CodexProvider?> _findActive(
    CodexConfigFile file,
    String source,
  ) async {
    final preferred = _providers.active(file.path);
    final list = [
      ..._allProviders.where((p) => p.id == preferred),
      ..._allProviders.where((p) => p.id != preferred),
    ];
    for (final provider in list) {
      if (!provider.parsed.matches(source, checkKey: false)) continue;
      if (provider.parsed.matches(source, apiKey: await _keyFor(provider.id))) {
        return provider;
      }
    }
    return null;
  }

  Future<void> _openConfig() async {
    final open = widget.onOpenFile;
    if (open == null) return;
    final file = await _resolve();
    await file.ensureExists();
    await open(file.path);
  }

  Future<void> _edit(CodexProvider provider, {bool duplicate = false}) async {
    final key = await _keyFor(provider.id) ?? '';
    if (!mounted) return;
    setState(() {
      _editingKey = key;
      _editing = duplicate
          ? CodexProvider(
              id: _providers.newId(),
              name: '${provider.name} (${_label('副本', 'copy')})',
              config: provider.config,
            )
          : provider;
    });
  }

  void _add() => setState(() {
    _editing = CodexProvider(
      id: _providers.newId(),
      name: _label('自定义供应商', 'Custom provider'),
      config: CodexProvider.presets.last.config,
    );
    _editingKey = '';
    _notice = null;
    _error = null;
  });
  Future<void> _import() async {
    final file = await _resolve();
    final config = CodexProviderConfig(await file.read());
    final name =
        config.table['name'] as String? ??
        (config.official ? 'OpenAI / ChatGPT' : config.providerId);
    final key = await file.importKey() ?? '';
    if (!mounted) return;
    setState(() {
      _editing = CodexProvider(
        id: _providers.newId(),
        name: name,
        config: config.projected().text,
      );
      _editingKey = key;
    });
  }

  Future<void> _activate(CodexProvider provider) async {
    final file = await _resolve();
    final outgoing = await _findActive(file, await file.read());
    await file.activate(
      provider.parsed,
      apiKey: await _keyFor(provider.id),
      outgoing: outgoing?.parsed,
    );
    await _providers.setActive(file.path, provider.id);
    await _reload();
    _notice = _label(
      '已启用 ${provider.name}。新会话生效；现有会话请重启。',
      '${provider.name} is active. Start a new session or restart an existing one.',
    );
  }

  CodexProvider? get _activeProvider =>
      _allProviders.where((provider) => provider.id == _active).firstOrNull;

  Future<void> _save(CodexProvider provider, String key, bool activate) async {
    final file = await _resolve();
    final previous = await _findActive(file, await file.read());
    final wasActive = previous?.id == provider.id;
    final old = _providers.providers
        .where((p) => p.id == provider.id)
        .firstOrNull;
    final oldKey = old == null ? '' : await _providers.key(old.id) ?? '';
    final saved = await _providers.save(provider, apiKey: key);
    if (activate || wasActive) {
      try {
        await file.activate(
          saved.parsed,
          apiKey: await _providers.key(saved.id),
          outgoing: previous?.parsed,
        );
      } catch (_) {
        if (old == null) {
          await _providers.remove(saved.id);
        } else {
          await _providers.save(old, apiKey: oldKey);
        }
        rethrow;
      }
      await _providers.setActive(file.path, saved.id);
    }
    if (mounted) setState(() => _editing = null);
    await _reload();
    _notice = activate || wasActive
        ? _label(
            '已保存并启用 ${saved.name}。新会话生效；现有会话请重启。',
            '${saved.name} saved and activated. Start a new session or restart the current one.',
          )
        : _label('供应商已保存。', 'Provider saved.');
  }

  Future<void> _remove(CodexProvider provider) async {
    final answer = await showIdeDialog(
      context,
      message: _label('删除供应商 ${provider.name}？', 'Delete ${provider.name}?'),
      detail: _label(
        '将删除保存的配置和密钥。',
        'The saved configuration and key will be removed.',
      ),
      buttons: [_label('删除', 'Delete'), context.l10n.commonCancel],
    );
    if (answer != 0) return;
    await _providers.remove(provider.id);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_editing case final provider?) {
      return CodexProviderEditor(
        key: ValueKey(provider.id),
        provider: provider,
        apiKey: _editingKey,
        busy: _busy,
        error: _error,
        onCancel: () => setState(() {
          _editing = null;
          _error = null;
        }),
        onSave: (provider, key, activate) =>
            unawaited(_run(() => _save(provider, key, activate))),
      );
    }
    final parsed = _source == null ? null : CodexProviderConfig(_source!);
    final executableKey = _key(CodexPathSetting.settingKey);
    final configKey = _key(CodexConfigSetting.settingKey);
    final configCwd = _cwd;
    return SettingsPage(
      title: context.l10n.settingsSectionModels,
      description: _label(
        '管理 Codex CLI、配置文件与模型供应商。',
        'Manage the Codex CLI, its configuration file and model providers.',
      ),
      children: [
        SettingsGroup(
          title: 'Codex CLI',
          children: [
            SettingsCard(
              children: [
                if (CodexEnvironmentController.instance.supported)
                  SettingsRow(
                    label: _label('运行环境', 'Execution environment'),
                    description: _label(
                      '分别管理 Windows 和 WSL2 的 CLI 与配置；打开项目时进入所选环境的目录。',
                      'Manage Windows and WSL2 independently. Open Project starts in the selected environment.',
                    ),
                    trailing: const CodexEnvironmentPicker(),
                  ),
                SettingsRow(
                  label: _label('可执行文件路径', 'Executable path'),
                  description: _label(
                    '留空时从 PATH 查找。WSL 工程使用对应发行版的 Linux Codex。修改后重启会话生效。',
                    'Leave empty to search PATH. WSL projects use Linux Codex in that distribution. Restart the session after changes.',
                  ),
                  trailing: SettingsTextField(
                    key: ValueKey(executableKey),
                    value: _value(CodexPathSetting.settingKey) ?? '',
                    hint: 'codex',
                    semanticLabel: 'Codex CLI path',
                    width: 260,
                    onSubmitted: (value) => unawaited(
                      _run(() async {
                        await widget.settings?.update(
                          executableKey,
                          CodexPathSetting.parse(value) ?? '',
                        );
                      }),
                    ),
                  ),
                ),
                SettingsRow(
                  label: _label('自定义 config.toml', 'Custom config.toml'),
                  description: _label(
                    '留空使用所选环境的默认配置。自定义文件名须为 config.toml，其目录也用于 Codex 登录与会话存储。',
                    'Leave empty for the selected environment’s default. The file must be named config.toml; its directory also stores Codex login and sessions.',
                  ),
                  below: [
                    LayoutBuilder(
                      builder: (context, constraints) => SettingsTextField(
                        key: ValueKey(configKey),
                        value: _configPath ?? '',
                        hint: '~/.codex/config.toml',
                        width: constraints.maxWidth.clamp(0, 360),
                        semanticLabel: 'Codex config.toml path',
                        onSubmitted: (value) => unawaited(
                          _run(() async {
                            final path = CodexConfigSetting.parse(value);
                            await (widget.resolveConfig?.call(path) ??
                                CodexConfigFile.resolve(
                                  cwd: configCwd,
                                  configPath: path,
                                ));
                            await widget.settings?.update(
                              configKey,
                              path ?? '',
                            );
                            await _reload();
                          }),
                        ),
                      ),
                    ),
                    if (_file != null)
                      SelectableText(
                        '${_file!.hostLabel} · ${_file!.path}',
                        style: SettingsText.path,
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        IdeButton(
                          label: _label('打开 config.toml', 'Open config.toml'),
                          onPressed: _busy || widget.onOpenFile == null
                              ? null
                              : () => unawaited(_run(_openConfig)),
                        ),
                        IdeButton(
                          label: _label('刷新配置', 'Refresh configuration'),
                          secondary: true,
                          onPressed: _busy
                              ? null
                              : () => unawaited(_run(_reloadAll)),
                        ),
                      ],
                    ),
                  ],
                ),
                SettingsRow(
                  label: _label('登录与模型', 'Sign in and models'),
                  description: _label(
                    '官方账号可在工程所在系统的终端运行 codex login。模型选择器读取 CLI 模型列表；“CLI 默认”使用当前配置。',
                    'Run codex login on the project host for an official account. The model picker reads the CLI catalog; CLI Default uses the current configuration.',
                  ),
                  below: [
                    SelectableText(
                      'codex login\ncodex --version',
                      style: SettingsText.path,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        SettingsGroup(
          title: _label('Codex 供应商', 'Codex providers'),
          description: _label(
            '保存多套 Responses 供应商配置并切换。API Key 保存在系统密钥存储中，启用时写入 config.toml；全局设置保留，切换前自动备份。',
            'Save and switch Responses providers. Keys use the system secret store and are written to config.toml on activation. Global settings are retained; switching creates a backup.',
          ),
          children: [
            SettingsCard(
              children: [
                SettingsRow(
                  label: _label('当前配置', 'Current configuration'),
                  description: parsed == null
                      ? _label('尚未读取配置。', 'Configuration has not been loaded.')
                      : '${_activeProvider?.name ?? parsed.providerId}${parsed.model == null ? '' : ' · ${parsed.model}'}',
                  below: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        IdeButton(
                          label: _label('添加供应商', 'Add provider'),
                          onPressed: _busy ? null : _add,
                        ),
                        IdeButton(
                          label: _label(
                            '导入当前配置',
                            'Import current configuration',
                          ),
                          secondary: true,
                          onPressed: _busy || _source == null
                              ? null
                              : () => unawaited(_run(_import)),
                        ),
                        IdeButton(
                          label: _label('使用 OpenAI 官方', 'Use OpenAI official'),
                          secondary: true,
                          onPressed: _busy || _source == null
                              ? null
                              : () => unawaited(
                                  _run(
                                    () =>
                                        _activate(CodexProvider.presets.first),
                                  ),
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
                for (final provider in _providers.providers)
                  SettingsRow(
                    label:
                        '${provider.name}${provider.id == _active ? _label(' · 已启用', ' · Active') : ''}',
                    description:
                        '${provider.parsed.baseUrl ?? provider.parsed.providerId}'
                        '${provider.parsed.model == null ? '' : ' · ${provider.parsed.model}'}',
                    below: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          IdeButton(
                            label: provider.id == _active
                                ? _label('已启用', 'Active')
                                : _label('启用', 'Activate'),
                            onPressed:
                                _busy ||
                                    _source == null ||
                                    provider.id == _active
                                ? null
                                : () => unawaited(
                                    _run(() => _activate(provider)),
                                  ),
                          ),
                          IdeButton(
                            label: _label('编辑', 'Edit'),
                            secondary: true,
                            onPressed: _busy
                                ? null
                                : () => unawaited(_run(() => _edit(provider))),
                          ),
                          IdeButton(
                            label: _label('复制', 'Duplicate'),
                            secondary: true,
                            onPressed: _busy
                                ? null
                                : () => unawaited(
                                    _run(
                                      () => _edit(provider, duplicate: true),
                                    ),
                                  ),
                          ),
                          IdeButton(
                            label: _label('删除', 'Delete'),
                            secondary: true,
                            onPressed: _busy || provider.id == _active
                                ? null
                                : () =>
                                      unawaited(_run(() => _remove(provider))),
                          ),
                        ],
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
        _ccSwitchGroup(),
        if (_busy)
          Text(_label('正在处理…', 'Working…'), style: SettingsText.description),
        if (_error != null)
          SelectableText(
            _error!,
            style: SettingsText.description.copyWith(color: Colors.redAccent),
          ),
        if (_notice != null) Text(_notice!, style: SettingsText.description),
      ],
    );
  }

  Widget _ccSwitchGroup() => SettingsGroup(
    title: _label(
      '第三方供应商 · CC Switch (CCS)',
      'Third-party providers · CC Switch (CCS)',
    ),
    description: _label(
      '连接 CCS 数据库后，在 CCS 添加、修改或删除供应商，再刷新此列表即可。连接的数据与密钥不另存本地副本；也可按需导入。',
      'Manage providers in CCS, then refresh this list. Linked providers and keys are not copied into local settings. Import a local copy if needed.',
    ),
    children: [
      SettingsCard(
        children: [
          SettingsRow(
            label: _label('CCS 数据库路径', 'CCS database path'),
            description: _label(
              '留空连接当前应用所在系统的 ~/.cc-switch/cc-switch.db。可填写其他数据库的绝对路径。',
              'Leave empty for ~/.cc-switch/cc-switch.db on the app host, or enter an absolute database path.',
            ),
            below: [
              LayoutBuilder(
                builder: (context, constraints) => SettingsTextField(
                  value: _ccSwitchDraft,
                  hint: '~/.cc-switch/cc-switch.db',
                  semanticLabel: 'CCS database path',
                  width: constraints.maxWidth.clamp(0, 420),
                  onSubmitted: (value) => _ccSwitchDraft = value.trim(),
                  onChanged: (value) => _ccSwitchDraft = value.trim(),
                ),
              ),
              if (_ccSwitchPath != null)
                SelectableText(_ccSwitchPath!, style: SettingsText.path),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  IdeButton(
                    label: _label('连接 CCS', 'Connect CCS'),
                    onPressed: _busy
                        ? null
                        : () => unawaited(_run(_connectCcSwitch)),
                  ),
                  if (_ccSwitchPath != null) ...[
                    IdeButton(
                      label: _label('刷新 CCS', 'Refresh CCS'),
                      secondary: true,
                      onPressed: _busy
                          ? null
                          : () => unawaited(_run(_reloadAll)),
                    ),
                    IdeButton(
                      label: _label('断开连接', 'Disconnect'),
                      secondary: true,
                      onPressed: _busy
                          ? null
                          : () => unawaited(_run(_disconnectCcSwitch)),
                    ),
                  ],
                ],
              ),
              if (_ccSwitchError != null)
                SelectableText(
                  _ccSwitchError!,
                  style: SettingsText.description.copyWith(
                    color: Colors.redAccent,
                  ),
                ),
              for (final warning in _ccSwitch?.warnings ?? const <String>[])
                Text(warning, style: SettingsText.description),
              if (_ccSwitch != null && _ccSwitch!.providers.isEmpty)
                Text(
                  _label(
                    'CCS 中没有可直连的 Codex 供应商。',
                    'No compatible Codex providers in CCS.',
                  ),
                  style: SettingsText.description,
                ),
            ],
          ),
          for (final entry
              in _ccSwitch?.providers ?? const <CcSwitchProvider>[])
            SettingsRow(
              label:
                  '${entry.provider.name}${entry.provider.id == _active ? _label(' · 已启用', ' · Active') : ''}',
              description:
                  '${entry.provider.parsed.baseUrl ?? entry.provider.parsed.providerId}'
                  '${entry.current ? _label(' · CCS 当前选择', ' · Selected in CCS') : ''}',
              below: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    IdeButton(
                      label: entry.provider.id == _active
                          ? _label('已启用', 'Active')
                          : _label('启用', 'Activate'),
                      onPressed:
                          _busy ||
                              _source == null ||
                              entry.provider.id == _active
                          ? null
                          : () => unawaited(
                              _run(() => _activate(entry.provider)),
                            ),
                    ),
                    IdeButton(
                      label: _label('导入为本地副本', 'Import local copy'),
                      secondary: true,
                      onPressed: _busy
                          ? null
                          : () => unawaited(
                              _run(
                                () => _edit(entry.provider, duplicate: true),
                              ),
                            ),
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    ],
  );
}
