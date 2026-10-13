import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'cc_switch_providers_stub.dart'
    if (dart.library.io) 'cc_switch_providers_io.dart'
    as platform;
import 'codex_provider_config.dart';
import 'codex_providers.dart';

/// A read-only view of CC Switch. Credentials live only in this snapshot until
/// a provider is activated or explicitly imported into the local secret store.
class CcSwitchProvider {
  const CcSwitchProvider({
    required this.provider,
    this.apiKey,
    this.current = false,
  });

  final CodexProvider provider;
  final String? apiKey;
  final bool current;
}

class CcSwitchSnapshot {
  const CcSwitchSnapshot({
    required this.path,
    required this.providers,
    this.warnings = const [],
  });

  static const pathSettingKey = 'codexCli.ccSwitchDatabasePath';
  final String path;
  final List<CcSwitchProvider> providers;
  final List<String> warnings;

  static Future<CcSwitchSnapshot> read(String? path) =>
      platform.readCcSwitchProviders(path);

  factory CcSwitchSnapshot.fromRows(String path, Iterable<Map> rows) {
    final providers = <CcSwitchProvider>[];
    final warnings = <String>[];
    final source = sha256.convert(utf8.encode(path)).toString();
    for (final row in rows) {
      final name = row['name'];
      try {
        final id = row['id'];
        if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
          throw const FormatException('供应商缺少名称或 ID。');
        }
        final raw = row['settings_config'];
        final settings = raw is String ? jsonDecode(raw) : raw;
        if (settings is! Map || settings['config'] is! String) {
          throw const FormatException('缺少 Codex TOML 配置。');
        }
        final rawMeta = row['meta'];
        final meta = rawMeta is String ? jsonDecode(rawMeta) : rawMeta;
        if (meta is Map) {
          final binding = meta['authBinding'];
          if (binding is Map && binding['source'] == 'managed_account') {
            throw const FormatException('此供应商使用 CCS 托管账号，请通过 CCS 使用。');
          }
          final format = meta['apiFormat'];
          if (format != null && format != 'openai_responses') {
            throw const FormatException('此供应商需要 CCS 代理转换协议，不能直接连接。');
          }
        }
        final config = CodexProviderConfig(settings['config'] as String);
        final wire = config.table['wire_api'];
        if (wire != null && wire != 'responses') {
          throw const FormatException('此供应商需要 CCS 代理转换协议，不能直接连接。');
        }
        final projected = config.projected();
        projected.validate();
        final auth = settings['auth'];
        final key =
            config.apiKey ??
            (auth is Map && auth['OPENAI_API_KEY'] is String
                ? auth['OPENAI_API_KEY'] as String
                : null);
        providers.add(
          CcSwitchProvider(
            provider: CodexProvider(
              id: 'cc-switch:$source:$id',
              name: name,
              config: projected.text,
            ),
            apiKey: key,
            current: row['is_current'] == 1 || row['is_current'] == true,
          ),
        );
      } catch (_) {
        // Never show parser diagnostics: JSON and TOML can contain API keys.
        warnings.add(
          '${name is String ? name : '未命名供应商'}：无法读取或不支持直连，请在 CCS 检查配置与认证方式。',
        );
      }
    }
    return CcSwitchSnapshot(
      path: path,
      providers: providers,
      warnings: warnings,
    );
  }
}
