import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/extensions.dart';
import '../config/settings.dart';
import '../engine/session.dart';
import '../util/cancel.dart';
import '../util/json.dart';
import '../util/processes.dart';

/// The events hooks run on.
abstract final class HookEvent {
  static const preToolUse = 'PreToolUse';
  static const postToolUse = 'PostToolUse';
  static const postToolUseFailure = 'PostToolUseFailure';
  static const permissionRequest = 'PermissionRequest';
  static const userPromptSubmit = 'UserPromptSubmit';
  static const notification = 'Notification';
  static const stop = 'Stop';
  static const subagentStart = 'SubagentStart';
  static const subagentStop = 'SubagentStop';
  static const preCompact = 'PreCompact';
  static const sessionStart = 'SessionStart';
  static const sessionEnd = 'SessionEnd';

  static const all = [
    preToolUse,
    postToolUse,
    postToolUseFailure,
    permissionRequest,
    userPromptSubmit,
    notification,
    stop,
    subagentStart,
    subagentStop,
    preCompact,
    sessionStart,
    sessionEnd,
  ];
}

/// One hook, where it was set.
class Hook {
  const Hook({
    required this.event,
    required this.type,
    required this.text,
    required this.source,
    this.matcher,
    this.timeout,
    this.model,
    this.plugin,
    this.evaluate,
  });

  final String event;

  /// `command` or `prompt`.
  final String type;

  /// The command run, or the prompt asked.
  final String text;

  /// `userSettings`, `projectSettings`, `localSettings`,
  /// `policySettings`, `flagSettings`, `pluginHook`, `sessionHook`.
  final String source;
  final String? matcher;
  final Duration? timeout;
  final String? model;
  final Plugin? plugin;

  /// A session's own prompt hook (the goal) answered its own way.
  final Future<HookResult> Function(
    Map<String, Object?> input,
    CancelToken cancel,
  )?
  evaluate;

  /// Whether it runs for [query] (a tool's name, a source, a trigger).
  bool matches(String? query) {
    final m = matcher?.trim() ?? '';
    if (m.isEmpty || m == '*' || query == null) return true;
    try {
      return RegExp('^(?:$m)\$').hasMatch(query);
    } on FormatException {
      return m == query;
    }
  }

  Map<String, Object?> toListing() => {
    'event': event,
    'source': source,
    'type': type,
    'commandText': text,
    'matcher': ?matcher,
    if (timeout != null) 'timeout': timeout!.inSeconds,
    if (plugin != null) 'pluginName': plugin!.name,
  };
}

/// What one hook said.
class HookResult {
  const HookResult({
    this.blocked = false,
    this.reason,
    this.decision,
    this.updatedInput,
    this.additionalContext,
    this.systemMessage,
    this.stop = false,
    this.stopReason,
    this.error,
    this.output,
    this.permissionRequest,
    this.hook,
  });

  /// Exit code 2, or `decision: block`.
  final bool blocked;

  /// Why it blocked (its stderr, or its `reason`).
  final String? reason;

  /// PreToolUse's `permissionDecision`: `allow`, `deny`, `ask`.
  final String? decision;
  final Map<String, Object?>? updatedInput;
  final String? additionalContext;

  /// Shown to the user.
  final String? systemMessage;

  /// `continue: false`: everything stops.
  final bool stop;
  final String? stopReason;

  /// A failure that does not block, shown to the user.
  final String? error;

  /// What it printed, when not JSON.
  final String? output;

  /// PermissionRequest's answer: `{behavior, updatedInput, message}`.
  final Map<String, Object?>? permissionRequest;

  /// The hook's command or prompt, to say which hook spoke.
  final String? hook;

  HookResult from(String hook) => HookResult(
    blocked: blocked,
    reason: reason,
    decision: decision,
    updatedInput: updatedInput,
    additionalContext: additionalContext,
    systemMessage: systemMessage,
    stop: stop,
    stopReason: stopReason,
    error: error,
    output: output,
    permissionRequest: permissionRequest,
    hook: hook,
  );
}

/// What the hooks of an event came to, together.
class HookOutcome {
  HookOutcome(this.results);

  final List<HookResult> results;

  bool get blocked => results.any((r) => r.blocked);

  String get blockReason => [
    for (final r in results)
      if (r.blocked && r.reason != null && r.reason!.trim().isNotEmpty)
        r.reason!.trim(),
  ].join('\n');

  /// What the blocking hooks said, each after its command or prompt:
  /// `[command]: why`.
  String get feedback => [
    for (final r in results)
      if (r.blocked) '[${r.hook ?? 'hook'}]: ${r.reason?.trim() ?? 'Blocked'}',
  ].join('\n');

  /// The strictest decision any said: deny over ask over allow.
  String? get decision {
    final said = {for (final r in results) ?r.decision};
    for (final d in const ['deny', 'ask', 'allow']) {
      if (said.contains(d)) return d;
    }
    return null;
  }

  String? get decisionReason => [
    for (final r in results)
      if (r.decision == decision && r.reason != null) r.reason!,
  ].join('\n').trim().nullIfEmpty;

