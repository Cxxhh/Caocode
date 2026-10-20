import 'package:flutter/foundation.dart';

import 'codex_environment_stub.dart'
    if (dart.library.io) 'codex_environment_io.dart'
    as platform;
import 'codex_host.dart';

/// The environment whose projects and history are shown. A project's stored
/// path continues to own its CLI while another environment is selected.
class CodexEnvironment {
  const CodexEnvironment.windows() : distribution = null;
  const CodexEnvironment.wsl(this.distribution);

  final String? distribution;
  bool get isWsl => distribution != null;
  String get id => isWsl ? 'wsl:$distribution' : 'windows';
  String get label => isWsl ? 'WSL2 · $distribution' : 'Windows · Codex';
  String? get root =>
      isWsl ? wslWindowsPath('//wsl.localhost/$distribution/') : null;

  static CodexEnvironment parse(Object? value) =>
      value is String && value.startsWith('wsl:') && value.length > 4
      ? CodexEnvironment.wsl(value.substring(4))
      : const CodexEnvironment.windows();

  bool accepts(String path) {
    final wsl = wslProject(path);
    return isWsl
        ? wsl?.distribution.toLowerCase() == distribution!.toLowerCase()
        : wsl == null;
  }

  String? settingsLocation(String? cwd) => isWsl
      ? (cwd != null && accepts(cwd) ? cwd : root)
      : (cwd != null && accepts(cwd) ? cwd : null);
}

abstract interface class CodexEnvironmentBackend {
  bool get supported;
  Future<List<String>> distributions();
  Future<String> home(CodexEnvironment environment);
  Future<bool> exists(String path);
}

class CodexEnvironmentController extends ChangeNotifier {
  CodexEnvironmentController({CodexEnvironmentBackend? backend})
    : backend = backend ?? platform.codexEnvironmentBackend();

  static CodexEnvironmentController instance = CodexEnvironmentController();
  static const storageKey = 'codexEnvironment';
  final CodexEnvironmentBackend backend;
  CodexEnvironment selected = const CodexEnvironment.windows();
  final Map<String, String> _folders = {};
  Future<void> Function(Map<String, Object?>)? save;
  bool get supported => backend.supported;

  void restore(Object? value) {
    if (value is! Map) return;
    selected = CodexEnvironment.parse(value['selected']);
    final folders = value['folders'];
    if (folders is Map) {
      for (final entry in folders.entries) {
        if (entry.key is String && entry.value is String) {
          _folders[entry.key as String] = entry.value as String;
        }
      }
    }
  }

  Future<void> _save() async => save?.call({
    'selected': selected.id,
    'folders': Map<String, String>.of(_folders),
  });

  Future<void> select(CodexEnvironment environment) async {
    final before = selected;
    selected = environment;
    try {
      await _save();
    } catch (_) {
      selected = before;
      rethrow;
    }
    notifyListeners();
  }

  Future<List<CodexEnvironment>> choices() async => [
    const CodexEnvironment.windows(),
    for (final name in await backend.distributions())
      CodexEnvironment.wsl(name),
  ];

  Future<String?> pick(
    Future<String?> Function(String? initialDirectory) picker,
  ) async {
    if (!supported) return picker(null);
    final target = selected;
    final recent = _folders[target.id];
    final initial =
        recent != null && target.accepts(recent) && await backend.exists(recent)
        ? recent
        : await backend.home(target);
    final path = await picker(initial);
    if (path == null) return null;
    if (!target.accepts(path)) {
      throw FormatException('所选目录不属于 ${target.label}。请切换运行环境，或选择该环境中的目录。');
    }
    _folders[target.id] = path;
    await _save();
    return path;
  }
}
