import 'codex_host_settings.dart';

abstract final class CodexConfigSetting {
  static const settingKey = 'codexCli.configPath';
  static String? Function() current = () => null;
  static String? forLocation(String? cwd, {bool? windows}) =>
      CodexHostSettings.value(settingKey, cwd, current(), windows: windows);

  static String? parse(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
}
