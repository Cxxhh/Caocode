import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/extensions.dart';
import '../engine/agent_loop.dart';
import '../engine/agent_run.dart';
import '../engine/context.dart';
import '../engine/session.dart';
import '../engine/session_store.dart';
import '../engine/tasks.dart';
import '../hooks/hooks.dart';
import '../permissions/decision.dart';
import '../util/cancel.dart';
import '../util/json.dart';
import 'file_state.dart';
import 'tool.dart';

/// Starts a subagent on a task of its own: it works with its own context
/// and tools, and answers with its report (or works in the background and
/// tells of it when done).
class AgentTool extends Tool {
  const AgentTool();

  @override
  String get name => 'Agent';

  @override
  List<String> get aliases => const ['Task'];

  @override
  String get description =>
      'Hands a task to an agent of its own, which does it and reports back.';

  @override
  String promptFor(AgentSession session) {
    final agents = [
      for (final agent in session.agentDefinitions)
        '- ${agent.name}: ${agent.description} (Tools: ${_toolsOf(agent)})',
    ].join('\n');
    return '''Hands a task to an agent of its own: it works on it alone, with a context and tools of its own, and gives you back one report when done.

The kinds of agent there are, and the tools each has:
$agents

Pick one with subagent_type; without it, general-purpose does the work.

An agent is worth it for a task that takes many steps, or a search that may take many rounds; not for what one call does sooner:
- a file whose path you know: Read it;
- a definition you can name ("class Foo"): Glob or Grep for it;
- code in two or three files you know: Read them.
Nor for work that fits none of the kinds above.

- Give it a short description (3 to 5 words) of what it is to do.
- It knows nothing of this conversation: say in the prompt all it needs, what to look into or change, and whether it is to write code or only to find things out.
- Agents whose work does not overlap can run at once, in calls side by side in one reply.
- Its report comes to you, not to the user: tell the user what matters in it, briefly.
- What an agent reports can generally be trusted.
- With run_in_background it works while you go on, and you are told when it is done: do not wait for it, sleep or look in on it meanwhile.
- With resume and an agent's ID, an agent from before goes on with all it had; without, each starts afresh.
- A kind whose description says to use it unasked should be used when it fits, without waiting to be asked.''';
  }

