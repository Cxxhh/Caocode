import 'package:collection/collection.dart';
import 'package:toml/toml.dart';

/// Provider switching follows CC Switch's Codex projection: connection and
/// model fields belong to a provider, while the rest of config.toml is global.
/// See docs/codex-providers.md for the reference revision and license.
class CodexProviderConfig {
  CodexProviderConfig(String text) : values = decode(text);
  CodexProviderConfig._(this.values);

  final Map<String, dynamic> values;
  static const routeId = 'custom';
  static const builtInIds = {
    'openai',
    'ollama',
    'lmstudio',
    'amazon-bedrock',
    'amazon-bedrock-runtime',
  };
  static const connectionFields = {
    'model_provider',
    'openai_base_url',
    'model',
    'review_model',
    'model_reasoning_effort',
    'plan_mode_reasoning_effort',
    'disable_response_storage',
    'model_catalog_json',
    'experimental_bearer_token',
    'base_url',
    'wire_api',
  };
  static const compatibilityFields = {
    'web_search',
    'model_context_window',
    'model_auto_compact_token_limit',
    'model_supports_reasoning_summaries',
    'model_verbosity',
  };
  static const nestedConnectionFields = {
    'agents': {'default_subagent_model', 'default_subagent_reasoning_effort'},
    'memories': {'extract_model', 'consolidation_model'},
  };

  static Map<String, dynamic> decode(String text) {
    late final Map<String, dynamic> values;
    try {
      values = TomlDocument.parse(text).toMap();
    } catch (_) {
      // Parser diagnostics can contain the source, including credentials.
      throw const FormatException('config.toml 不是有效的 TOML，请检查配置格式。');
    }
    void check(Map values) {
      for (final key in [
        'model_provider',
        'model',
        'review_model',
        'model_reasoning_effort',
        'plan_mode_reasoning_effort',
        'profile',
        'openai_base_url',
        'base_url',
        'wire_api',
        'experimental_bearer_token',
      ]) {
        if (values.containsKey(key) && values[key] is! String) {
          throw FormatException('config.toml 中的 $key 必须为字符串。');
        }
      }
      final providers = values['model_providers'];
      if (providers != null && providers is! Map) {
        throw const FormatException(
          'config.toml 中的 model_providers 必须为 TOML 表。',
        );
      }
      if (providers is Map) {
        for (final table in providers.values) {
          if (table is! Map) {
            throw const FormatException('model_providers 中的每个供应商必须为 TOML 表。');
          }
          for (final key in [
            'name',
            'base_url',
            'env_key',
            'experimental_bearer_token',
            'wire_api',
          ]) {
            if (table.containsKey(key) && table[key] is! String) {
              throw FormatException('供应商配置中的 $key 必须为字符串。');
            }
          }
        }
      }
    }

    check(values);
    final profiles = values['profiles'];
    if (profiles is Map && profiles[values['profile']] is Map) {
      check(profiles[values['profile']] as Map);
    }
    return values;
  }

  Map<String, dynamic> get effective {
    final profiles = values['profiles'];
    final profile = profiles is Map ? profiles[values['profile']] : null;
    Map<String, dynamic> merge(Map base, Map override) => {
      for (final key in {...base.keys, ...override.keys})
        key as String: base[key] is Map && override[key] is Map
            ? merge(base[key] as Map, override[key] as Map)
            : override.containsKey(key)
            ? override[key]
            : base[key],
    };
    return profile is Map ? merge(values, profile) : values;
  }

  String get providerId => effective['model_provider'] as String? ?? 'openai';
  Map<String, dynamic> get table {
    final tables = effective['model_providers'];
    final selected = tables is Map ? tables[providerId] : null;
    return selected is Map ? Map<String, dynamic>.from(selected) : {};
  }

  String? get baseUrl =>
      table['base_url'] as String? ??
      effective['openai_base_url'] as String? ??
      effective['base_url'] as String?;
  String? get model => effective['model'] as String?;
  String? get effort => effective['model_reasoning_effort'] as String?;
  String? get apiKey =>
      table['experimental_bearer_token'] as String? ??
      effective['experimental_bearer_token'] as String?;
  bool get official => providerId == 'openai' && baseUrl == null;
  bool get builtIn => builtInIds.contains(providerId) && baseUrl == null;

