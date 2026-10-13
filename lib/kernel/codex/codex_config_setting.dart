abstract final class CodexConfigSetting {
  static const settingKey = 'codexCli.configPath';
  static String? Function() current = () => null;

  static String? parse(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
}
