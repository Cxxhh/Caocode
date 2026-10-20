import '../../platform/app_platform.dart';
import 'codex_host.dart';

/// Windows and each WSL distribution keep their executable/config overrides
/// independently. Older unscoped settings still apply to compatible paths.
abstract final class CodexHostSettings {
  static Object? Function(String key) read = (_) => null;

  static String key(String base, String? cwd, {bool? windows}) {
    if (!(windows ?? AppPlatform.isWindows)) return base;
    final wsl = wslProject(cwd);
    return '$base.${wsl == null ? 'windows' : 'wsl.${wsl.distribution}'}';
  }

  static String? value(
    String base,
    String? cwd,
    String? legacy, {
    bool? windows,
    Object? Function(String)? readSetting,
  }) {
    final win = windows ?? AppPlatform.isWindows;
    final scoped = (readSetting ?? read)(key(base, cwd, windows: win));
    if (scoped is String) return scoped.trim().isEmpty ? null : scoped.trim();
    if (legacy == null || !win) return legacy;
    final target = wslProject(cwd);
    final path = legacy.replaceAll('\\', '/');
    final source = wslProject(path);
    if (target != null) {
      if (RegExp(r'^[A-Za-z]:/').hasMatch(path)) return null;
      if (source != null) {
        return source.distribution.toLowerCase() ==
                target.distribution.toLowerCase()
            ? source.path
            : null;
      }
    } else if (source != null ||
        (path.startsWith('/') && !path.startsWith('//'))) {
      return null;
    }
    return legacy;
  }
}
