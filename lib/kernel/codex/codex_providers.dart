import 'package:flutter/foundation.dart';

import '../../models/secret_store.dart';
import '../../settings/user_settings.dart';
import 'codex_provider_config.dart';

class CodexProvider {
  const CodexProvider({
    required this.id,
    required this.name,
    required this.config,
  });
  final String id;
  final String name;
  final String config;
  CodexProviderConfig get parsed => CodexProviderConfig(config);
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'config': config};

  static CodexProvider? fromJson(Object? value) => switch (value) {
    {
      'id': final String id,
      'name': final String name,
      'config': final String config,
    }
        when id.isNotEmpty && name.isNotEmpty =>
      CodexProvider(id: id, name: name, config: config),
    _ => null,
  };

  static final presets = [
    CodexProvider(
      id: 'official',
      name: 'OpenAI / ChatGPT',
      config: 'model_provider = "openai"\n',
    ),
    CodexProvider(
      id: 'openai-api',
      name: 'OpenAI API',
      config:
          'model_provider = "custom"\n\n[model_providers.custom]\n'
          'name = "OpenAI API"\nbase_url = "https://api.openai.com/v1"\n'
          'wire_api = "responses"\nrequires_openai_auth = false\n',
    ),
    for (final (id, name, url) in const [
      ('kimi', 'Kimi', 'https://api.moonshot.cn/v1'),
      ('kimi-code', 'Kimi For Coding', 'https://api.kimi.com/coding/v1'),
      ('deepseek', 'DeepSeek', 'https://api.deepseek.com'),
      ('glm', '智谱 GLM', 'https://open.bigmodel.cn/api/v1'),
      ('minimax', 'MiniMax', 'https://api.minimax.cn/v1'),
      ('xai', 'xAI (Grok)', 'https://api.x.ai/v1'),
      ('openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1'),
    ])
      CodexProvider(
        id: id,
        name: name,
        config:
            'model_provider = "custom"\n\n[model_providers.custom]\n'
            'name = "$name"\nbase_url = "$url"\n'
            'wire_api = "responses"\nrequires_openai_auth = false\n',
      ),
    CodexProvider(
      id: 'custom',
      name: '自定义 Responses',
      config:
          'model_provider = "custom"\n\n[model_providers.custom]\n'
          'name = "custom"\nbase_url = ""\nwire_api = "responses"\nrequires_openai_auth = false\n',
    ),
  ];
}

/// Saved provider fragments in settings.json; API keys in the existing OS
/// secret store. Activating one materializes the key in Codex's config.toml,
/// as CC Switch does, without modifying the official auth.json login.
class CodexProviders extends ChangeNotifier {
  CodexProviders({
    required this.read,
    required this.write,
    this.changes,
    SecretStore? secrets,
  }) : secrets = secrets ?? SecretStore.instance {
    changes?.addListener(notifyListeners);
  }
  factory CodexProviders.settings(
    UserSettings settings, {
    SecretStore? secrets,
  }) => CodexProviders(
    read: (key) => settings[key],
    write: settings.update,
    changes: settings,
    secrets: secrets,
  );
  factory CodexProviders.memory({SecretStore? secrets}) {
    final values = <String, Object?>{};
    return CodexProviders(
      read: (key) => values[key],
      write: (key, value) async => values[key] = value,
      secrets: secrets ?? MemorySecretStore(),
    );
  }

  static const providersKey = 'codexCli.providers';
  static const activeKey = 'codexCli.activeProviders';
  final Object? Function(String) read;
  final Future<void> Function(String, Object?) write;
  final Listenable? changes;
  final SecretStore secrets;
  List<CodexProvider> get providers => [
    for (final value in read(providersKey) as List? ?? const [])
      ?CodexProvider.fromJson(value),
  ];
  String newId() => 'codex-${DateTime.now().microsecondsSinceEpoch}';
  String _keyRef(String id) => 'caocode.codex.provider.$id';
  Future<String?> key(String id) => secrets.read(_keyRef(id));
  String? active(String path) => switch (read(activeKey)) {
    final Map active => active[path] as String?,
    _ => null,
  };
  Future<void> setActive(String path, String? id) async {
    final active = <String, Object?>{
      ...?read(activeKey) as Map<String, Object?>?,
    };
    if (id == null) {
      active.remove(path);
    } else {
      active[path] = id;
    }
    await write(activeKey, active);
    notifyListeners();
  }

  Future<CodexProvider> save(
    CodexProvider provider, {
    required String apiKey,
  }) async {
    final parsed = provider.parsed;
    parsed.validate();
    if (provider.name.trim().isEmpty) throw const FormatException('请填写供应商名称。');
    final sanitized = CodexProvider(
      id: provider.id,
      name: provider.name.trim(),
      config: parsed.projected().text,
    );
    final ref = _keyRef(provider.id);
    final previous = await secrets.read(ref);
    final key = apiKey.trim().isEmpty
        ? parsed.apiKey?.trim() ?? ''
        : apiKey.trim();
    if (key.isEmpty) {
      await secrets.delete(ref);
    } else {
      await secrets.write(ref, key);
    }
    try {
      await write(providersKey, [
        for (final item in providers)
          if (item.id != provider.id) item.toJson(),
        sanitized.toJson(),
      ]);
    } catch (_) {
      if (previous == null) {
        await secrets.delete(ref);
      } else {
        await secrets.write(ref, previous);
      }
      rethrow;
    }
    notifyListeners();
    return sanitized;
  }

  Future<void> remove(String id) async {
    await write(providersKey, [
      for (final item in providers)
        if (item.id != id) item.toJson(),
    ]);
    await secrets.delete(_keyRef(id));
    notifyListeners();
  }

  @override
  void dispose() {
    changes?.removeListener(notifyListeners);
    super.dispose();
  }
}