  Map<String, Object?>? get updatedInput =>
      [for (final r in results) ?r.updatedInput].lastOrNull;

  List<String> get additionalContext => [
    for (final r in results)
      if (r.additionalContext case final c? when c.trim().isNotEmpty) c.trim(),
  ];

  List<String> get systemMessages => [
    for (final r in results)
      if (r.systemMessage case final m? when m.trim().isNotEmpty) m.trim(),
  ];

  List<String> get errors => [
    for (final r in results)
      if (r.error case final e? when e.trim().isNotEmpty) e.trim(),
  ];

  /// What hooks printed (not JSON) on events whose output is context.
  List<String> get outputs => [
    for (final r in results)
      if (r.output case final o? when o.trim().isNotEmpty) o.trim(),
  ];

  bool get stop => results.any((r) => r.stop);

  String? get stopReason => results
      .where((r) => r.stop)
      .map((r) => r.stopReason)
      .nonNulls
      .firstOrNull;

  Map<String, Object?>? get permissionRequest =>
      results.map((r) => r.permissionRequest).nonNulls.firstOrNull;

  static final empty = HookOutcome(const []);
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// Runs the hooks of the settings, the plugins and the session.
class HookRunner {
  HookRunner(this.session);

  final AgentSession session;

  /// The session's own (the goal).
  final List<Hook> sessionHooks = [];

  /// Every hook in effect.
  List<Hook> get hooks {
    final out = <Hook>[];
    for (final group in session.settings.hooks) {
      out.addAll(
        _fromGroup(group.event, group.matcher, group.hooks, group.source.wire),
      );
    }
    if (!session.settings.disableAllHooks) {
      for (final plugin in session.plugins) {
        for (final MapEntry(key: event, value: groups)
            in plugin.hooks.entries) {
          for (final group in asList(groups)) {
            final g = asMap(group);
            out.addAll(
              _fromGroup(
                event,
                asString(g['matcher']),
                [for (final h in asList(g['hooks'])) asMap(h)],
                'pluginHook',
                plugin: plugin,
              ),
            );
          }
        }
      }
    }
    out.addAll(sessionHooks);
    return out;
  }

  static List<Hook> _fromGroup(
    String event,
    String? matcher,
    List<Map<String, Object?>> hooks,
    String source, {
    Plugin? plugin,
  }) => [
    for (final hook in hooks)
      if (asString(hook['type']) case final type?
          when (type == 'command' && asText(hook['command']) != null) ||
              (type == 'prompt' && asText(hook['prompt']) != null))
        Hook(
          event: event,
          type: type,
          text: type == 'command'
              ? asText(hook['command'])!
              : asText(hook['prompt'])!,
          source: source,
          matcher: matcher,
          timeout: switch (asInt(hook['timeout'])) {
            final int seconds when seconds > 0 => Duration(seconds: seconds),
            _ => null,
          },
          model: asText(hook['model']),
          plugin: plugin,
        ),
  ];

  /// The listing `get_hooks_listing` answers with.
  Map<String, Object?> listing() => {
    'hooks': [for (final hook in hooks) hook.toListing()],
  };

  bool has(String event) => hooks.any((hook) => hook.event == event);

  /// Runs the hooks of [event] that match [query], with [input] (the
  /// fields of the event: the common ones are added).
  Future<HookOutcome> run(
    String event,
    Map<String, Object?> input, {
    String? query,
    CancelToken? cancel,
  }) async {
    final matching = <String, Hook>{};
    for (final hook in hooks) {
      if (hook.event != event || !hook.matches(query)) continue;
      // The same command set twice runs once.
      matching.putIfAbsent(
        '${hook.type}\u0000${hook.text}\u0000${hook.plugin?.root}',
        () => hook,
      );
    }
    if (matching.isEmpty) return HookOutcome.empty;
    final full = {
      'session_id': session.sessionId,
      'transcript_path': session.store.file ?? '',
      'cwd': session.cwd,
      'permission_mode': session.permissionMode,
      'hook_event_name': event,
      ...input,
    };
    final token = cancel ?? CancelToken();
    final results = await Future.wait([
      for (final hook in matching.values) _runOne(hook, full, token),
    ]);
    return HookOutcome(results);
  }

  Future<HookResult> _runOne(
    Hook hook,
    Map<String, Object?> input,
    CancelToken cancel,
  ) async {
    try {
      if (hook.evaluate case final evaluate?) {
        return (await evaluate(input, cancel)).from(hook.text);
      }
      final result = switch (hook.type) {
        'prompt' => await _prompt(hook, input, cancel),
        _ => await _command(hook, input, cancel),
      };
      return result.from(hook.text);
    } on Cancelled {
      rethrow;
    } on Object catch (error) {
      return HookResult(error: '${hook.event} hook failed: $error');
    }
  }

