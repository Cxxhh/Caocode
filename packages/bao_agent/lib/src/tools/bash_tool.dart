import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../engine/session.dart';
import '../engine/tasks.dart';
import '../permissions/decision.dart';
import '../permissions/shell_command.dart';
import '../util/ids.dart';
import '../util/json.dart';
import '../util/processes.dart';
import 'tool.dart';

/// Runs a shell command.
class BashTool extends Tool {
  const BashTool();

  static const defaultTimeout = Duration(minutes: 2);
  static const maxTimeout = Duration(minutes: 10);
  static const defaultMaxOutput = 30000;

  @override
  String get name => 'Bash';

  @override
  String get description => 'Runs a shell command and returns what it printed.';

  /// What the model is told of it, with the session's commit trailer.
  @override
  String promptFor(AgentSession session) {
    final attribution = session.attribution;
    final trailer = attribution.commit.isEmpty
        ? ''
        : '\n\n   ${attribution.commit}';
    final prLine = attribution.pr.isEmpty ? '' : '\n\n${attribution.pr}';
    return '''Runs a command in a shell and gives back what it printed.

Each call gets a fresh shell, in the directory the one before it ended in: variables, aliases and functions do not carry over. The environment is the user's login shell's.

Use it for what needs a shell: builds, tests, package managers, git, docker, scripts. Files have tools of their own, which do it better and which the user can follow: Read to look at a file (not cat, head or tail), Edit and Write to change one (not sed, awk, echo or heredocs), Glob and Grep to find and search files (not find, ls -R, grep or rg). Tell the user things in your reply, not with echo.

- Give a short description of what the command does, in about 5 to 10 words: the user sees it in place of the command.
- A command is stopped after ${defaultTimeout.inMinutes} minutes, or after `timeout` milliseconds (at most ${maxTimeout.inMinutes} minutes).
- Output beyond $defaultMaxOutput characters is cut.
- Quote paths with spaces in them ("my dir/file.txt"). Before creating a file or a folder, make sure its parent exists and is the one you mean.
- Prefer absolute paths to `cd`, so the directory stays where it is; change it only when the user asks.
- Commands that do not depend on each other can be separate calls in one response, run side by side. Chain those that do in one call with `&&` (with `;` when a failure should not stop the rest); never separate them with newlines.
- `run_in_background` starts a command you need not wait for (a server, a long build): you are told when it ends, and read what it printed with TaskOutput or from its output file. It needs no `&`.
- Nothing interactive works: no `git rebase -i` or `git add -i`, no editor waiting for input.

# Git commits

Commit only when the user asks you to; if you are not sure they did, ask. Then:
1. Look at the state first, in parallel: `git status` (untracked files too), `git diff` (staged and not), and `git log`, for how this repository words its messages.
2. Leave out files that may hold secrets (.env, credentials, keys), and say so if the user asked for them.
3. Write a message in the repository's style, a sentence or two on why the change was made rather than only what it is. Stage the files that belong to it, commit, and check with `git status` that it worked.
4. If a pre-commit hook fails, fix what it found and commit again, anew: the failed commit never happened, so amending would change the one before it.

Never change the git config, never skip hooks (--no-verify) or signing, and run nothing that cannot be undone (push --force, reset --hard, deleting a branch) unless the user asks; warn them before a force-push to main or master. Amend only when asked. With nothing to commit, make no empty commit.

Pass the message through a heredoc, so that it keeps its lines:
<example>
git commit -F - <<'MSG'
The message.$trailer
MSG
</example>

# Pull requests

Use `gh` for everything on GitHub: issues, pull requests, checks, releases, and links to any of them. To open a pull request, first see what the branch holds: `git status`, `git diff`, whether it tracks a remote and is pushed, and `git log` with `git diff <base>...HEAD` for every commit since it left its base. Write a title and a summary that cover all of those commits, push the branch if it needs it, and create the pull request with its body in a heredoc:
<example>
gh pr create --title "The title" --body-file - <<'BODY'
## What changed
<one to three points>

## How it was checked
<the tests run, by hand or not>$prLine
BODY
</example>
End with the pull request's URL, for the user to open.''';
  }

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'command': {'type': 'string', 'description': 'The command to run'},
      'timeout': {
        'type': 'number',
        'description': 'How long it may run, in milliseconds (at most 600000)',
      },
      'description': {
        'type': 'string',
        'description': 'What the command does, in 5 to 10 words: the user sees it in place of the command',
      },
      'run_in_background': {
        'type': 'boolean',
        'description': 'Start it and go on without waiting; read its output later with TaskOutput',
      },
      'dangerouslyDisableSandbox': {
        'type': 'boolean',
        'description': 'Run it outside the sandbox, where there is one',
      },
    },
    'required': ['command'],
    'additionalProperties': false,
  };

  @override
  bool isReadOnly(Map<String, Object?> input) =>
      isReadOnlyCommand('${input['command'] ?? ''}');

  @override
  String? describe(Map<String, Object?> input) =>
      asString(input['description']);

  @override
  String? ruleContent(Map<String, Object?> input) => asString(input['command']);

  /// How long a command runs in the foreground before it is shown as a
  /// task.
  static const foregroundTaskAfter = Duration(seconds: 1);

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => context.session.permissions.checkBash(
    '${input['command'] ?? ''}',
    context.cwd,
    context.run.permissionMode,
  );

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final command = '${input['command'] ?? ''}';
    if (command.trim().isEmpty) return 'command must not be empty';
    // A `sleep` alone, waited on, only wastes the user's time.
    final sleep = RegExp(r'^\s*sleep\s+(\d+)\s*$').firstMatch(command);
    if (sleep != null &&
        int.parse(sleep[1]!) > 120 &&
        input['run_in_background'] != true) {
      return 'Blocked: a long `sleep` on its own. Run what you are waiting '
          'for in the background and you will be told when it finishes.';
    }
    return null;
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final session = context.session;
    final command = '${input['command']}';
    final description =
        asText(input['description']) ??
        (command.length > 60 ? '${command.substring(0, 60)}…' : command);
    if (input['run_in_background'] == true) {
      final task = await session.tasks.startShell(
        command: command,
        description: description,
        cwd: context.cwd,
        toolUseId: context.toolUseId,
      );
      return _backgroundOutput(task);
    }
    final timeout = _timeout(input, session);
    final shell = session.shell;
    final cwdFile = p.join(
      Directory.systemTemp.path,
      'bao-cwd-${randomId(10)}',
    );
    final Process process;
    try {
      process = await Process.start(
        shell.executable,
        shell.arguments(command, cwdFile),
        workingDirectory: Directory(context.cwd).existsSync()
            ? context.cwd
            : session.cwd,
        environment: session.commandEnvironment,
        includeParentEnvironment: false,
      );
    } on ProcessException catch (error) {
      return ToolOutput.error(
        'Could not start ${shell.executable}: ${error.message}',
      );
    }
    unawaited(process.stdin.close().catchError((_) {}));
    final running = ForegroundCommand(
      process: process,
      command: command,
      description: description,
      toolUseId: context.toolUseId,
    );
    session.tasks.foreground[context.toolUseId] = running;
    // Shown as a task once it has gone on a while: one the user can send
    // to the background.
    final shown = Timer(foregroundTaskAfter, () {
      if (running.task == null) session.tasks.registerForeground(running);
    });
    final streams = Future.wait([
      process.stdout.listen(running.addStdout).asFuture<void>(),
      process.stderr.listen(running.addStderr).asFuture<void>(),
    ]);
    var timedOut = false;
    var interrupted = false;
    final ended = Completer<String>();
    unawaited(
      process.exitCode.then((_) {
        if (!ended.isCompleted) ended.complete('exit');
      }),
    );
    final timer = Timer(timeout, () {
      if (!ended.isCompleted) ended.complete('timeout');
    });
    unawaited(
      context.cancel.whenCancelled.then((_) {
        if (!ended.isCompleted) ended.complete('cancel');
      }),
    );
    unawaited(
      running.backgrounded.then((_) {
        if (!ended.isCompleted) ended.complete('background');
      }),
    );
    final how = await ended.future;
    timer.cancel();
    shown.cancel();
    switch (how) {
      case 'background':
        session.tasks.foreground.remove(context.toolUseId);
        final task = running.task!;
        unawaited(() async {
          final code = await process.exitCode;
          await streams.catchError((_) => <void>[]);
          await running.closeSink();
          task.exitCode = code;
          session.tasks.finish(
            task,
            task.status == TaskStatus.killed
                ? TaskStatus.killed
                : code == 0
                ? TaskStatus.completed
                : TaskStatus.failed,
          );
        }());
        return _backgroundOutput(task);
      case 'timeout':
        timedOut = true;
        await killTree(process.pid);
      case 'cancel':
        interrupted = true;
        await killTree(process.pid);
    }
    final code = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        Process.killPid(process.pid, ProcessSignal.sigkill);
        return -9;
      },
    );
    await streams
        .timeout(const Duration(seconds: 2), onTimeout: () => [])
        .catchError((_) => <void>[]);
    session.tasks.foreground.remove(context.toolUseId);
    if (running.registered case final task?) {
      task.exitCode = code;
      session.tasks.finish(
        task,
        interrupted || timedOut || task.status == TaskStatus.killed
            ? TaskStatus.killed
            : code == 0
            ? TaskStatus.completed
            : TaskStatus.failed,
      );
    }
    final cwdNote = _followCwd(cwdFile, context);
    final maxOutput =
        asInt(session.environment['BASH_MAX_OUTPUT_LENGTH']) ??
        defaultMaxOutput;
    final stdout = _truncate(_trimEnd(running.stdout.toString()), maxOutput);
    final stderr = _truncate(_trimEnd(running.stderr.toString()), maxOutput);
    final parts = <String>[
      if (stdout.isNotEmpty) stdout,
      if (stderr.isNotEmpty) stderr,
    ];
    var text = parts.join('\n');
    if (timedOut) {
      text = [
        if (text.isNotEmpty) text,
        'Command timed out after ${_seconds(timeout)}',
      ].join('\n');
    } else if (interrupted) {
      text = [if (text.isNotEmpty) text, 'Command was interrupted'].join('\n');
    } else if (code != 0) {
      text = ['Exit code $code', if (text.isNotEmpty) text].join('\n');
    }
    if (cwdNote != null) text = [if (text.isNotEmpty) text, cwdNote].join('\n');
    final isError = timedOut || interrupted || code != 0;
    return ToolOutput(
      text.isEmpty ? '(Bash completed with no output)' : text,
      isError: isError,
      result: {
        'stdout': stdout,
        'stderr': stderr,
        'interrupted': timedOut || interrupted,
        'isImage': false,
        'exitCode': code,
        if (timedOut) 'timedOut': true,
      },
    );
  }

  static ToolOutput _backgroundOutput(BackgroundTask task) => ToolOutput(
    'Command running in background with ID: ${task.id}. Output is being '
    'written to: ${task.outputFile}. You will be notified when it finishes; '
    'you can check on it with the TaskOutput tool.',
    result: {
      'stdout': '',
      'stderr': '',
      'interrupted': false,
      'isImage': false,
      'backgroundTaskId': task.id,
      'outputFile': task.outputFile,
    },
  );

  static Duration _timeout(Map<String, Object?> input, AgentSession session) {
    final env = session.environment;
    final defaultMs =
        asInt(env['BASH_DEFAULT_TIMEOUT_MS']) ?? defaultTimeout.inMilliseconds;
    final maxMs =
        asInt(env['BASH_MAX_TIMEOUT_MS']) ??
        (defaultMs > maxTimeout.inMilliseconds
            ? defaultMs
            : maxTimeout.inMilliseconds);
    final asked = asInt(input['timeout']) ?? defaultMs;
    return Duration(milliseconds: asked.clamp(1000, maxMs));
  }

  static String _seconds(Duration duration) =>
      duration.inMinutes >= 1 && duration.inSeconds % 60 == 0
      ? '${duration.inMinutes}m'
      : '${duration.inSeconds}s';

  /// Moves the agent's shell to where the command left it, inside the
  /// working folders; elsewhere, back to the project, and says so.
  static String? _followCwd(String cwdFile, ToolContext context) {
    final file = File(cwdFile);
    String? ended;
    try {
      if (file.existsSync()) ended = file.readAsStringSync().trim();
    } on FileSystemException {
      ended = null;
    }
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Left in the temp folder.
    }
    if (ended == null || ended.isEmpty) return null;
    final permissions = context.session.permissions;
    if (permissions.inWorkingDirectories(ended) ||
        _sameDirectory(ended, context.cwd)) {
      context.run.cwd = ended;
      return null;
    }
    final project = context.session.cwd;
    context.run.cwd = project;
    return 'Shell cwd was reset to $project';
  }

  static bool _sameDirectory(String a, String b) {
    try {
      return Directory(a).resolveSymbolicLinksSync() ==
          Directory(b).resolveSymbolicLinksSync();
    } on FileSystemException {
      return false;
    }
  }

  static String _trimEnd(String text) => text.replaceFirst(RegExp(r'\s+$'), '');

  /// [text] cut to [max] characters, from its middle.
  static String _truncate(String text, int max) {
    if (text.length <= max) return text;
    final head = text.substring(0, max ~/ 2);
    final tail = text.substring(text.length - max ~/ 2);
    final dropped = '\n'
        .allMatches(text.substring(max ~/ 2, text.length - max ~/ 2))
        .length;
    return '$head\n\n... [$dropped lines truncated] ...\n\n$tail';
  }
}

