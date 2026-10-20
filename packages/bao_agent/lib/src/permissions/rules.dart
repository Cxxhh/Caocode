import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/settings.dart';
import '../tools/glob_pattern.dart';
import 'shell_command.dart';

/// A permission rule, taken apart: the tool it is for and what of its
/// input it matches (`Bash(npm test:*)` is `Bash` and `npm test:*`).
class PermissionRule {
  const PermissionRule({
    required this.tool,
    required this.content,
    required this.behavior,
    required this.source,
    required this.text,
    this.root,
  });

  static PermissionRule parse(SourcedRule rule) {
    final text = rule.rule;
    final open = text.indexOf('(');
    String tool;
    String? content;
    if (open > 0 && text.endsWith(')')) {
      tool = text.substring(0, open).trim();
      content = text.substring(open + 1, text.length - 1);
      // `Bash()` and `Bash(*)` are the whole tool.
      if (content.trim().isEmpty || content.trim() == '*') content = null;
    } else {
      tool = text.trim();
    }
    return PermissionRule(
      tool: _canonical(tool),
      content: content,
      behavior: rule.behavior,
      source: rule.source,
      text: text,
      root: rule.root,
    );
  }

  /// The tool's name; an older one taken as the current.
  final String tool;

  /// What of the input it matches; null for the tool as a whole.
  final String? content;

  /// `allow`, `deny` or `ask`.
  final String behavior;
  final SettingsSource source;

  /// As written.
  final String text;

  /// The folder a `/path` in it is taken from.
  final String? root;

  bool get wholeTool => content == null;

  static String _canonical(String tool) => switch (tool) {
    'Task' => 'Agent',
    'KillShell' || 'KillBash' => 'TaskStop',
    'BashOutput' => 'TaskOutput',
    _ => tool,
  };

  /// Whether it is about [toolName] (an MCP server's rule covers its
  /// tools).
  bool isFor(String toolName) {
    final name = _canonical(toolName);
    if (tool == name) return true;
    if (tool.startsWith('mcp__') && name.startsWith('mcp__')) {
      final ruleParts = tool.split('__');
      final toolParts = name.split('__');
      // `mcp__server` and `mcp__server__*`: all of the server's tools.
      if (ruleParts.length == 2 ||
          (ruleParts.length == 3 && ruleParts[2] == '*')) {
        return toolParts.length >= 2 && toolParts[1] == ruleParts[1];
      }
    }
    return false;
  }
}

/// The tools a `Read(…)` rule covers: what reads files.
const readingTools = {'Read', 'Glob', 'Grep', 'LS', 'NotebookRead'};

/// The tools an `Edit(…)` rule covers: what changes files.
const editingTools = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit'};

/// Whether the command rule [content] matches [command] (one simple
/// command, or the whole line): `npm test` exactly, `npm test:*` it and
/// what follows it, `npm *` with `*` standing for anything.
bool bashRuleMatches(String content, String command) {
  final rule = content.trim();
  final normalized = _normalizeCommand(command);
  if (rule.endsWith(':*')) {
    final prefix = rule.substring(0, rule.length - 2).trim();
    return normalized == prefix || normalized.startsWith('$prefix ');
  }
  if (rule.contains('*')) {
    final pattern = StringBuffer('^');
    for (final (i, part) in rule.split('*').indexed) {
      if (i > 0) pattern.write('.*');
      pattern.write(RegExp.escape(part));
    }
    pattern.write(r'$');
    if (RegExp(pattern.toString(), dotAll: true).hasMatch(normalized)) {
      return true;
    }
    // `ls *` covers `ls` alone too.
    if (rule.endsWith(' *')) {
      return normalized == rule.substring(0, rule.length - 2).trim();
    }
    return false;
  }
  return normalized == rule;
}

/// [command] with its leading assignments and runs of spaces taken out.
String _normalizeCommand(String command) {
  final trimmed = command.trim();
  final words = ShellCommand.tokenize(trimmed);
  final kept = ShellCommand.withoutAssignments(words);
  if (kept.length == words.length) {
    return trimmed.replaceAll(RegExp(r'[ \t]+'), ' ');
  }
  // Rebuilt from the words when assignments came first.
  var rest = trimmed;
  for (var i = 0; i < words.length - kept.length; i++) {
    final at = rest.indexOf(words[i].split('=').first);
    if (at < 0) break;
    final space = rest.indexOf(RegExp(r'\s'), at);
    rest = space < 0 ? '' : rest.substring(space).trimLeft();
  }
  return rest.replaceAll(RegExp(r'[ \t]+'), ' ');
}