  static String _toolsOf(AgentDefinition agent) {
    final tools = agent.tools;
    if (tools == null) {
      return agent.disallowedTools.isEmpty
          ? '*'
          : 'All tools except ${agent.disallowedTools.join(', ')}';
    }
    return tools.join(', ');
  }

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'description': {
        'type': 'string',
        'description': 'What it is to do, in 3 to 5 words',
      },
      'prompt': {
        'type': 'string',
        'description': 'The task, with all the agent needs to know for it',
      },
      'subagent_type': {
        'type': 'string',
        'description':
            'The kind of agent to do it (general-purpose if left out)',
      },
      'model': {
        'type': 'string',
        'enum': ['sonnet', 'opus', 'haiku'],
        'description': 'The model it runs on, if not the one you run on: haiku is cheaper and quicker for a simple task',
      },
      'run_in_background': {
        'type': 'boolean',
        'description':
            'Let it work while you go on: you are told when it is done',
      },
      'resume': {
        'type': 'string',
        'description':
            'The ID of an agent from before, to go on with all it had',
      },
    },
    'required': ['description', 'prompt'],
    'additionalProperties': false,
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => true;

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  String? describe(Map<String, Object?> input) => asText(input['description']);

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final type = asText(input['subagent_type']);
    if (type != null && _definition(context.session, type) == null) {
      final names = [for (final a in context.session.agentDefinitions) a.name];
      return "There is no agent of the kind '$type'. The kinds there are: "
          "${names.join(', ')}";
    }
    if (asText(input['resume']) case final id?) {
      final file = _sidechainFile(context.session, id);
      if (file == null || !File(file).existsSync()) {
        return 'There is no agent from before with the ID $id.';
      }
    }
    return null;
  }

  static AgentDefinition? _definition(AgentSession session, String type) {
    for (final agent in session.agentDefinitions) {
      if (agent.name == type) return agent;
    }
    // As the model may write it: `explore` for `Explore`.
    for (final agent in session.agentDefinitions) {
      if (agent.name.toLowerCase() == type.toLowerCase()) return agent;
    }
    return null;
  }

  static String? _sidechainFile(AgentSession session, String agentId) {
    final main =
        session.store.file ??
        session.paths.sessionFile(session.cwd, session.sessionId);
    return sidechainFile(main, agentId);
  }

  /// The model [agent] works with, as an id.
  static String modelFor(
    AgentSession session,
    AgentDefinition agent,
    String? asked,
  ) {
    final env = session.environment;
    final subagent = asText(env['CLAUDE_CODE_SUBAGENT_MODEL']);
    final force = asText(env['CLAUDE_CODE_SUBAGENT_MODEL_FORCE']);
    final forced = force != null && force != '0' && force != 'false';
    final alias = forced && subagent != null && agent.model != 'inherit'
        ? subagent
        : asked ?? agent.model ?? subagent;
    if (alias == null || alias == 'inherit') return session.resolvedModel;
    return session.catalog.resolve(alias);
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final session = context.session;
    if (!context.run.isMain) {
      return ToolOutput.error('An agent cannot start agents of its own.');
    }
    final resumeId = asText(input['resume']);
    final meta = resumeId == null ? null : _readMeta(session, resumeId);
    final type =
        asText(input['subagent_type']) ??
        asString(meta?['agentType']) ??
        'general-purpose';
    final agent = _definition(session, type) ?? builtInAgents.first;
    final description = asText(input['description']) ?? agent.name;
    final prompt = '${input['prompt'] ?? ''}';
    final model = modelFor(session, agent, asText(input['model']));
    final background = input['run_in_background'] == true;
    final agentId = resumeId ?? session.tasks.newId('a');
    final job = _Job(
      session: session,
      agent: agent,
      agentId: agentId,
      description: description,
      prompt: prompt,
      model: model,
      toolUseId: context.toolUseId,
      resumed: resumeId != null,
      parentReads: context.run.readFiles,
    );
    final task = session.tasks.registerAgent(
      description: description,
      agentId: agentId,
      toolUseId: context.toolUseId,
      agentType: agent.name,
      background: background,
    );
    // In the foreground it stops with the turn; sent to the background,
    // it goes on.
    unawaited(
      context.cancel.whenCancelled.then((_) {
        if (!task.backgrounded) task.cancel.cancel('interrupted');
      }),
    );
    final done = job.start(task);
    if (!background) {
      final outcome = await Future.any<Object?>([
        done,
        task.toBackground.future.then((_) => _sentAway),
      ]);
      if (outcome is _Outcome) return outcome.output(job, task);
      // Sent to the background: it tells of itself once done.
    }
    return _launched(job, task);
  }

  static const _sentAway = #sentAway;

  static Map<String, Object?>? _readMeta(AgentSession session, String agentId) {
    final file = _sidechainFile(session, agentId);
    if (file == null) return null;
    try {
      return asMap(jsonDecode(File(_metaPath(file)).readAsStringSync()));
    } on Object {
      return null;
    }
  }

  static String _metaPath(String sidechain) => p.join(
    p.dirname(sidechain),
    '${p.basenameWithoutExtension(sidechain)}.meta.json',
  );

  ToolOutput _launched(_Job job, BackgroundTask task) => ToolOutput(
    'The agent has started in the background, and you will be told when it '
    'is done.\n'
    'agentId: ${job.agentId} (for you, not the user: give it to resume to '
    'have this agent go on later)\n'
    'Leave its work to it: keep off the files and questions it is on. Do '
    'something else, or tell the user briefly what you started and stop '
    'there.\n'
    'output_file: ${task.outputFile}\n'
    'To see how far it is before then, if asked, call TaskOutput with '
    'task_id ${job.agentId}.',
    result: {
      'status': 'async_launched',
      'agentId': job.agentId,
      'description': job.description,
      'prompt': job.prompt,
      'outputFile': task.outputFile,
      'resolvedModel': job.model,
    },
  );
}

/// How a subagent's work came out.
class _Outcome {
  _Outcome(this.result, this.duration);

  final LoopResult result;
  final Duration duration;

  ToolOutput output(_Job job, BackgroundTask task) {
    final text = result.lastText;
    final tokens = job.run?.tokens ?? 0;
    final calls = job.run?.toolUses ?? 0;
    final structured = {
      'status': result.ok ? 'completed' : result.reason,
      'agentId': job.agentId,
      'agentType': job.agent.name,
      'prompt': job.prompt,
      'content': [
        {'type': 'text', 'text': text},
      ],
      'totalDurationMs': duration.inMilliseconds,
      'totalTokens': tokens,
      'totalToolUseCount': calls,
      'usage': result.usage,
      'resolvedModel': job.model,
    };
    if (!result.ok && result.reason != 'max_turns') {
      return ToolOutput.error(
        result.error ??
            (result.reason == 'interrupted'
                ? '[Request interrupted by user for tool use]'
                : 'The agent stopped before it finished (${result.reason}).'),
        result: structured,
      );
    }
    return ToolOutput([
      {
        'type': 'text',
        'text': text.isEmpty ? '(The agent gave no report.)' : text,
      },
      {
        'type': 'text',
        'text':
            'agentId: ${job.agentId} (give it to resume to have this agent go on)\n'
            '<usage>total_tokens: $tokens\ntool_uses: $calls\n'
            'duration_ms: ${duration.inMilliseconds}</usage>',
      },
    ], result: structured);
  }
}

