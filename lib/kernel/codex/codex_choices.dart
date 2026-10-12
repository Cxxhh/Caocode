import 'package:flutter/material.dart';

import '../agent_kernel.dart';
import '../kernel_types.dart';

/// Efforts come from the CLI's model catalog and are remembered per model.
class CodexEffort implements ModelSetting {
  CodexEffort(this.model, Map<String, String> settings, this.onChanged) {
    const prefix = 'effort@';
    for (final entry in settings.entries) {
      if (entry.key.startsWith(prefix)) {
        _picked[entry.key.substring(prefix.length)] = entry.value;
      }
    }
    if (settings['effort'] case final value?) {
      _picked.putIfAbsent(model.selected ?? 'default', () => value);
    }
  }

  final LocalChoice model;
  final VoidCallback onChanged;
  final Map<String, List<KernelOption>> _options = {};
  final Map<String, String> _defaults = {};
  final Map<String, String> _picked = {};
  String? _catalogDefault;
  String? _configuredModel;
  String? _configuredEffort;

  String? get resolvedModel => _resolve(model.selected ?? 'default');

  String? _resolve(String id) =>
      id == 'default' ? _configuredModel ?? _catalogDefault : id;

  void configure(Map config) {
    _configuredModel = config['model'] as String?;
    _configuredEffort = config['model_reasoning_effort'] as String?;
  }

  void loadModels(Iterable<Map> models) {
    _options.clear();
    _defaults.clear();
    _catalogDefault = null;
    for (final raw in models) {
      if (raw['model'] case final String id) {
        if (raw['isDefault'] == true) _catalogDefault = id;
        if (raw['defaultReasoningEffort'] case final String value) {
          _defaults[id] = value;
        }
        _options[id] = [
          for (final raw
              in raw['supportedReasoningEfforts'] as List? ?? const [])
            if (raw is Map && raw['reasoningEffort'] is String)
              KernelOption(
                raw['reasoningEffort'] as String,
                switch (raw['reasoningEffort']) {
                  'none' => 'None',
                  'minimal' => 'Minimal',
                  'low' => 'Low',
                  'medium' => 'Medium',
                  'high' => 'High',
                  'xhigh' => 'Extra high',
                  'ultra' => 'Ultra',
                  'max' => 'Maximum',
                  _ => raw['reasoningEffort'] as String,
                },
                Icons.speed_rounded,
                raw['description'] as String? ?? '',
              ),
        ];
      }
    }
  }

  @override
  List<KernelOption> optionsFor(String model) =>
      _options[_resolve(model)] ?? const [];

  @override
  String? get selected => selectedFor(model.selected ?? 'default');

  @override
  String? selectedFor(String model) {
    final options = optionsFor(model);
    for (final value in [
      _picked[model],
      if (model == 'default') _configuredEffort,
      _defaults[_resolve(model)],
    ]) {
      if (value != null && options.any((option) => option.id == value)) {
        return value;
      }
    }
    return options.firstOrNull?.id;
  }

  @override
  void select(String model, String id) {
    if (!optionsFor(model).any((option) => option.id == id)) return;
    _picked[model] = id;
    this.model.select(model);
    onChanged();
  }
}

const codexPermissionOptions = [
  KernelOption(
    'default',
    'Ask for approval',
    Icons.back_hand_outlined,
    'Always ask before editing external files or using the internet',
  ),
  KernelOption(
    'auto',
    'Approve for me',
    Icons.verified_user_outlined,
    'Only ask for actions detected as potentially unsafe',
  ),
  KernelOption(
    'full-access',
    'Full access',
    Icons.shield_outlined,
    'Unrestricted access to the internet and any file on your computer',
    caution: true,
  ),
  KernelOption(
    'custom',
    'Custom (config.toml)',
    Icons.tune_rounded,
    'Uses permissions defined in config.toml',
  ),
];

/// Translate the same permission presets as the Codex extension. Explicitly
/// send the custom policy too: omitted fields keep the previous turn's policy.
Map<String, Object?> codexPermissionParams(
  String? permission,
  List<String> workspaceRoots,
  Map config,
) {
  Map<String, Object?> workspacePolicy([Map? settings]) => {
    'type': 'workspaceWrite',
    'writableRoots': {
      ...workspaceRoots,
      for (final root in settings?['writable_roots'] as List? ?? const [])
        if (root is String) root,
    }.toList(),
    'networkAccess': settings?['network_access'] == true,
    'excludeTmpdirEnvVar': settings?['exclude_tmpdir_env_var'] == true,
    'excludeSlashTmp': settings?['exclude_slash_tmp'] == true,
  };

  if (permission == 'full-access') {
    return {
      'approvalPolicy': 'never',
      'approvalsReviewer': 'user',
      'sandboxPolicy': {'type': 'dangerFullAccess'},
    };
  }
  if (permission == 'custom') {
    return {
      'approvalPolicy': config['approval_policy'] ?? 'on-request',
      'approvalsReviewer': config['approvals_reviewer'] ?? 'user',
      if (config['default_permissions'] case final String profile)
        'permissions': profile
      else
        'sandboxPolicy': switch (config['sandbox_mode']) {
          'danger-full-access' => {'type': 'dangerFullAccess'},
          'workspace-write' => workspacePolicy(
            config['sandbox_workspace_write'] as Map?,
          ),
          _ => {'type': 'readOnly', 'networkAccess': false},
        },
    };
  }
  final reviewConfig =
      permission == 'auto' &&
      (config['approval_policy'] == null ||
          config['approval_policy'] == 'on-request');
  return {
    'approvalPolicy': 'on-request',
    'approvalsReviewer': permission == 'auto' ? 'auto_review' : 'user',
    'sandboxPolicy': reviewConfig && config['sandbox_mode'] == 'read-only'
        ? {'type': 'readOnly', 'networkAccess': false}
        : workspacePolicy(
            reviewConfig && config['sandbox_mode'] == 'workspace-write'
                ? config['sandbox_workspace_write'] as Map?
                : null,
          ),
  };
}
