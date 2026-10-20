import 'dart:io';

import 'package:path/path.dart' as p;

import '../tools/glob_pattern.dart';
import 'frontmatter.dart';
import 'paths.dart';

/// Whose a memory file is.
enum MemoryType { managed, user, project, local }

/// One memory file's instructions, its imports filled in.
class MemoryFile {
  const MemoryFile(this.path, this.type, this.content, {this.globs = const []});

  final String path;
  final MemoryType type;
  final String content;

  /// For a rule that applies only to some files (`paths:` in its header):
  /// the patterns it applies to, relative to [base].
  final List<String> globs;

  bool get conditional => globs.isNotEmpty;

  String get description => switch (type) {
    MemoryType.managed => 'set by the organization',
    MemoryType.user => "the user's own, for every project",
    MemoryType.project => "the project's, kept in its repository",
    MemoryType.local =>
      "the user's own for this project, kept out of its "
          'repository',
  };
}

/// The memory files that apply to a project, as Claude Code finds them:
/// the organisation's, the user's (`~/.claude/CLAUDE.md` and its rules), and
/// from the root down to the project those of each folder (`CLAUDE.md`,
/// `.claude/CLAUDE.md`, `.claude/rules/*.md`, `CLAUDE.local.md`). `@path`
/// imports are read in, five deep at most.
class MemoryLoader {
  MemoryLoader(this.paths);

  final AgentPaths paths;

  static const maxImportDepth = 5;

  /// The files for [cwd] and the [additional] folders (whose own files are
  /// read when [readAdditional]).
  List<MemoryFile> load(
    String cwd, {
    List<String> additional = const [],
    bool readAdditional = false,
  }) {
    final files = <MemoryFile>[];
    final seen = <String>{};
    void add(String path, MemoryType type) {
      final file = File(path);
      if (!file.existsSync()) return;
      final real = _real(path);
      if (!seen.add(real)) return;
      final content = expand(path, file.readAsStringSync(), {real});
      if (content.trim().isEmpty) return;
      files.add(MemoryFile(path, type, content.trim()));
    }

    void addRules(String folder, MemoryType type) {
      final dir = Directory(folder);
      if (!dir.existsSync()) return;
      final rules =
          dir
              .listSync(recursive: true, followLinks: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('.md'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final rule in rules) {
        final real = _real(rule.path);
        if (!seen.add(real)) continue;
        final text = rule.readAsStringSync();
        final front = Frontmatter.parse(text);
        final globs = front.list('paths') ?? front.list('globs') ?? const [];
        final content = expand(rule.path, front.body, {real}).trim();
        if (content.isEmpty) continue;
        files.add(MemoryFile(rule.path, type, content, globs: globs));
      }
    }

    add(p.join(AgentPaths.managedDir, 'CLAUDE.md'), MemoryType.managed);
    add(paths.userMemory, MemoryType.user);
    addRules(p.join(paths.configDir, 'rules'), MemoryType.user);
    // From the root down: the nearest folder's instructions come last, and
    // weigh most.
    final folders = <String>[];
    for (var dir = p.normalize(cwd); ; dir = p.dirname(dir)) {
      folders.add(dir);
      if (p.dirname(dir) == dir) break;
    }
    for (final dir in folders.reversed) {
      // The home folder's `.claude/CLAUDE.md` is the user's, read above.
      add(p.join(dir, 'CLAUDE.md'), MemoryType.project);
      add(p.join(dir, '.claude', 'CLAUDE.md'), MemoryType.project);
      addRules(p.join(dir, '.claude', 'rules'), MemoryType.project);
      add(p.join(dir, 'CLAUDE.local.md'), MemoryType.local);
    }
    if (readAdditional) {
      for (final dir in additional) {
        add(p.join(dir, 'CLAUDE.md'), MemoryType.project);
        add(p.join(dir, '.claude', 'CLAUDE.md'), MemoryType.project);
        addRules(p.join(dir, '.claude', 'rules'), MemoryType.project);
        add(p.join(dir, 'CLAUDE.local.md'), MemoryType.local);
      }
    }
    return files;
  }

  /// The instructions under [folder] (below the project) that apply once
  /// the agent works on a file there: its `CLAUDE.md` files.
  List<MemoryFile> nested(String folder, Set<String> loaded) {
    final files = <MemoryFile>[];
    for (final name in const ['CLAUDE.md', 'CLAUDE.local.md']) {
      final path = p.join(folder, name);
      if (loaded.contains(path) || !File(path).existsSync()) continue;
      final content = expand(path, File(path).readAsStringSync(), {
        _real(path),
      }).trim();
      if (content.isEmpty) continue;
      files.add(
        MemoryFile(
          path,
          name == 'CLAUDE.md' ? MemoryType.project : MemoryType.local,
          content,
        ),
      );
    }
    return files;
  }

  /// [text] (of the file at [path]) with its `@path` imports read in.
  String expand(String path, String text, Set<String> seen, [int depth = 0]) {
    if (depth >= maxImportDepth || !text.contains('@')) return text;
    final out = StringBuffer();
    var inFence = false;
    for (final line in text.split('\n')) {
      if (line.trimLeft().startsWith('```')) inFence = !inFence;
      if (inFence || !line.contains('@')) {
        out.writeln(line);
        continue;
      }
      out.writeln(line);
      for (final match in _import.allMatches(_withoutCode(line))) {
        final target = _resolve(path, match[1]!);
        if (target == null) continue;
        final file = File(target);
        if (!file.existsSync()) continue;
        final real = _real(target);
        if (!seen.add(real)) continue;
        final String imported;
        try {
          imported = file.readAsStringSync();
        } on FileSystemException {
          continue;
        }
        out.writeln(expand(target, imported, seen, depth + 1).trimRight());
      }
    }
    return out.toString().trimRight();
  }

  static final _import = RegExp(r'(?:^|\s)@((?:~|\.{1,2}|/)?[^\s`@]+)');

  static String _withoutCode(String line) =>
      line.replaceAll(RegExp(r'`[^`]*`'), '');

  String? _resolve(String from, String target) {
    if (target.endsWith('.') || target.endsWith(',')) {
      target = target.substring(0, target.length - 1);
    }
    // An email address, a package (`@scope/name`), a mention: not a file.
    if (target.contains('://')) return null;
    final expanded = paths.expandHome(target);
    final path = p.isAbsolute(expanded)
        ? expanded
        : p.join(p.dirname(from), expanded);
    return p.normalize(path);
  }

  static String _real(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return p.normalize(path);
    }
  }

  /// The conditional rules among [files] that apply to [path] (absolute),
  /// relative to [cwd].
  static List<MemoryFile> rulesFor(
    List<MemoryFile> files,
    String path,
    String cwd,
  ) {
    final relative = p.isWithin(cwd, path)
        ? p.relative(path, from: cwd).replaceAll(r'\', '/')
        : path.replaceAll(r'\', '/');
    return [
      for (final file in files)
        if (file.conditional &&
            file.globs.any((glob) => GlobPattern(glob).matches(relative)))
          file,
    ];
  }
}
