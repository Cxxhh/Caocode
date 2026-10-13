import 'codex_config_file_stub.dart'
    if (dart.library.io) 'codex_config_file_io.dart'
    as platform;
import 'codex_provider_config.dart';

abstract class CodexConfigFile {
  CodexConfigFile();
  factory CodexConfigFile.at(
    String path, {
    String? serverHome,
    String? distribution,
  }) => platform.codexConfigFileAt(
    path,
    serverHome: serverHome,
    distribution: distribution,
  );
  static Future<CodexConfigFile> resolve({
    String? cwd,
    String? configPath,
    Map<String, String>? environment,
    bool? windows,
    Future<String> Function(String)? wslHome,
    Future<String> Function(String)? wslUserHome,
  }) => platform.resolveCodexConfigFile(
    cwd: cwd,
    configPath: configPath,
    environment: environment,
    windows: windows,
    wslHome: wslHome,
    wslUserHome: wslUserHome,
  );

  String get path;
  String get serverHome;
  String get hostLabel;
  Future<String> read();
  Future<String?> importKey();
  Future<void> ensureExists();
  Future<void> activate(
    CodexProviderConfig provider, {
    String? apiKey,
    CodexProviderConfig? outgoing,
  });
}
