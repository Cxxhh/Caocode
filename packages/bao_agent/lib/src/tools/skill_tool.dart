import '../config/extensions.dart';
import '../config/settings.dart';
import '../engine/session.dart';
import '../permissions/decision.dart';
import '../util/json.dart';
import 'tool.dart';

/// Takes up a skill (or a command the model may run): its instructions
/// follow the call, for the model to carry out.
class SkillTool extends Tool {
  const SkillTool();

  @override
  String get name => 'Skill';

  @override
  String get description =>
      'Loads a skill\'s instructions into this conversation.';

  /// The skills and commands the model may use.
  static List<PromptCommand> available(AgentSession session) => [
    for (final command in session.promptCommands)
      if (command.modelInvocable &&
          (command.isSkill || command.description.isNotEmpty))
        command,
  ];

  @override
  bool isEnabled(AgentSession session) => available(session).isNotEmpty;

  @override
  String promptFor(AgentSession session) {
    final listing = [
      for (final command in available(session))
        '- ${command.name}: ${command.description}'
            '${command.whenToUse == null ? '' : ' - ${command.whenToUse}'}',
    ].join('\n');
    return '''Loads a skill into this conversation: its instructions come in, and you follow them here.

A skill brings know-how or a way of working for some kind of task. Before taking on a task, see whether one of those below fits it. A "slash command", "/<name>" ("/commit", "/review-pr"), is a skill too, called this way.

- Call it with the skill's name, and args for what the user said after it: `skill: "pdf"`, `skill: "commit", args: "-m 'Fix bug'"`. A plugin's skill can be named with its plugin: `skill: "office:pdf"`.
- When one fits what the user asks, load it first, before saying or doing anything else about the task.
- Do not speak of a skill as used without calling this tool.
- One already loaded is not loaded again: a <command-name> tag in this turn means it is here already, so follow its instructions.

The skills there are:
$listing''';
  }

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'skill': {
        'type': 'string',
        'description': 'The skill, by name: "commit", "review-pr", "pdf"',
      },
      'args': {'type': 'string', 'description': 'What to pass it, if anything'},
    },
    'required': ['skill'],
    'additionalProperties': false,
  };

  @override
  bool isReadOnly(Map<String, Object?> input) => true;

  @override
  bool isConcurrencySafe(Map<String, Object?> input) => false;

  static PromptCommand? find(AgentSession session, String name) {
    final wanted = name.startsWith('/') ? name.substring(1) : name;
    for (final command in available(session)) {
      if (command.name == wanted) return command;
    }
    // A plugin's skill by its own name.
    for (final command in available(session)) {
      if (command.name.split(':').last == wanted) return command;
    }
    return null;
  }

  @override
  Future<String?> validate(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final name = '${input['skill'] ?? ''}'.trim();
    if (name.isEmpty) return 'Give the name of a skill.';
    if (find(context.session, name) == null) return 'Unknown skill: $name';
    return null;
  }

  @override
  Future<PermissionDecision> checkPermissions(
    Map<String, Object?> input,
    ToolContext context,
  ) async => const PermissionAllow();

  @override
  String? ruleContent(Map<String, Object?> input) => asText(input['skill']);

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final session = context.session;
    final command = find(session, '${input['skill']}'.trim())!;
    final args = asString(input['args']) ?? '';
    // What it may use while it runs, without asking.
    if (command.allowedTools.isNotEmpty) {
      session.settings.addRules(
        command.allowedTools,
        'allow',
        SettingsSource.session,
      );
    }
    final body = command.expand(args);
    final text = command.isSkill
        ? 'Base directory for this skill: ${command.baseDir}\n\n$body'
        : body;
    return ToolOutput(
      'Loaded the skill ${command.name}.',
      result: {
        'success': true,
        'commandName': command.name,
        if (command.allowedTools.isNotEmpty)
          'allowedTools': command.allowedTools,
        'model': ?command.model,
      },
      followUp: [
        {
          'content': [
            {'type': 'text', 'text': text},
          ],
          'isMeta': true,
        },
      ],
    );
  }
}
