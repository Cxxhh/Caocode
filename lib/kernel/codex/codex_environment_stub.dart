import 'codex_environment.dart';

CodexEnvironmentBackend codexEnvironmentBackend() => _Unsupported();

class _Unsupported implements CodexEnvironmentBackend {
  @override
  bool get supported => false;
  @override
  Future<List<String>> distributions() async => const [];
  @override
  Future<String> home(CodexEnvironment environment) =>
      throw UnsupportedError('WSL');
  @override
  Future<bool> exists(String path) async => false;
}
