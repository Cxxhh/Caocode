import 'codex_transport.dart';

CodexTransport localCodexTransport({String? cwd}) =>
    throw UnsupportedError('Codex CLI 需要桌面环境');

String? codexServerPath(String? path) => path;
String codexClientPath(String path, String? project) => path;
Future<void> reapCodexProcesses() async {}
Future<void> stopCodexProcesses() async {}