  /// A portable provider fragment; never imports MCP, projects or plugins.
  CodexProviderConfig projected({String? apiKey, bool includeKey = false}) {
    final projected = <String, dynamic>{
      for (final key in {...connectionFields, ...compatibilityFields})
        if (effective.containsKey(key)) key: effective[key],
    };
    for (final key in const [
      'openai_base_url',
      'base_url',
      'wire_api',
      'experimental_bearer_token',
    ]) {
      projected.remove(key);
    }
    projected['model_provider'] = builtIn ? providerId : routeId;
    if (!builtIn) {
      final selected = table;
      selected.remove('experimental_bearer_token');
      if (baseUrl != null) selected['base_url'] = baseUrl;
      selected['wire_api'] = 'responses';
      // A third-party endpoint must authenticate through its own credentials.
      if (selected.containsKey('auth')) {
        selected.remove('requires_openai_auth');
      } else {
        selected['requires_openai_auth'] = false;
      }
      final key = apiKey ?? (includeKey ? this.apiKey : null);
      if (key != null && key.isNotEmpty) {
        for (final auth in ['env_key', 'env_key_instructions', 'auth']) {
          selected.remove(auth);
        }
        selected['experimental_bearer_token'] = key;
        selected['requires_openai_auth'] = false;
      }
      projected['model_providers'] = {routeId: selected};
    }
    return CodexProviderConfig._(projected);
  }

  String get text => TomlDocument.fromMap(values).toString();

  void validate() {
    final selected = values['model_providers'];
    if (selected != null && selected is! Map) {
      throw const FormatException('model_providers 必须为 TOML 表。');
    }
    if (selected is Map && selected.keys.any((key) => key != providerId)) {
      throw const FormatException('配置片段只能包含当前供应商的 model_providers 表。');
    }
    for (final key in values.keys) {
      if (!connectionFields.contains(key) &&
          !compatibilityFields.contains(key) &&
          key != 'model_providers') {
        throw FormatException('“$key” 是全局设置，请通过 Fast IDE 编辑完整 config.toml。');
      }
    }
    if (!builtIn) {
      final url = Uri.tryParse(baseUrl ?? '');
      if (url == null ||
          !{'http', 'https'}.contains(url.scheme) ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          url.fragment.isNotEmpty) {
        throw const FormatException('请填写有效的 HTTP 或 HTTPS API 地址。');
      }
      if (model == null || model!.trim().isEmpty) {
        throw const FormatException('请填写供应商的模型 ID。');
      }
      final wire = table['wire_api'] ?? values['wire_api'];
      if (wire != null && wire != 'responses') {
        throw const FormatException('Codex 直连供应商需要 Responses API。');
      }
    }
  }

