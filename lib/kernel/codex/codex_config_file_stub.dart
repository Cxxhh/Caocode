import 'codex_config_file.dart';

CodexConfigFile codexConfigFileAt(
  String path, {
  String? serverHome,
  String? distribution,
}) => throw UnsupportedError('Codex 配置需要桌面环境。');
Future<CodexConfigFile> resolveCodexConfigFile({
  String? cwd,
  String? configPath,
  Map<String, String>? environment,
  bool? windows,
  Future<String> Function(String)? wslHome,
  Future<String> Function(String)? wslUserHome,
}) => Future.error(UnsupportedError('Codex 配置需要桌面环境。'));
