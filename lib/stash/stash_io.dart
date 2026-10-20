import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../kernel/claude_code/claude_environment.dart';
import 'stash_skill.dart';

/// The picture at [path] (absolute), from its file.
ImageProvider stashImageProvider(String path) => FileImage(File(path));

/// Whether there is a file at [path].
bool stashFileExists(String path) => File(path).existsSync();

/// The title of the page at [url] (its `<title>`, or its Open Graph one);
/// null when it cannot be had soon.
Future<String?> fetchPageTitle(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.acceptHeader, 'text/html');
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Macintosh) Caocode',
    );
    final response = await request.close().timeout(const Duration(seconds: 5));
    if (response.statusCode >= 400) return null;
    final html = StringBuffer();
    await for (final chunk
        in response
            .transform(const Utf8Decoder(allowMalformed: true))
            .timeout(const Duration(seconds: 5))) {
      html.write(chunk);
      // The head is enough.
      if (html.length > 200000 || html.toString().contains('</head>')) break;
    }
    return pageTitleOf(html.toString());
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// [html]'s title: Open Graph's, else its `<title>`.
String? pageTitleOf(String html) {
  final og = RegExp(
    r'''<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']''',
    caseSensitive: false,
  ).firstMatch(html);
  final title =
      og?[1] ??
      RegExp(
        r'<title[^>]*>([\s\S]*?)</title>',
        caseSensitive: false,
      ).firstMatch(html)?[1];
  final cleaned = title
      ?.replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .trim();
  return cleaned == null || cleaned.isEmpty ? null : cleaned;
}

/// The branch checked out in the Git repository at [folder] (its `.git`
/// folder's, or a worktree's `.git` file's); null for none, or detached.
Future<String?> gitBranchOf(String folder) async {
  try {
    var git = '$folder/.git';
    if (await File(git).exists()) {
      // A worktree's: `gitdir: <path>`.
      final line = (await File(git).readAsString()).trim();
      if (!line.startsWith('gitdir:')) return null;
      git = line.substring('gitdir:'.length).trim();
      if (!git.startsWith('/') && !RegExp(r'^[A-Za-z]:').hasMatch(git)) {
        git = '$folder/$git';
      }
    }
    final head = File('$git/HEAD');
    if (!await head.exists()) return null;
    final ref = (await head.readAsString()).trim();
    const prefix = 'ref: refs/heads/';
    return ref.startsWith(prefix) ? ref.substring(prefix.length) : null;
  } on Object {
    return null;
  }
}

/// Whether [folder] is (in) a Git repository: it, or a folder above it,
/// has a `.git`.
Future<bool> isGitRepository(String folder) async {
  var dir = Directory(folder).absolute;
  for (var i = 0; i < 64; i++) {
    if (await FileSystemEntity.type('${dir.path}/.git') !=
        FileSystemEntityType.notFound) {
      return true;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) return false;
    dir = parent;
  }
  return false;
}

/// [path]'s text; null when it cannot be read.
Future<String?> readTextFile(String path) async {
  try {
    return await File(path).readAsString();
  } on Object {
    return null;
  }
}

/// Writes [text] to [path], its folder made if need be.
Future<void> writeTextFile(String path, String text) async {
  try {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  } on Object {
    // A cache: written again next time.
  }
}

/// [path]'s bytes; null when it cannot be read.
Future<Uint8List?> readBytesFile(String path) async {
  try {
    return await File(path).readAsBytes();
  } on Object {
    return null;
  }
}

/// Writes the Stash skill ([StashSkill]), for the stash folder [root],
/// into Claude Code's skills on this machine: where there is none, or
/// Caocode's is not the same.
Future<void> installStashSkill(String root) async {
  try {
    final path = p.join(
      await ClaudeEnvironment.configDir(),
      'skills',
      StashSkill.name,
      'SKILL.md',
    );
    final text = StashSkill.text(root);
    if (!StashSkill.stale(await readTextFile(path), text)) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  } on Object catch (error) {
    debugPrint('The Stash skill was not written: $error');
  }
}