/// Whether the path rule [content] (gitignore-like) matches [path]
/// (absolute). `//abs/path` is from the root, `~/x` from home, `/x` from
/// [root] (the settings file's folder), `x` or `./x` from [cwd]. A pattern
/// with no slash matches a name at any depth; one naming a folder matches
/// what is in it.
bool pathRuleMatches(
  String content, {
  required String path,
  required String cwd,
  required String home,
  String? root,
}) {
  var rule = content.trim().replaceAll(r'\', '/');
  if (rule.isEmpty) return false;
  final target = p.normalize(path).replaceAll(r'\', '/');
  String base;
  if (rule.startsWith('//')) {
    base = '/';
    rule = rule.substring(2);
  } else if (rule.startsWith('~/')) {
    base = home;
    rule = rule.substring(2);
  } else if (rule.startsWith('/')) {
    base = root ?? cwd;
    rule = rule.substring(1);
  } else {
    base = cwd;
    if (rule.startsWith('./')) {
      rule = rule.substring(2);
    } else if (!rule.contains('/') ||
        (rule.endsWith('/') &&
            !rule.substring(0, rule.length - 1).contains('/'))) {
      rule = '**/$rule';
    }
  }
  base = base.replaceAll(r'\', '/');
  // A Windows drive as Claude Code writes it: `/c/Users/…`.
  final drive = RegExp(r'^/([a-zA-Z])/').firstMatch('/$rule');
  if (base == '/' && drive != null && RegExp(r'^[A-Za-z]:/').hasMatch(target)) {
    rule = '${drive[1]!.toUpperCase()}:/${rule.substring(2)}';
    base = '';
  }
  if (rule.endsWith('/')) rule = '$rule**';
  final full = base.isEmpty
      ? rule
      : base.endsWith('/')
      ? '$base$rule'
      : '$base/$rule';
  // The file systems macOS and Windows have by default ignore case.
  final caseSensitive = !(Platform.isMacOS || Platform.isWindows);
  final glob = GlobPattern(full, caseSensitive: caseSensitive);
  if (glob.matches(target)) return true;
  // A folder named covers what is in it.
  if (!full.endsWith('**')) {
    return GlobPattern(
      '$full/**',
      caseSensitive: caseSensitive,
    ).matches(target);
  }
  return false;
}

/// Whether the domain rule [content] (`domain:example.com`,
/// `domain:*.example.com`) matches [url].
bool domainRuleMatches(String content, String url) {
  final rule = content.trim();
  if (!rule.startsWith('domain:')) {
    return rule == url;
  }
  final domain = rule.substring('domain:'.length).trim().toLowerCase();
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  if (domain.startsWith('*.')) {
    final suffix = domain.substring(1);
    return host.endsWith(suffix) || host == domain.substring(2);
  }
  return host == domain;
}

/// Whether the plain rule [content] matches [value]: exactly, or as a
/// prefix (`name:*`), or with `*` standing for anything.
bool plainRuleMatches(String content, String value) {
  final rule = content.trim();
  if (rule.endsWith(':*')) {
    final prefix = rule.substring(0, rule.length - 2);
    return value == prefix || value.startsWith(prefix);
  }
  if (rule.contains('*')) {
    final pattern = rule.split('*').map(RegExp.escape).join('.*');
    return RegExp('^$pattern\$').hasMatch(value);
  }
  return rule == value;
}

/// The rule that lets the agent at what is in [folder] with [tool]:
/// `Read(//Users/me/x/**)`.
String folderRule(String tool, String folder) {
  var path = folder.replaceAll(r'\', '/');
  if (RegExp(r'^[A-Za-z]:').hasMatch(path)) {
    path = '/${path[0].toLowerCase()}${path.substring(2)}';
  }
  if (path.endsWith('/')) path = path.substring(0, path.length - 1);
  return '$tool(/$path/**)';
}