  Future<HookResult> _command(
    Hook hook,
    Map<String, Object?> input,
    CancelToken cancel,
  ) async {
    final shell = session.shell;
    final command = hook.plugin?.expand(hook.text) ?? hook.text;
    final process = await Process.start(
      shell.executable,
      shell.posix ? ['-c', command] : ['/d', '/s', '/c', command],
      workingDirectory: session.cwd,
      environment: {
        ...session.commandEnvironment,
        'CLAUDE_PROJECT_DIR': session.cwd,
        if (hook.plugin case final plugin?) 'CLAUDE_PLUGIN_ROOT': plugin.root,
      },
      includeParentEnvironment: false,
    );
    final stdout = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final stderr = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      process.stdin.write(jsonEncode(input));
      await process.stdin.close();
    } on Object {
      // A hook that reads nothing.
    }
    final timeout = hook.timeout ?? const Duration(seconds: 60);
    final ended = Completer<int?>();
    unawaited(
      process.exitCode.then((code) {
        if (!ended.isCompleted) ended.complete(code);
      }),
    );
    final timer = Timer(timeout, () {
      if (!ended.isCompleted) ended.complete(null);
    });
    unawaited(
      cancel.whenCancelled.then((_) {
        if (!ended.isCompleted) ended.complete(-1);
      }),
    );
    final code = await ended.future;
    timer.cancel();
    if (code == null || code == -1) {
      await killTree(process.pid);
      if (code == -1) throw Cancelled(cancel.reason);
      return HookResult(
        error:
            '${hook.event} hook timed out after ${timeout.inSeconds}s: $command',
      );
    }
    final out = (await stdout).trim();
    final err = (await stderr).trim();
    if (code == 2) {
      return HookResult(blocked: true, reason: err.isEmpty ? out : err);
    }
    if (code != 0) {
      return HookResult(
        error:
            '${hook.event} hook error (exit code $code): ${err.isEmpty ? out : err}',
      );
    }
    return parseOutput(hook.event, out);
  }

  /// A hook's printed [out] read as its answer: JSON when it is, else
  /// context for the events that take it.
  static HookResult parseOutput(String event, String out) {
    if (out.isEmpty) return const HookResult();
    Map<String, Object?>? json;
    if (out.startsWith('{')) {
      try {
        json = asMap(jsonDecode(out));
      } on FormatException {
        json = null;
      }
    }
    if (json == null) {
      return HookResult(
        additionalContext:
            event == HookEvent.userPromptSubmit ||
                event == HookEvent.sessionStart
            ? out
            : null,
        output: out,
      );
    }
    final specific = asMap(json['hookSpecificOutput']);
    final legacy = asString(json['decision']);
    var decision = asString(specific['permissionDecision']);
    // The older words for it.
    if (decision == null && event == HookEvent.preToolUse) {
      decision = switch (legacy) {
        'approve' => 'allow',
        'block' => 'deny',
        _ => null,
      };
    }
    final blocked =
        legacy == 'block' &&
        event != HookEvent.preToolUse &&
        event != HookEvent.permissionRequest;
    return HookResult(
      blocked: blocked,
      reason:
          asString(specific['permissionDecisionReason']) ??
          asString(json['reason']),
      decision: decision,
      updatedInput: switch (specific['updatedInput']) {
        final Map<Object?, Object?> input => input.cast<String, Object?>(),
        _ => null,
      },
      additionalContext: asString(specific['additionalContext']),
      systemMessage: asString(json['systemMessage']),
      stop: json['continue'] == false,
      stopReason: asString(json['stopReason']),
      permissionRequest: switch (specific['decision']) {
        final Map<Object?, Object?> d => d.cast<String, Object?>(),
        _ => null,
      },
    );
  }

  Future<HookResult> _prompt(
    Hook hook,
    Map<String, Object?> input,
    CancelToken cancel,
  ) async {
    final prompt = hook.text.contains(r'$ARGUMENTS')
        ? hook.text.replaceAll(r'$ARGUMENTS', jsonEncode(input))
        : '${hook.text}\n\nHook input:\n${jsonEncode(input)}';
    final answer = await session.quickQuery(
      system:
          'You are evaluating a hook in a coding agent. Answer with a JSON '
          'object only, no other text: {"ok": true} when the condition '
          'holds or the action should go ahead, or {"ok": false, "reason": '
          '"why"} when it should not.',
      prompt: prompt,
      model: hook.model,
      cancel: cancel,
      maxTokens: 1024,
    );
    final json = extractJson(answer);
    final ok = json['ok'] == true || json['decision'] == 'approve';
    final reason = asString(json['reason']);
    if (ok) return HookResult(systemMessage: asString(json['systemMessage']));
    return switch (hook.event) {
      HookEvent.preToolUse => HookResult(decision: 'deny', reason: reason),
      _ => HookResult(
        blocked: true,
        reason: reason ?? 'Blocked by a prompt hook',
      ),
    };
  }
}

/// The first JSON object in [text] (a model's answer, maybe fenced).
Map<String, Object?> extractJson(String text) {
  final start = text.indexOf('{');
  final end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return const {};
  try {
    return asMap(jsonDecode(text.substring(start, end + 1)));
  } on FormatException {
    return const {};
  }
}

/// A hook's source as settings name it.
String sourceName(SettingsSource source) => source.wire;
