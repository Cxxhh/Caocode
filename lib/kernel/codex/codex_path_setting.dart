abstract final class CodexPathSetting {
  static const settingKey = 'codexCli.path';
  static String? Function() current = () => null;
  static String? parse(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
}
