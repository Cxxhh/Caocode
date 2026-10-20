import 'dart:io';

import '../platform/app_paths.dart';
import 'editor_launcher.dart';
import 'window_controls.dart';

/// Opens [path] in [editor], or in the app the system opens it with when
/// [editor] is null; false where that cannot be done or it failed.
Future<bool> openPath(String path, {Editor? editor}) async {
  path = AppPaths.expandHome(path);
  if (Platform.isMacOS) return _onMacOS(path, editor?.macApp);
  if (Platform.isWindows) return _onWindows(path, editor);
  if (Platform.isLinux) return _onLinux(path, editor);
  return false;
}

/// `xdg-open` for a file or folder, the editor's command when it has one
/// (`code`, `cursor`), or a terminal in that directory.
Future<bool> _onLinux(String path, Editor? editor) async {
  try {
    if (editor == Editor.terminal) {
      final result = await Process.run(
        'x-terminal-emulator',
        const [],
        workingDirectory: path,
      );
      return result.exitCode == 0;
    }
    final command = editor?.command;
    final result = command == null
        ? await Process.run('xdg-open', [path])
        : await Process.run(command, [path]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// `open [-a app] path`, on macOS.
Future<bool> _onMacOS(String path, String? appName) async {
  try {
    final result = await Process.run('open', [
      if (appName != null) ...['-a', appName],
      path,
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// The window opens it, on Windows: the app found on the PATH, started
/// without a console — a `.cmd` shim (`code`, `cursor`) through cmd.exe —
/// or else by `ShellExecute` (see windows/runner/window_channel.cpp).
Future<bool> _onWindows(String path, Editor? editor) {
  final command = editor?.command;
  if (command == null) return WindowControls.openExternal(path);
  return WindowControls.openExternal(
    path,
    app: command,
    // Windows Terminal opens in the folder with `-d`; the editors take it
    // as the file to open.
    arguments: editor == Editor.terminal ? ['-d', path] : const [],
  );
}
