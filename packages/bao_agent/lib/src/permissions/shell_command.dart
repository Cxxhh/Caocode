/// A shell command line, taken apart as far as permissions need: the
/// simple commands it is made of, and what in it could hide another
/// command or write a file.
class ShellCommand {
  ShellCommand._(
    this.source,
    this.commands,
    this.hasSubstitution,
    this.redirects,
    this.unbalanced,
  );

  /// Splits [source] at `&&`, `||`, `;`, `|`, `&` and new lines outside
  /// quotes. A heredoc's lines are its command's input, not commands.
  factory ShellCommand.parse(String source) {
    final commands = <String>[];
    final redirects = <String>[];
    var substitution = false;
    final current = StringBuffer();
    String? quote;
    var i = 0;
    // The heredocs begun on this line, their lines to come after it.
    final heredocs = <({String end, bool tabs, bool literal})>[];

    void cut() {
      final text = current.toString().trim();
      if (text.isNotEmpty) commands.add(text);
      current.clear();
    }

    while (i < source.length) {
      final c = source[i];
      final next = i + 1 < source.length ? source[i + 1] : '';
      if (quote == "'") {
        current.write(c);
        if (c == "'") quote = null;
        i++;
        continue;
      }
      if (c == r'\' && next.isNotEmpty) {
        // A line continued: no break.
        if (next != '\n') current.write('$c$next');
        i += 2;
        continue;
      }
      if (quote == '"') {
        current.write(c);
        if (c == '"') {
          quote = null;
        } else if (c == r'$' && next == '(' || c == '`') {
          substitution = true;
        }
        i++;
        continue;
      }
      switch (c) {
        case "'" || '"':
          quote = c;
          current.write(c);
          i++;
        case '`':
          substitution = true;
          current.write(c);
          i++;
        case r'$' when next == '(':
          substitution = true;
          current.write(c);
          i++;
        case '<' || '>' when next == '(':
          substitution = true;
          current.write(c);
          i++;
        case '#'
            when current.isEmpty || RegExp(r'\s$').hasMatch(current.toString()):
          // A comment, to the end of the line.
          while (i < source.length && source[i] != '\n') {
            i++;
          }
        case '<' when next == '<' && source.startsWith('<<<', i):
          // A here-string: a word, not lines.
          current.write('<<<');
          i += 3;
        case '<' when next == '<':
          final tabs = source.startsWith('<<-', i);
          var at = i + (tabs ? 3 : 2);
          while (at < source.length && ' \t'.contains(source[at])) {
            at++;
          }
          final (end, after) = _redirectTarget(source, at);
          final word = source.substring(at, after);
          heredocs.add((
            end: end,
            tabs: tabs,
            // A quoted delimiter: the lines as they are, nothing expanded.
            literal:
                word.contains("'") || word.contains('"') || word.contains(r'\'),
          ));
          current.write(source.substring(i, after));
          i = after;
        case ';':
          cut();
          i++;
        case '\n':
          cut();
          i++;
          for (final heredoc in heredocs) {
            while (i < source.length) {
              var lineEnd = source.indexOf('\n', i);
              if (lineEnd < 0) lineEnd = source.length;
              var line = source.substring(i, lineEnd);
              i = lineEnd + 1;
              if (heredoc.tabs) line = line.replaceFirst(RegExp('^\t+'), '');
              if (line == heredoc.end) break;
              if (!heredoc.literal &&
                  (line.contains(r'$(') || line.contains('`'))) {
                substitution = true;
              }
            }
          }
          heredocs.clear();
        case '&' when next == '&':
          cut();
          i += 2;
        case '|' when next == '|':
          cut();
          i += 2;
        case '|':
          cut();
          i += next == '&' ? 2 : 1;
        case '&' when next == '>':
          // `&>file`: both streams to a file.
          final (target, end) = _redirectTarget(source, i + 2);
          redirects.add(target);
          current.write(source.substring(i, end));
          i = end;
        case '&':
          final before = current.toString();
          // `2>&1` and `>&2` are not a command's end.
          if (before.endsWith('>') || before.endsWith('<')) {
            current.write(c);
            i++;
          } else {
            cut();
            i++;
          }
        case '>':
          var end = i + 1;
          if (end < source.length &&
              (source[end] == '>' || source[end] == '|')) {
            end++;
          }
          if (end < source.length && source[end] == '&') {
            // `>&2`: to another stream, not a file.
            current.write(source.substring(i, end + 1));
            i = end + 1;
            break;
          }
          final (target, after) = _redirectTarget(source, end);
          redirects.add(target);
          current.write(source.substring(i, after));
          i = after;
        default:
          current.write(c);
          i++;
      }
    }
    cut();
    return ShellCommand._(
      source,
      commands,
      substitution,
      redirects,
      quote != null,
    );
  }

  static (String, int) _redirectTarget(String source, int from) {
    var i = from;
    while (i < source.length && (source[i] == ' ' || source[i] == '\t')) {
      i++;
    }
    final start = i;
    String? quote;
    while (i < source.length) {
      final c = source[i];
      if (quote != null) {
        if (c == quote) quote = null;
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (' \t\n;&|<>()'.contains(c)) {
        break;
      }
      i++;
    }
    return (_unquote(source.substring(start, i)), i);
  }

  final String source;

  /// The simple commands, each as written.
  final List<String> commands;

  /// Whether it runs a command inside another: `$(…)`, backticks, `<(…)`.
  final bool hasSubstitution;

  /// The files output is sent to (`> file`, `>> file`).
  final List<String> redirects;

  /// Whether a quote is left open: what it means is not clear.
  final bool unbalanced;

  /// Whether it writes to no file but the null device.
  bool get redirectsOnlyToNull =>
      redirects.every((target) => target == '/dev/null' || target == 'NUL');

  /// Each simple command's words, quotes taken off, environment assignments
  /// before it left out.
  List<List<String>> get words => [
    for (final command in commands) withoutAssignments(tokenize(command)),
  ];

  static String _unquote(String word) {
    final out = StringBuffer();
    String? quote;
    for (var i = 0; i < word.length; i++) {
      final c = word[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else if (c == r'\' && quote == '"' && i + 1 < word.length) {
          out.write(word[++i]);
        } else {
          out.write(c);
        }
      } else if (c == '"' || c == "'") {
        quote = c;
      } else if (c == r'\' && i + 1 < word.length) {
        out.write(word[++i]);
      } else {
        out.write(c);
      }
    }
    return out.toString();
  }

  /// [command]'s words, as the shell would split them (no expansion),
  /// redirections left out.
  static List<String> tokenize(String command) {
    final words = <String>[];
    final current = StringBuffer();
    String? quote;
    var started = false;
    var skipNext = false;
    void end() {
      if (started) {
        final word = current.toString();
        if (skipNext) {
          skipNext = false;
        } else if (RegExp(r'^\d*(>>?|<|&>)$').hasMatch(word)) {
          // A redirection; its target is the next word.
          skipNext = true;
        } else if (RegExp(r'^\d*(>>?|<|&>|>&)\S').hasMatch(word)) {
          // A redirection with its target: left out.
        } else {
          words.add(word);
        }
      }
      current.clear();
      started = false;
    }

    for (var i = 0; i < command.length; i++) {
      final c = command[i];
      if (quote != null) {
        if (c == quote) {
          quote = null;
        } else if (c == r'\' && quote == '"' && i + 1 < command.length) {
          current.write(command[++i]);
        } else {
          current.write(c);
        }
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        started = true;
      } else if (c == r'\' && i + 1 < command.length) {
        current.write(command[++i]);
        started = true;
      } else if (c == ' ' || c == '\t' || c == '\n') {
        end();
      } else {
        current.write(c);
        started = true;
      }
    }
    end();
    return words;
  }

  /// [words] without the `NAME=value` assignments before the command.
  static List<String> withoutAssignments(List<String> words) {
    var i = 0;
    while (i < words.length &&
        RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words[i])) {
      i++;
    }
    return words.sublist(i);
  }

  /// The words a rule for [command] (one simple command) is best made of:
  /// the program, and its subcommand where it has them (`git commit`,
  /// `npm run build`).
  static String prefix(String command) {
    final words = withoutAssignments(tokenize(command));
    if (words.isEmpty) return command.trim();
    final first = words.first;
    if (_hasSubcommands.contains(first) && words.length > 1) {
      final second = words[1];
      if ((first == 'python' || first == 'python3') && second == '-m') {
        return words.length > 2 ? '$first -m ${words[2]}' : first;
      }
      if (second.startsWith('-')) return first;
      if ((first == 'npm' ||
              first == 'pnpm' ||
              first == 'yarn' ||
              first == 'bun') &&
          second == 'run' &&
          words.length > 2) {
        return '$first $second ${words[2]}';
      }
      return '$first $second';
    }
    return first;
  }

  static const _hasSubcommands = {
    'git',
    'npm',
    'pnpm',
    'yarn',
    'bun',
    'cargo',
    'go',
    'docker',
    'kubectl',
    'flutter',
    'dart',
    'gh',
    'brew',
    'pip',
    'pip3',
    'uv',
    'poetry',
    'make',
    'mvn',
    'gradle',
    './gradlew',
    'dotnet',
    'swift',
    'xcodebuild',
    'pod',
    'terraform',
    'helm',
    'aws',
    'gcloud',
    'az',
    'deno',
    'npx',
    'bunx',
    'python',
    'python3',
    'rails',
    'bundle',
    'composer',
    'php',
    'mix',
    'stack',
    'cabal',
    'nx',
    'turbo',
    'wrangler',
    'firebase',
    'vercel',
  };
}

/// Whether [command] only reads: each of its simple commands is one known
/// not to change anything, it writes no file and runs nothing hidden.
bool isReadOnlyCommand(String command) {
  final parsed = ShellCommand.parse(command);
  if (parsed.unbalanced || parsed.hasSubstitution) return false;
  if (!parsed.redirectsOnlyToNull) return false;
  if (parsed.commands.isEmpty) return false;
  return parsed.words.every(isReadOnlyWords);
}

/// Whether the simple command [words] only reads.
bool isReadOnlyWords(List<String> words) {
  if (words.isEmpty) return true;
  final program = words.first.split('/').last;
  final args = words.sublist(1);
  bool has(Iterable<String> flags) => args.any(
    (arg) => flags.any((flag) => arg == flag || arg.startsWith('$flag=')),
  );
  switch (program) {
    case 'git':
      return _readOnlyGit(args);
    case 'find':
      return !has(const [
        '-exec',
        '-execdir',
        '-delete',
        '-ok',
        '-okdir',
        '-fprint',
        '-fprint0',
        '-fprintf',
        '-fls',
      ]);
    case 'sed':
      return !args.any(
        (arg) =>
            arg == '-i' ||
            arg.startsWith('-i') && !arg.startsWith('--') ||
            arg.startsWith('--in-place') ||
            RegExp(r'^-[a-zA-Z]*i').hasMatch(arg),
      );
    case 'sort':
      return !has(const ['-o', '--output']);
    case 'tree':
      return !has(const ['-o']);
    case 'env' || 'printenv':
      // `env cmd` runs cmd.
      return args.every((arg) => arg.startsWith('-') || arg.contains('='))
          ? program == 'printenv' || args.isEmpty
          : program == 'printenv';
    case 'xargs':
      return args.isNotEmpty &&
          isReadOnlyWords([
            for (final arg in args)
              if (!arg.startsWith('-')) arg,
          ]);
    case 'command':
      return args.isNotEmpty && (args.first == '-v' || args.first == '-V');
    case 'npm' || 'pnpm' || 'yarn':
      return args.isNotEmpty &&
          const {
            'ls',
            'list',
            'view',
            'info',
            'outdated',
            'why',
            'root',
            'prefix',
            'bin',
            'help',
            '--version',
            '-v',
          }.contains(args.first);
    case 'cargo':
      return args.isNotEmpty &&
          const {
            'tree',
            'metadata',
            '--version',
            'search',
          }.contains(args.first);
    case 'go':
      return args.isNotEmpty &&
          const {'version', 'env', 'list', 'doc'}.contains(args.first);
    case 'docker':
      return args.isNotEmpty &&
          const {
            'ps',
            'images',
            'logs',
            'inspect',
            'version',
            'info',
          }.contains(args.first);
    case 'gh':
      return args.length >= 2 &&
          const {'view', 'list', 'status', 'diff', 'checks'}.contains(args[1]);
  }
  return _readOnlyPrograms.contains(program);
}

const _readOnlyPrograms = {
  'ls',
  'cat',
  'head',
  'tail',
  'wc',
  'grep',
  'egrep',
  'fgrep',
  'rg',
  'ag',
  'ack',
  'pwd',
  'echo',
  'printf',
  'which',
  'whereis',
  'type',
  'file',
  'stat',
  'du',
  'df',
  'date',
  'uname',
  'whoami',
  'id',
  'hostname',
  'uniq',
  'cut',
  'tr',
  'jq',
  'yq',
  'diff',
  'cmp',
  'basename',
  'dirname',
  'realpath',
  'readlink',
  'true',
  'false',
  'test',
  '[',
  'nl',
  'od',
  'xxd',
  'hexdump',
  'strings',
  'md5',
  'md5sum',
  'shasum',
  'sha1sum',
  'sha256sum',
  'column',
  'comm',
  'fold',
  'expand',
  'unexpand',
  'seq',
  'sleep',
  'cd',
  'less',
  'more',
  'man',
  'help',
  'tac',
  'rev',
  'paste',
  'join',
  'fmt',
  'locale',
  'uptime',
  'arch',
  'nproc',
  'sw_vers',
  'lsof',
  'ps',
  'top',
  'pgrep',
  'groups',
  'tty',
  'cal',
  'look',
  'zcat',
  'bzcat',
  'xzcat',
  'fd',
  'fzf',
  'bat',
  'exa',
  'eza',
  'dust',
  'tokei',
  'cloc',
  'awk',
  'gawk',
  'mawk',
};

bool _readOnlyGit(List<String> args) {
  // Global options first (`git -C dir status`).
  var i = 0;
  while (i < args.length && args[i].startsWith('-')) {
    if (args[i] == '-C' || args[i] == '-c') i++;
    i++;
  }
  if (i >= args.length) return true;
  final sub = args[i];
  final rest = args.sublist(i + 1);
  bool none(Iterable<String> flags) => !rest.any(
    (arg) => flags.any((flag) => arg == flag || arg.startsWith('$flag=')),
  );
  switch (sub) {
    case 'status' ||
        'log' ||
        'diff' ||
        'show' ||
        'rev-parse' ||
        'ls-files' ||
        'ls-tree' ||
        'blame' ||
        'describe' ||
        'shortlog' ||
        'grep' ||
        'cat-file' ||
        'merge-base' ||
        'name-rev' ||
        'whatchanged' ||
        'rev-list' ||
        'show-ref' ||
        'for-each-ref' ||
        'count-objects' ||
        'check-ignore' ||
        'var' ||
        'version' ||
        'help' ||
        'ls-remote':
      return none(const ['--output', '-o']);
    case 'branch':
      return none(const [
            '-d',
            '-D',
            '-m',
            '-M',
            '-c',
            '-C',
            '--delete',
            '--move',
            '--copy',
            '--set-upstream-to',
            '-u',
            '--unset-upstream',
            '--edit-description',
            '-f',
            '--force',
          ]) &&
          // A name alone makes a branch; with a listing flag it filters.
          (rest.every((arg) => arg.startsWith('-')) ||
              rest.any(
                (arg) => const {
                  '--list',
                  '-l',
                  '--contains',
                  '--no-contains',
                  '--merged',
                  '--no-merged',
                  '--points-at',
                }.contains(arg),
              ));
    case 'tag':
      return rest.isEmpty || rest.contains('-l') || rest.contains('--list');
    case 'remote':
      return rest.isEmpty ||
          rest.every((arg) => arg == '-v' || arg == '--verbose') ||
          (rest.first == 'show' || rest.first == 'get-url');
    case 'config':
      return rest.any(
        (arg) =>
            arg == '--get' ||
            arg == '--get-all' ||
            arg == '--list' ||
            arg == '-l' ||
            arg == '--get-regexp',
      );
    case 'stash':
      return rest.isNotEmpty && (rest.first == 'list' || rest.first == 'show');
    case 'worktree':
      return rest.isNotEmpty && rest.first == 'list';
    case 'reflog':
      return rest.isEmpty || rest.first == 'show';
  }
  return false;
}

/// Whether [words] is a command that destroys what cannot be got back
/// wholesale (`rm -rf /`, `rm -rf ~`): asked about in every mode.
bool isDangerousWords(List<String> words, {required String home}) {
  if (words.isEmpty) return false;
  final program = words.first.split('/').last;
  if (program == 'sudo' || program == 'doas') return true;
  if (program == 'mkfs' || program.startsWith('mkfs.') || program == 'dd') {
    return words.any((w) => w.startsWith('of=/dev/') || program != 'dd');
  }
  if (program != 'rm') return false;
  final flags = words.where((w) => w.startsWith('-')).join();
  final recursive =
      flags.contains('r') ||
      flags.contains('R') ||
      words.contains('--recursive');
  if (!recursive) return false;
  for (final target in words.skip(1).where((w) => !w.startsWith('-'))) {
    final t = target.replaceAll(RegExp(r'/+$'), '');
    if (t.isEmpty ||
        t == '/' ||
        t == '/*' ||
        t == '~' ||
        t == r'$HOME' ||
        t == r'${HOME}' ||
        t == '~/*' ||
        t == home ||
        t == '*' ||
        t == '.' ||
        t == '..') {
      return true;
    }
  }
  return false;
}

/// Programs that only make, move or remove files: allowed in accept-edits
/// mode when what they touch is in the working folders.
const fileSystemPrograms = {
  'mkdir',
  'touch',
  'mv',
  'cp',
  'rm',
  'rmdir',
  'ln',
  'chmod',
};
