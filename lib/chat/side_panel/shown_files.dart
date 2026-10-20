import 'dart:convert';
import 'dart:typed_data';

import 'shown_files_stub.dart'
    if (dart.library.io) 'shown_files_io.dart'
    as platform;

/// What is shown as a file though it is none (a paste, a picture pasted,
/// a stash's text): written once, by what it holds, under this machine's
/// app data (`<data>/cache/shown/`), to open as any file is (see
/// [FileOpenScope.showText]), its tab, its language, its menu theirs.
abstract final class ShownFiles {
  /// [text] in a file named [name] (its extension, else one for what it
  /// holds, see [extensionFor]); null where there are no files (the web)
  /// or it cannot be written.
  static String? text(String text, {required String name}) => platform
      .writeShown(utf8.encode(text), _named(name, () => extensionFor(text)));

  /// [bytes] (a picture's) in a file named [name].
  static String? bytes(Uint8List bytes, {required String name}) =>
      platform.writeShown(bytes, _named(name, () => ''));

  static String _named(String name, String Function() extension) {
    final safe = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').trim();
    final base = safe.isEmpty ? 'shown' : safe;
    return RegExp(r'\.[A-Za-z0-9]{1,8}$').hasMatch(base)
        ? base
        : '$base${extension()}';
  }

  /// The extension of a file holding [text], as what it holds looks:
  /// JSON, a diff, HTML or XML, a script by its `#!`, Markdown, YAML, a
  /// log or stack trace; else plain text.
  static String extensionFor(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.isEmpty) return '.txt';
    final lines = const LineSplitter()
        .convert(trimmed.length > 20000 ? trimmed.substring(0, 20000) : trimmed)
        .take(200)
        .toList();
    final first = lines.first.trim();
    if ((first.startsWith('{') || first.startsWith('[')) && _isJson(trimmed)) {
      return '.json';
    }
    if (first.startsWith('diff --git') ||
        lines.any((line) => line.startsWith('@@ -')) &&
            lines.any((line) => line.startsWith('--- ')) &&
            lines.any((line) => line.startsWith('+++ '))) {
      return '.diff';
    }
    final lower = first.toLowerCase();
    if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
      return '.html';
    }
    if (lower.startsWith('<?xml')) return '.xml';
    if (first.startsWith('#!')) {
      return switch (first) {
        _ when first.contains('python') => '.py',
        _ when first.contains('node') => '.js',
        _ when first.contains('ruby') => '.rb',
        _ when first.contains('perl') => '.pl',
        _ => '.sh',
      };
    }
    bool most(RegExp pattern) {
      final shown = lines.where((line) => line.trim().isNotEmpty).toList();
      return shown.isNotEmpty &&
          shown.where(pattern.hasMatch).length * 10 >= shown.length * 6;
    }

    if (lines.any(
          (line) => RegExp(
            r'^\s*(Traceback \(most recent call last\)|at [\w$.<>]+\(|#\d+\s+\S+ \()',
          ).hasMatch(line),
        ) ||
        most(
          RegExp(
            r'^\s*(\[?\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}|\[?\d{2}:\d{2}:\d{2}|(\[)?(INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL)\b)',
          ),
        )) {
      return '.log';
    }
    if (lines.any((line) => RegExp(r'^(#{1,6} |```)').hasMatch(line)) ||
        most(RegExp(r'^\s*([-*+] |\d+\. |> |#{1,6} |\|)'))) {
      return '.md';
    }
    if (lines.length > 1 &&
        most(RegExp(r'^(\s*[\w.-]+:(\s|$)|\s*- |\s*#|---$)'))) {
      return '.yaml';
    }
    return '.txt';
  }

  static bool _isJson(String text) {
    try {
      jsonDecode(text);
      return true;
    } on FormatException {
      return false;
    }
  }
}
