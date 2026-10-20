import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/decision.dart';
import '../util/json.dart';
import 'file_index.dart';
import 'file_state.dart';
import 'glob_pattern.dart';
import 'tool.dart';

/// The folder a search is in: the one given, else where the agent is.
String _searchRoot(Map<String, Object?> input, ToolContext context) {
  final given = asText(input['path']);
  return given == null
      ? context.cwd
      : context.session.permissions.absolute(given, context.cwd);
}

/// Finds files by name.
class GlobTool extends Tool {
  const GlobTool();

  static const maxResults = 100;

  @override
  String get name => 'Glob';

  @override
  String get description =>
      '''Finds files by name, with a glob pattern such as "**/*.dart" or "lib/**/test_*.py", in a project of any size.

- The paths found come back newest first (by when they were last changed), at most $maxResults.
- For finding files by what is in them, use Grep.
- A search that may take many rounds of looking is better handed to an agent (Agent).
- Several searches that may help can run at once, in calls side by side in one reply.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description': 'The glob the paths must match',
      },
      'path': {
        'type': 'string',
        'description': 'The folder to look in. Leave it out for the working directory (rather than "null" or "undefined")',
      },
    },
    'required': ['pattern'],
    'additionalProperties': false,
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  String? ruleContent(Map<String, Object?> input) => asString(input['path']);

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => context.session.permissions.checkRead(
    _searchRoot(input, context),
    context.cwd,
  );

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final root = _searchRoot(input, context);
    if (!Directory(root).existsSync()) {
      return 'No folder is there: $root';
    }
    return null;
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final started = DateTime.now();
    var root = _searchRoot(input, context);
    var pattern = '${input['pattern']}'.replaceAll(r'\', '/');
    // An absolute pattern searches from its fixed part.
    if (p.isAbsolute(pattern)) {
      final base = GlobPattern.base(pattern);
      root = base.isEmpty ? '/' : base;
      pattern = p.relative(pattern, from: root).replaceAll(r'\', '/');
    } else if (pattern.startsWith('./')) {
      pattern = pattern.substring(2);
    }
    final caseSensitive = !(Platform.isMacOS || Platform.isWindows);
    final glob = GlobPattern(pattern, caseSensitive: caseSensitive);
    final index = context.session.fileIndex;
    final files = await index.list(root, cancel: context.cancel);
    var matched = [
      for (final file in files)
        if (glob.matches(p.relative(file, from: root))) file,
    ];
    if (matched.isEmpty) {
      // Ignored files too, when nothing else matched: the model asked for
      // them by name.
      final all = await index.list(root, ignored: true, cancel: context.cancel);
      matched = [
        for (final file in all)
          if (glob.matches(p.relative(file, from: root))) file,
      ];
    }
    final sorted = byModified(matched);
    final truncated = sorted.length > maxResults;
    final shown = [
      for (final file in sorted.take(maxResults)) shownPath(file, context.cwd),
    ];
    final text = shown.isEmpty
        ? 'No files found'
        : [
            ...shown,
            if (truncated)
              '(Only the first $maxResults are shown: narrow the path or the pattern to see the rest.)',
          ].join('\n');
    return ToolOutput(
      text,
      result: {
        'filenames': shown,
        'durationMs': DateTime.now().difference(started).inMilliseconds,
        'numFiles': shown.length,
        'truncated': truncated,
      },
    );
  }
}

/// Searches files' contents, as ripgrep does (and by ripgrep, where it is
/// installed).
class GrepTool extends Tool {
  const GrepTool();

  @override
  String get name => 'Grep';

  @override
  String get description => '''Searches what files contain, with a regular expression, as ripgrep does.

- Search with this, not with `grep` or `rg` through Bash: it keeps to the folders you may read.
- The pattern is ripgrep's syntax (Rust regex): "fn\\s+\\w+", "TODO|FIXME". A brace to be found as itself is escaped: `map\\{\\}` finds `map{}`.
- Narrow the files with glob ("*.ts", "src/**/*.rs") or type ("py", "go").
- output_mode: files_with_matches (the default) gives the paths of the files with a match; content gives the lines that match, with line numbers and any lines around them asked for (-A, -B, -C); count gives how many matches each file has.
- A pattern matches within a line. For one that runs across lines, such as `class \\w+[\\s\\S]*?init`, set multiline.
- A search that may take many rounds of looking is better handed to an agent (Agent).''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'pattern': {
        'type': 'string',
        'description': 'The regular expression to look for',
      },
      'path': {
        'type': 'string',
        'description':
            'The file or folder to search (the working directory if left out)',
      },
      'glob': {
        'type': 'string',
        'description': 'Only the files whose paths match this glob ("*.kt", "*.{c,h}"), as rg --glob',
      },
      'output_mode': {
        'type': 'string',
        'enum': ['content', 'files_with_matches', 'count'],
        'description': 'What comes back: "files_with_matches" (the default) the paths of the files with a match, "content" the lines that match, "count" how many matches in each file',
      },
      '-B': {
        'type': 'number',
        'description':
            'With content: this many lines before each match too (rg -B)',
      },
      '-A': {
        'type': 'number',
        'description':
            'With content: this many lines after each match too (rg -A)',
      },
      '-C': {
        'type': 'number',
        'description':
            'With content: this many lines on both sides of each match (rg -C)',
      },
      'context': {'type': 'number', 'description': 'Another name for -C'},
      '-n': {
        'type': 'boolean',
        'description': 'With content: each line\'s number before it (rg -n); on unless set false',
      },
      '-i': {
        'type': 'boolean',
        'description': 'Match upper and lower case alike (rg -i)',
      },
      'type': {
        'type': 'string',
        'description': 'Only files of this ripgrep type (rg --type): py, js, rust, go, java and so on; quicker than a glob for a common kind',
      },
      'head_limit': {
        'type': 'number',
        'description': 'Give at most this many lines or paths, whatever the output_mode: 250 unless set, 0 for all',
      },
      'offset': {
        'type': 'number',
        'description': 'Leave out this many lines or paths from the start, before head_limit: for the next page',
      },
      'multiline': {
        'type': 'boolean',
        'description': 'Let a match run across lines, . matching a line break too (rg -U --multiline-dotall)',
      },
    },
    'required': ['pattern'],
    'additionalProperties': false,
  };

  static const defaultHeadLimit = 250;

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  String? ruleContent(Map<String, Object?> input) => asString(input['path']);

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => context.session.permissions.checkRead(
    _searchRoot(input, context),
    context.cwd,
  );

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final root = _searchRoot(input, context);
    if (FileSystemEntity.typeSync(root) == FileSystemEntityType.notFound) {
      return 'Nothing is there: $root';
    }
    try {
      RegExp('${input['pattern']}');
    } on FormatException catch (error) {
      // ripgrep takes some that Dart does not; it is asked when there.
      if (context.session.fileIndex.ripgrep == null) {
        return 'Invalid regular expression: ${error.message}';
      }
    }
    return null;
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final mode = asString(input['output_mode']) ?? 'files_with_matches';
    final limit = asInt(input['head_limit']) ?? defaultHeadLimit;
    final offset = asInt(input['offset']) ?? 0;
    final root = _searchRoot(input, context);
    final search = _Search.from(input);
    final index = context.session.fileIndex;
    List<_Hit> hits;
    if (index.ripgrep case final rg?) {
      hits =
          await _ripgrep(rg, search, root, context) ??
          await _dart(search, root, context);
    } else {
      hits = await _dart(search, root, context);
    }
    String shown(String path) => shownPath(path, context.cwd);
    List<T> page<T>(List<T> items) {
      final skipped = items.skip(offset);
      return (limit > 0 ? skipped.take(limit) : skipped).toList();
    }

    final applied = <String, Object?>{
      if (limit > 0) 'appliedLimit': limit,
      if (offset > 0) 'appliedOffset': offset,
    };
    switch (mode) {
      case 'content':
        final lines = <String>[];
        for (final hit in hits) {
          for (final line in hit.lines) {
            lines.add(
              line.separator
                  ? '--'
                  : search.lineNumbers
                  ? '${shown(hit.path)}${line.match ? ':' : '-'}${line.number}${line.match ? ':' : '-'}${line.text}'
                  : '${shown(hit.path)}${line.match ? ':' : '-'}${line.text}',
            );
          }
        }
        final pageLines = page(lines);
        final text = pageLines.isEmpty
            ? 'No matches found'
            : [
                ...pageLines,
                if (limit > 0 && lines.length > offset + limit)
                  '\n[There is more: offset ${offset + limit} gives the next $limit.]',
              ].join('\n');
        return ToolOutput(
          text,
          result: {
            'mode': 'content',
            'numFiles': hits.length,
            'filenames': <String>[],
            'content': pageLines.join('\n'),
            'numLines': pageLines.length,
            ...applied,
          },
        );
      case 'count':
        final counts = [
          for (final hit in hits) '${shown(hit.path)}:${hit.count}',
        ];
        final pageCounts = page(counts);
        final total = hits.fold<int>(0, (sum, hit) => sum + hit.count);
        final text = pageCounts.isEmpty
            ? 'No matches found'
            : '${pageCounts.join('\n')}\n\nFound $total total '
                  '${total == 1 ? 'occurrence' : 'occurrences'} across '
                  '${hits.length} ${hits.length == 1 ? 'file' : 'files'}.';
        return ToolOutput(
          text,
          result: {
            'mode': 'count',
            'numFiles': hits.length,
            'filenames': <String>[],
            'content': pageCounts.join('\n'),
            'numMatches': total,
            ...applied,
          },
        );
      default:
        final files = page(byModified([for (final hit in hits) hit.path]));
        final names = [for (final file in files) shown(file)];
        final text = names.isEmpty
            ? 'No files found'
            : 'Found ${hits.length} ${hits.length == 1 ? 'file' : 'files'}'
                  '${limit > 0 && hits.length > offset + limit ? ' (showing ${names.length})' : ''}'
                  '\n${names.join('\n')}';
        return ToolOutput(
          text,
          result: {
            'mode': 'files_with_matches',
            'numFiles': hits.length,
            'filenames': names,
            ...applied,
          },
        );
    }
  }

  Future<List<_Hit>?> _ripgrep(
    String rg,
    _Search search,
    String root,
    ToolContext context,
  ) async {
    final isFile = FileSystemEntity.isFileSync(root);
    final args = <String>[
      '--json',
      '--hidden',
      '--glob',
      '!.git',
      '--max-columns',
      '500',
      if (search.ignoreCase) '-i',
      if (search.multiline) ...['-U', '--multiline-dotall'],
      if (search.before > 0) ...['-B', '${search.before}'],
      if (search.after > 0) ...['-A', '${search.after}'],
      if (search.glob case final glob?)
        for (final part in _globParts(glob)) ...['--glob', part],
      if (search.type case final type?) ...['--type', type],
      '-e',
      search.pattern,
      isFile ? root : '.',
    ];
    try {
      final process = await Process.start(
        rg,
        args,
        workingDirectory: isFile ? p.dirname(root) : root,
        environment: context.session.environment,
      );
      unawaited(context.cancel.whenCancelled.then((_) => process.kill()));
      final hits = <String, _Hit>{};
      final lines = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());
      final errors = process.stderr.transform(utf8.decoder).join();
      await for (final line in lines) {
        final Map<String, Object?> event;
        try {
          event = asMap(jsonDecode(line));
        } on FormatException {
          continue;
        }
        final data = asMap(event['data']);
        final pathText = asString(asMap(data['path'])['text']);
        if (pathText == null) continue;
        final path = p.normalize(
          p.isAbsolute(pathText)
              ? pathText
              : p.join(isFile ? p.dirname(root) : root, pathText),
        );
        final text = (asString(asMap(data['lines'])['text']) ?? '')
            .replaceFirst(RegExp(r'\r?\n$'), '');
        final number = asInt(data['line_number']) ?? 0;
        switch (event['type']) {
          case 'match':
            final hit = hits[path] ??= _Hit(path);
            final submatches = asList(data['submatches']).length;
            hit.count += submatches == 0 ? 1 : submatches;
            hit.addLine(number, text, match: true);
          case 'context':
            (hits[path] ??= _Hit(path)).addLine(number, text, match: false);
        }
      }
      final code = await process.exitCode;
      if (code > 1) {
        final message = (await errors).trim();
        if (message.contains('regex')) {
          throw ToolFailure('ripgrep: $message');
        }
        return null;
      }
      return [
        for (final hit in hits.values)
          if (hit.count > 0) hit,
      ];
    } on ProcessException {
      return null;
    }
  }

  /// `*.{ts,tsx}` stays one glob; `*.ts *.tsx` is two.
  static List<String> _globParts(String glob) {
    if (glob.contains('{')) return [glob];
    return [
      for (final part in glob.split(RegExp(r'[\s,]+')))
        if (part.isNotEmpty) part,
    ];
  }

  Future<List<_Hit>> _dart(
    _Search search,
    String root,
    ToolContext context,
  ) async {
    final RegExp regExp;
    try {
      regExp = RegExp(
        search.pattern,
        caseSensitive: !search.ignoreCase,
        multiLine: true,
        dotAll: search.multiline,
      );
    } on FormatException catch (error) {
      throw ToolFailure('Invalid regular expression: ${error.message}');
    }
    final isFile = FileSystemEntity.isFileSync(root);
    final files = isFile
        ? [root]
        : await context.session.fileIndex.list(root, cancel: context.cancel);
    final globs = search.glob == null ? null : _globParts(search.glob!);
    final extensions = search.type == null ? null : _types[search.type];
    final hits = <_Hit>[];
    var checked = 0;
    for (final file in files) {
      if (++checked % 200 == 0) {
        context.cancel.check();
        // Others get a turn.
        await Future<void>.delayed(Duration.zero);
      }
      final relative = isFile ? p.basename(file) : p.relative(file, from: root);
      if (globs != null && !globs.any((glob) => _globMatches(glob, relative))) {
        continue;
      }
      if (extensions != null &&
          !extensions.contains(p.extension(file).toLowerCase()) &&
          !extensions.contains(p.basename(file))) {
        continue;
      }
      final String text;
      try {
        final handle = File(file);
        if (handle.lengthSync() > 20 * 1024 * 1024) continue;
        final bytes = handle.readAsBytesSync();
        if (looksBinary(bytes)) continue;
        text = decodeText(bytes).text;
      } on FileSystemException {
        continue;
      }
      final hit = _Hit(file);
      if (search.multiline) {
        final lines = text.split('\n');
        final starts = _lineStarts(text);
        for (final match in regExp.allMatches(text)) {
          hit.count++;
          final first = _lineAt(starts, match.start);
          final last = _lineAt(
            starts,
            match.end == match.start ? match.end : match.end - 1,
          );
          for (var n = first; n <= last; n++) {
            hit.addLine(n + 1, lines[n], match: true);
          }
        }
        if (hit.count > 0) {
          _context(hit, lines, search);
          hits.add(hit);
        }
        continue;
      }
      final lines = text.split('\n');
      if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
      for (final (i, line) in lines.indexed) {
        final count = regExp.allMatches(line).length;
        if (count == 0) continue;
        hit.count += count;
        hit.addLine(
          i + 1,
          line.length > 500 ? '${line.substring(0, 500)} [...]' : line,
          match: true,
        );
      }
      if (hit.count > 0) {
        _context(hit, lines, search);
        hits.add(hit);
      }
    }
    hits.sort((a, b) => a.path.compareTo(b.path));
    return hits;
  }

  /// Adds the lines before and after [hit]'s matches the search asks for.
  static void _context(_Hit hit, List<String> lines, _Search search) {
    if (search.before == 0 && search.after == 0) return;
    final matched = {
      for (final line in hit.lines)
        if (line.match) line.number,
    };
    final wanted = <int>{};
    for (final n in matched) {
      for (var k = n - search.before; k <= n + search.after; k++) {
        if (k >= 1 && k <= lines.length) wanted.add(k);
      }
    }
    final sorted = wanted.toList()..sort();
    hit.lines.clear();
    int? previous;
    for (final n in sorted) {
      if (previous != null && n > previous + 1) hit.lines.add(_Line.gap);
      hit.lines.add(_Line(n, lines[n - 1], match: matched.contains(n)));
      previous = n;
    }
  }

  static List<int> _lineStarts(String text) {
    final starts = [0];
    for (var i = 0; i < text.length; i++) {
      if (text.codeUnitAt(i) == 10) starts.add(i + 1);
    }
    return starts;
  }

  static int _lineAt(List<int> starts, int offset) {
    var low = 0;
    var high = starts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (starts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  static bool _globMatches(String glob, String relative) {
    final negated = glob.startsWith('!');
    final pattern = negated ? glob.substring(1) : glob;
    final caseSensitive = !(Platform.isMacOS || Platform.isWindows);
    final matches = pattern.contains('/')
        ? GlobPattern(pattern, caseSensitive: caseSensitive).matches(relative)
        : GlobPattern(
            pattern,
            caseSensitive: caseSensitive,
          ).matches(p.basename(relative));
    return negated ? !matches : matches;
  }

  /// ripgrep's file types, as far as a search is likely to name them.
  static const _types = <String, Set<String>>{
    'js': {'.js', '.jsx', '.mjs', '.cjs', '.vue'},
    'ts': {'.ts', '.tsx', '.mts', '.cts'},
    'typescript': {'.ts', '.tsx', '.mts', '.cts'},
    'py': {'.py', '.pyi'},
    'python': {'.py', '.pyi'},
    'rust': {'.rs'},
    'go': {'.go'},
    'java': {'.java', '.jsp'},
    'kotlin': {'.kt', '.kts'},
    'scala': {'.scala', '.sbt'},
    'swift': {'.swift'},
    'dart': {'.dart'},
    'c': {'.c', '.h'},
    'cpp': {'.cpp', '.cc', '.cxx', '.hpp', '.hh', '.hxx', '.h', '.inl'},
    'cs': {'.cs', '.csx'},
    'objc': {'.m', '.h'},
    'rb': {'.rb', '.gemspec', 'Gemfile', 'Rakefile'},
    'ruby': {'.rb', '.gemspec', 'Gemfile', 'Rakefile'},
    'php': {'.php'},
    'lua': {'.lua'},
    'sh': {'.sh', '.bash', '.zsh', '.fish'},
    'md': {'.md', '.markdown', '.mdx'},
    'markdown': {'.md', '.markdown', '.mdx'},
    'json': {'.json', '.jsonc'},
    'yaml': {'.yaml', '.yml'},
    'toml': {'.toml'},
    'xml': {'.xml', '.xsd', '.xsl', '.svg'},
    'html': {'.html', '.htm', '.xhtml'},
    'css': {'.css', '.scss', '.sass', '.less'},
    'sql': {'.sql'},
    'svelte': {'.svelte'},
    'vue': {'.vue'},
    'elixir': {'.ex', '.exs'},
    'erlang': {'.erl', '.hrl'},
    'haskell': {'.hs', '.lhs'},
    'zig': {'.zig'},
    'proto': {'.proto'},
    'make': {'Makefile', 'makefile', 'GNUmakefile', '.mk'},
    'docker': {'Dockerfile', '.dockerfile'},
    'gradle': {'.gradle', '.gradle.kts'},
    'tf': {'.tf', '.tfvars'},
    'txt': {'.txt'},
  };
}

class _Search {
  const _Search({
    required this.pattern,
    required this.ignoreCase,
    required this.multiline,
    required this.before,
    required this.after,
    required this.lineNumbers,
    this.glob,
    this.type,
  });

  factory _Search.from(Map<String, Object?> input) {
    final around = asInt(input['-C']) ?? asInt(input['context']);
    return _Search(
      pattern: '${input['pattern']}',
      ignoreCase: input['-i'] == true,
      multiline: input['multiline'] == true,
      before: input['output_mode'] == 'content'
          ? asInt(input['-B']) ?? around ?? 0
          : 0,
      after: input['output_mode'] == 'content'
          ? asInt(input['-A']) ?? around ?? 0
          : 0,
      lineNumbers: input['-n'] != false,
      glob: asText(input['glob']),
      type: asText(input['type']),
    );
  }

  final String pattern;
  final bool ignoreCase;
  final bool multiline;
  final int before;
  final int after;
  final bool lineNumbers;
  final String? glob;
  final String? type;
}

class _Hit {
  _Hit(this.path);

  final String path;
  int count = 0;
  final List<_Line> lines = [];

  void addLine(int number, String text, {required bool match}) {
    if (lines.isNotEmpty) {
      final last = lines.last;
      if (!last.separator && last.number == number) return;
      if (!last.separator && number > last.number + 1) lines.add(_Line.gap);
    }
    lines.add(_Line(number, text, match: match));
  }
}

class _Line {
  const _Line(this.number, this.text, {required this.match})
    : separator = false;

  const _Line._gap() : number = 0, text = '', match = false, separator = true;

  static const gap = _Line._gap();

  final int number;
  final String text;
  final bool match;
  final bool separator;
}
