import 'dart:io';

import '../config/extensions.dart';
import '../config/memory.dart';
import '../prompts/system_prompt.dart';
import 'session.dart';

/// The repository the session works in, as it stood at the start.
class GitSnapshot {
  const GitSnapshot({
    required this.branch,
    required this.mainBranch,
    required this.status,
    required this.recentCommits,
  });

  final String branch;
  final String? mainBranch;
  final String status;
  final String recentCommits;

  /// The snapshot of [cwd]; null when it is not in a repository (or Git
  /// is not there).
  static Future<GitSnapshot?> of(
    String cwd,
    Map<String, String> environment,
  ) async {
    Future<String?> git(List<String> args) async {
      try {
        final result = await Process.run(
          'git',
          args,
          workingDirectory: cwd,
          environment: {...environment, 'GIT_OPTIONAL_LOCKS': '0'},
          includeParentEnvironment: false,
        ).timeout(const Duration(seconds: 5));
        if (result.exitCode != 0) return null;
        return '${result.stdout}'.trim();
      } on Object {
        return null;
      }
    }

    if (await git(['rev-parse', '--is-inside-work-tree']) != 'true') {
      return null;
    }
    final (branch, status, log, head) = await (
      git(['branch', '--show-current']),
      git(['status', '--short']),
      git(['log', '--oneline', '-n', '5']),
      git(['symbolic-ref', '--short', 'refs/remotes/origin/HEAD']),
    ).wait;
    var main = head?.replaceFirst(RegExp(r'^origin/'), '');
    if (main == null || main.isEmpty) {
      for (final candidate in const ['main', 'master']) {
        if (await git(['rev-parse', '--verify', '--quiet', candidate]) !=
            null) {
          main = candidate;
          break;
        }
      }
    }
    var shown = status ?? '';
    if (shown.length > 2000) {
      shown =
          '${shown.substring(0, 2000)}\n… (cut at 2,000 characters: run '
          '`git status` through Bash for the rest)';
    }
    return GitSnapshot(
      branch: branch == null || branch.isEmpty ? 'HEAD (detached)' : branch,
      mainBranch: main,
      status: shown,
      recentCommits: log ?? '',
    );
  }
}

/// What the model is told of where it works: its system prompt, and the
/// context sent with the conversation's first message.
class SessionContext {
  SessionContext(this.session);

  final AgentSession session;
  GitSnapshot? git;
  bool _loaded = false;

  /// Reads what the session works with: plugins, commands and skills,
  /// subagents, memory files, the repository.
  Future<void> load() async {
    final session = this.session;
    session.plugins = loadPlugins(session.paths, session.settings);
    reloadExtensions();
    git = await GitSnapshot.of(session.cwd, session.commandEnvironment);
    _loaded = true;
  }

  /// Reads the plugins again (one installed or switched on since), and
  /// with them the rest.
  void reloadPlugins() {
    final session = this.session;
    session.reloadSettings();
    session.plugins = loadPlugins(session.paths, session.settings);
    reloadExtensions();
  }

  /// Reads the commands, skills, subagents and memory again (one was
  /// added or changed).
  void reloadExtensions() {
    final session = this.session;
    session.promptCommands = loadPromptCommands(
      paths: session.paths,
      cwd: session.cwd,
      plugins: session.plugins,
      additional: session.workingDirectories.skip(1).toList(),
    );
    session.agentDefinitions = loadAgents(
      paths: session.paths,
      cwd: session.cwd,
      plugins: session.plugins,
    );
    session.memory = session.memoryLoader.load(
      session.cwd,
      additional: session.workingDirectories.skip(1).toList(),
      readAdditional: _truthy(
        session.environment['CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD'],
      ),
    );
  }

  static bool _truthy(String? value) =>
      value != null && value.isNotEmpty && value != '0' && value != 'false';

  bool get loaded => _loaded;

  static String get _platform => switch (Platform.operatingSystem) {
    'macos' => 'darwin',
    'windows' => 'win32',
    final other => other,
  };

  static String get _osVersion {
    final version = Platform.operatingSystemVersion;
    return switch (Platform.operatingSystem) {
      'macos' => version.replaceFirst('Version ', 'Darwin '),
      _ => version,
    };
  }