/// One subagent's work: its conversation, kept beside the session's.
class _Job {
  _Job({
    required this.session,
    required this.agent,
    required this.agentId,
    required this.description,
    required this.prompt,
    required this.model,
    required this.toolUseId,
    required this.resumed,
    required this.parentReads,
  });

  final AgentSession session;
  final AgentDefinition agent;
  final String agentId;
  final String description;
  final String prompt;
  final String model;
  final String toolUseId;
  final bool resumed;
  final ReadFileState parentReads;
  AgentRun? run;

  SessionStore _store() {
    final file = session.store.file == null
        ? null
        : sidechainFile(session.store.file!, agentId);
    if (resumed && file != null) {
      return SessionStore.resume(
        sessionId: session.sessionId,
        cwd: session.cwd,
        file: file,
        gitBranch: session.store.gitBranch,
        sidechain: true,
      );
    }
    if (file != null && !resumed) {
      try {
        final meta = File(AgentTool._metaPath(file));
        meta.parent.createSync(recursive: true);
        meta.writeAsStringSync(
          jsonEncode({'agentType': agent.name, 'description': description}),
        );
      } on FileSystemException {
        // Kept without: a resume takes the general-purpose agent.
      }
    }
    return SessionStore(
      sessionId: session.sessionId,
      cwd: session.cwd,
      file: file,
      gitBranch: session.store.gitBranch,
    );
  }

  /// Runs it to the end, [task] kept up to date.
  Future<_Outcome> start(BackgroundTask task) async {
    final started = DateTime.now();
    final store = _store();
    final run = this.run = AgentRun(
      session: session,
      agentId: agentId,
      parentToolUseId: toolUseId,
      agentType: agent.name,
      modeOverride: agent.permissionMode,
      readFiles: parentReads.copy(),
    );
    run.onToolUse = (tool) {
      task
        ..toolUses = run.toolUses
        ..tokens = run.tokens;
      session.tasks.agentProgress(task, lastTool: tool, summary: description);
    };
    LoopResult result;
    try {
      var text = prompt;
      if (session.hooks.has(HookEvent.subagentStart)) {
        final hook = await session.hooks.run(
          HookEvent.subagentStart,
          {'agent_id': agentId, 'agent_type': agent.name},
          query: agent.name,
          cancel: task.cancel,
        );
        if (hook.additionalContext.isNotEmpty) {
          text =
              '$text\n\n<system-reminder>\n${hook.additionalContext.join('\n')}\n</system-reminder>';
        }
      }
      final entry = store.append({
        'type': 'user',
        'message': {'role': 'user', 'content': text},
        'isSidechain': true,
        'agentId': agentId,
        if (!resumed) 'parentUuid': null,
      });
      session.emit({
        'type': 'user',
        'message': entry['message'],
        'parent_tool_use_id': toolUseId,
        'uuid': entry['uuid'],
      });
      final loop = AgentLoop(
        session: session,
        run: run,
        store: store,
        tools: session.toolbox.forAgent(agent),
        system: session.context.agentSystem(agent, model),
        model: model,
        userContext: SessionContext.omitsMemory(agent)
            ? null
            : session.context.userContext(),
      );
      result = await loop.runTurn(task.cancel);
    } on Cancelled {
      result = const LoopResult(
        reason: 'interrupted',
        lastText: '',
        requests: 0,
        usage: {},
        apiDuration: Duration.zero,
      );
    } on Object catch (error) {
      result = LoopResult(
        reason: 'error',
        lastText: '',
        requests: 0,
        usage: const {},
        apiDuration: Duration.zero,
        error: 'Error: $error',
      );
    }
    task
      ..toolUses = run.toolUses
      ..tokens = run.tokens;
    final report = result.lastText;
    try {
      File(task.outputFile)
          .writeAsStringSync(report.isEmpty ? (result.error ?? '') : report);
    } on FileSystemException {
      // The notification carries it all the same.
    }
    if (!result.ok) task.error = result.error ?? result.reason;
    session.tasks.finish(task, switch (result.reason) {
      'end_turn' || 'max_turns' || 'stopped' => TaskStatus.completed,
      'interrupted' => TaskStatus.killed,
      _ => TaskStatus.failed,
    }, result: report);
    return _Outcome(result, DateTime.now().difference(started));
  }
}