  /// Replaces only provider-owned expressions, retaining untouched source
  /// byte for byte, including multiline strings, comments and quoted keys.
  String applyTo(
    String source, {
    String? apiKey,
    CodexProviderConfig? outgoing,
  }) {
    final live = decode(source);
    final profile = live['profile'] as String?;
    final target = projected(apiKey: apiKey);
    final remove = {...connectionFields};
    for (final key in compatibilityFields) {
      if (target.values.containsKey(key) ||
          (outgoing?.values.containsKey(key) == true &&
              const DeepCollectionEquality().equals(
                live[key],
                outgoing!.values[key],
              ))) {
        remove.add(key);
      }
    }
    final newline = source.contains('\r\n') ? '\r\n' : '\n';
    final kept = StringBuffer();
    var context = <String>[];
    var offset = 0;
    var insertedInline = false;
    final targetTable = target.values['model_providers']?[routeId];
    List<String> relative(List<String> path) =>
        profile != null &&
            path.length >= 3 &&
            path[0] == 'profiles' &&
            path[1] == profile
        ? path.sublist(2)
        : path;
    bool managed(List<String> path) {
      final route = relative(path);
      return route.length >= 2 &&
          route[0] == 'model_providers' &&
          route[1] == routeId;
    }

    dynamic at(List<String> path) {
      dynamic value = live;
      for (final key in path) {
        value = value is Map ? value[key] : null;
      }
      return value;
    }

    Map<String, dynamic> stripProfile(Map values) {
      final result = Map<String, dynamic>.from(values);
      for (final key in remove) {
        result.remove(key);
      }
      if (result['model_providers'] is Map) {
        final providers = Map<String, dynamic>.from(result['model_providers']);
        providers.remove(routeId);
        result['model_providers'] = providers;
      }
      for (final entry in nestedConnectionFields.entries) {
        if (result[entry.key] is Map) {
          final table = Map<String, dynamic>.from(result[entry.key]);
          for (final key in entry.value) {
            table.remove(key);
          }
          result[entry.key] = table;
        }
      }
      return result;
    }

    while (offset < source.length) {
      final parsed = TomlExpression.parser.parse(source.substring(offset));
      final expression = parsed.value;
      var end = offset + parsed.position;
      if (source.startsWith('\r\n', end)) {
        end += 2;
      } else if (source.startsWith('\n', end)) {
        end++;
      }
      if (end == offset) throw const FormatException('无法定位 TOML 配置字段。');
      var keep = true;
      String? replacement;
      if (expression is TomlTable) {
        context = [for (final part in expression.name.parts) part.name];
        keep = !managed(context);
      } else if (expression is TomlKeyValuePair) {
        final absolute = [
          ...context,
          for (final part in expression.key.parts) part.name,
        ];
        final path = relative(absolute);
        keep =
            !managed(path) &&
            !(path.length == 1 && remove.contains(path[0])) &&
            !(path.length == 2 &&
                (nestedConnectionFields[path[0]]?.contains(path[1]) ?? false));
        if (path.length == 1 && path[0] == 'model_providers') {
          final map = Map<String, dynamic>.from(at(absolute) as Map);
          map.remove(routeId);
          if (absolute.length == 1) {
            if (targetTable != null) map[routeId] = targetTable;
            insertedInline = true;
          }
          replacement =
              '${TomlKeyValuePair(expression.key, TomlValue.from(map))}$newline';
        } else if (path.length == 1 &&
            nestedConnectionFields.containsKey(path[0])) {
          final value = at(absolute);
          if (value is Map) {
            final map = Map<String, dynamic>.from(value);
            for (final key in nestedConnectionFields[path[0]]!) {
              map.remove(key);
            }
            replacement =
                '${TomlKeyValuePair(expression.key, TomlValue.from(map))}$newline';
          }
        } else if (profile != null &&
            absolute.length <= 2 &&
            absolute[0] == 'profiles') {
          final value = at(absolute);
          if (value is Map) {
            Map<String, dynamic>? map;
            if (absolute.length == 2 && absolute[1] == profile) {
              map = stripProfile(value);
            } else if (absolute.length == 1 && value[profile] is Map) {
              map = Map<String, dynamic>.from(value);
              map[profile] = stripProfile(value[profile] as Map);
            }
            if (map != null) {
              replacement =
                  '${TomlKeyValuePair(expression.key, TomlValue.from(map))}$newline';
            }
          }
        }
      }
      if (keep) kept.write(replacement ?? source.substring(offset, end));
      offset = end;
    }
    final top = {
      for (final entry in target.values.entries)
        if (entry.key != 'model_providers') entry.key: entry.value,
    };
    final head = TomlDocument.fromMap(top).toString().replaceAll('\n', newline);
    final body = kept.toString();
    final tail = !insertedInline && targetTable != null
        ? TomlDocument.fromMap({
            'model_providers': {routeId: targetTable},
          }).toString().replaceAll('\n', newline)
        : '';
    final result =
        '$head$newline$body${body.endsWith(newline) ? '' : newline}'
        '${tail.isEmpty ? '' : '$newline$tail'}';
    decode(result);
    return result;
  }

  bool matches(String source, {String? apiKey, bool checkKey = true}) {
    final live = CodexProviderConfig(source)
        .projected(includeKey: checkKey)
        .values;
    final target = projected(
      apiKey: checkKey ? apiKey : null,
      includeKey: checkKey,
    ).values;
    for (final key in compatibilityFields) {
      if (!target.containsKey(key)) live.remove(key);
    }
    return const DeepCollectionEquality().equals(live, target);
  }

  CodexProviderConfig withFields({
    required String name,
    required String model,
    required String baseUrl,
    required String effort,
  }) {
    final result = projected().values;
    if (model.trim().isEmpty) {
      result.remove('model');
    } else {
      result['model'] = model.trim();
    }
    if (effort.isEmpty) {
      result.remove('model_reasoning_effort');
    } else {
      result['model_reasoning_effort'] = effort;
    }
    if (!builtIn) {
      final table = result['model_providers'][routeId] as Map;
      table['name'] = name.trim();
      table['base_url'] = baseUrl.trim();
    }
    return CodexProviderConfig._(result);
  }
}