/// Reads what a background task has written.
class TaskOutputTool extends Tool {
  const TaskOutputTool();

  @override
  String get name => 'TaskOutput';

  @override
  List<String> get aliases => const ['BashOutput', 'AgentOutputTool'];

  @override
  String get description => '''Reads what a background task has produced (a shell started with run_in_background, or an agent sent to the background), and whether it is still running. For a shell, only what it printed since the last read comes back.

By default it waits for the task to end, for up to `timeout` milliseconds; with block set to false it looks without waiting.''';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'task_id': {'type': 'string', 'description': 'The task\'s ID'},
      'bash_id': {'type': 'string', 'description': 'Older name of task_id'},
      'block': {
        'type': 'boolean',
        'description': 'Wait for the task to end',
        'default': true,
      },
      'timeout': {
        'type': 'number',
        'description': 'The longest to wait, in milliseconds',
        'default': 30000,
      },
      'filter': {
        'type': 'string',
        'description':
            'A regular expression: only the lines that match it come back',
      },
    },
    'additionalProperties': false,
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final id = asText(input['task_id']) ?? asText(input['bash_id']);
    if (id == null) return 'task_id is required';
    if (context.session.tasks[id] == null) return 'No task found with ID: $id';
    return null;
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final id = asText(input['task_id']) ?? asText(input['bash_id'])!;
    final task = context.session.tasks[id]!;
    if (input['block'] != false && task.status == TaskStatus.running) {
      final wait = Duration(
        milliseconds: (asInt(input['timeout']) ?? 30000).clamp(0, 600000),
      );
      await context.cancel.guard(task.done.timeout(wait, onTimeout: () {}));
    }
    final all = task.output();
    var fresh = task.isShell
        ? all.substring(task.readOffset.clamp(0, all.length))
        : all;
    task.readOffset = all.length;
    if (asText(input['filter']) case final filter?) {
      try {
        final regExp = RegExp(filter);
        fresh = fresh.split('\n').where(regExp.hasMatch).join('\n');
      } on FormatException catch (error) {
        return ToolOutput.error('Invalid filter: ${error.message}');
      }
    }
    if (!task.isShell && task.result != null) fresh = task.result!;
    final text = StringBuffer()
      ..writeln('<task_id>$id</task_id>')
      ..writeln('<task_type>${task.type}</task_type>')
      ..writeln('<status>${task.status.name}</status>');
    if (task.exitCode != null) {
      text.writeln('<exit_code>${task.exitCode}</exit_code>');
    }
    text.write(
      fresh.trim().isEmpty
          ? '<output>(no new output)</output>'
          : '<output>\n${fresh.trimRight()}\n</output>',
    );
    return ToolOutput(
      text.toString(),
      result: {
        'retrieval_status': task.status == TaskStatus.running
            ? 'timeout'
            : 'success',
        'task': {
          'task_id': id,
          'task_type': task.type,
          'status': task.status.name,
          'description': task.description,
          'output': fresh,
          'exitCode': task.exitCode,
        },
      },
    );
  }
}

/// Stops a background task.
class TaskStopTool extends Tool {
  const TaskStopTool();

  @override
  String get name => 'TaskStop';

  @override
  List<String> get aliases => const ['KillShell', 'KillBash'];

  @override
  String get description =>
      'Stops a background task, a shell or an agent, by its ID: one that runs '
      'too long or is no longer needed. Says whether it was stopped.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'task_id': {
        'type': 'string',
        'description': 'The ID of the task to stop',
      },
      'shell_id': {'type': 'string', 'description': 'Older name of task_id'},
    },
    'additionalProperties': false,
  };

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final id = asText(input['task_id']) ?? asText(input['shell_id']);
    if (id == null) return ToolOutput.error('task_id is required');
    final task = context.session.tasks[id];
    if (task == null) return ToolOutput.error('No task found with ID: $id');
    if (task.status.done) {
      return ToolOutput.error(
        'Task $id is not running (it is ${task.status.name}).',
      );
    }
    await context.session.tasks.stop(id);
    return ToolOutput(
      'Successfully stopped task: $id (${task.description})',
      result: {
        'message': 'Successfully stopped task: $id',
        'task_id': id,
        'task_type': task.type,
        'command': task.command ?? task.description,
      },
    );
  }
}