  static String _date(DateTime now) =>
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  String _environment(String model) {
    final info = session.catalog.info(model);
    return environmentSection(
      cwd: session.cwd,
      additionalDirectories: session.workingDirectories.skip(1).toList(),
      isGitRepo: git != null,
      platform: _platform,
      osVersion: _osVersion,
      date: _date(DateTime.now()),
      modelName: info.known ? info.name : model,
      modelId: model,
      knowledgeCutoff: info.known ? _cutoffs[info.family] : null,
    );
  }

  static const _cutoffs = {
    'opus': 'June 2026',
    'sonnet': 'June 2026',
    'haiku': 'February 2026',
  };

  /// The main agent's system prompt, in blocks: the instructions, the
  /// environment, what the host and the MCP servers add.
  List<String> mainSystem() {
    final model = session.resolvedModel;
    final git = this.git;
    return [
      coreInstructions(productName: session.options.productName),
      [
        _environment(model),
        if (git != null)
          gitStatusSection(
            branch: git.branch,
            mainBranch: git.mainBranch,
            status: git.status,
            recentCommits: git.recentCommits,
          ),
      ].join('\n\n'),
      ?_outputStyle(),
      ?_mcpInstructions(),
      if (session.options.appendSystemPrompt case final extra?
          when extra.trim().isNotEmpty)
        extra,
    ];
  }

  String? _outputStyle() {
    final style = session.settings['outputStyle'];
    if (style is! String || style.isEmpty || style == 'default') return null;
    return switch (style.toLowerCase()) {
      'explanatory' =>
        '# Output style: explanatory\nAs you do the task, teach the user '
            'about it: why you chose to build it the way you did, and the '
            'patterns of their codebase you come across, in short '
            '"★ Insight" notes before and after the code you write.',
      'learning' =>
        '# Output style: learning\nThe user wants to learn by doing. Say '
            'why you do what you do, and leave small pieces of code that '
            'matter (5 to 10 lines) for them to write: mark each place with '
            'a TODO(human) comment and ask them to fill it in.',
      _ => null,
    };
  }

  String? _mcpInstructions() {
    final instructions = session.mcp.instructions;
    if (instructions == null) return null;
    return '# From the MCP servers\n\n'
        'What the connected MCP servers say of using their tools and '
        'resources:\n\n$instructions';
  }

  /// The context sent with the conversation's first message: the memory
  /// files, the date.
  String userContext({bool withMemory = true}) {
    final memory = withMemory ? _memoryText() : null;
    final out = StringBuffer(
      '<system-reminder>\nContext for this conversation:\n',
    );
    if (memory != null) {
      out
        ..writeln('# Instructions')
        ..writeln(
          'The user\'s and the project\'s instructions (CLAUDE.md files and '
          'rules). Follow them as they are written: where they differ from '
          'how you would work otherwise, they win.',
        )
        ..writeln()
        ..writeln(memory)
        ..writeln();
    }
    out
      ..writeln('# Date')
      ..writeln('Today is ${_date(DateTime.now())}.')
      ..writeln()
      ..writeln(
        'This is here in case it helps: do not bring it up unless it bears '
        'on the task.',
      )
      ..write('</system-reminder>\n');
    return out.toString();
  }

  String? _memoryText() {
    final files = [
      for (final file in session.memory)
        if (!file.conditional) file,
    ];
    if (files.isEmpty) return null;
    return [
      for (final file in files)
        '${file.path} (${file.description}):\n\n${file.content}',
    ].join('\n\n');
  }

  /// A subagent's system prompt: its own instructions, the notes for
  /// agents, the environment.
  List<String> agentSystem(AgentDefinition agent, String model) => [
    agent.prompt,
    'As an agent:\n'
        '- Each Bash call starts again in the working directory, so give '
        'absolute paths.\n'
        '- Your last message is your report. Name the files that matter by '
        'absolute path. Quote code only where its exact text is the point (a '
        'bug you found, a signature you were asked for), not to retell what '
        'you read.\n'
        '- No emoji.\n'
        '- Do not end a sentence with a colon just before a tool call.',
    _environment(model),
  ];

  /// Whether [agent]'s context leaves the memory files out (a quick
  /// read-only search does not need them).
  static bool omitsMemory(AgentDefinition agent) =>
      agent.source == 'built-in' &&
      (agent.name == 'Explore' || agent.name == 'Plan');

  /// The memory files in effect, for `/memory` and the context's report.
  List<MemoryFile> get memoryFiles => session.memory;
}
