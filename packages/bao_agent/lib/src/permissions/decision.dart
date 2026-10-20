/// What is decided about a tool call: run it, refuse it, or ask the user.
sealed class PermissionDecision {
  const PermissionDecision();
}

/// Run it, with [updatedInput] in place of what the model sent if given.
class PermissionAllow extends PermissionDecision {
  const PermissionAllow({this.updatedInput, this.reason});

  final Map<String, Object?>? updatedInput;

  /// Why (a rule, the mode, a hook), for the record.
  final String? reason;
}

/// Refuse it: [message] is what the model is told.
class PermissionDeny extends PermissionDecision {
  const PermissionDeny(this.message, {this.reasonType, this.interrupt = false});

  final String message;

  /// `rule`, `mode`, `hook`, `classifier`, `user`…
  final String? reasonType;

  /// Whether the turn stops with it.
  final bool interrupt;
}

/// Ask the user (or, in auto mode, the classifier).
class PermissionAsk extends PermissionDecision {
  const PermissionAsk({
    this.message,
    this.suggestions = const [],
    this.reasonType,
    this.matchedAskRule,
    this.classifierApprovable = true,
    this.requiresUserInteraction = false,
    this.blockedPath,
  });

  /// Why it is asked, shown with the question.
  final String? message;

  /// The permission updates offered as "always allow" (`addRules`,
  /// `setMode`, `addDirectories`).
  final List<Map<String, Object?>> suggestions;

  /// `rule`, `safetyCheck`, `workingDir`, `mode`, `other`…
  final String? reasonType;

  /// The ask rule that matched, if one did.
  final String? matchedAskRule;

  /// Whether auto mode's classifier may answer for the user.
  final bool classifierApprovable;

  /// Whether only the user can answer (a question put to them).
  final bool requiresUserInteraction;

  /// The path outside the working folders that was asked about.
  final String? blockedPath;
}

/// The tool has nothing to say about it: the rules and the mode decide.
class PermissionPassthrough extends PermissionDecision {
  const PermissionPassthrough({this.suggestions = const []});

  final List<Map<String, Object?>> suggestions;
}

/// A suggestion to allow [rules] from now on, saved in the project's local
/// settings unless said otherwise.
Map<String, Object?> addRulesSuggestion(
  List<String> rules, {
  String destination = 'localSettings',
  String behavior = 'allow',
}) => {
  'type': 'addRules',
  'rules': [for (final rule in rules) _ruleValue(rule)],
  'behavior': behavior,
  'destination': destination,
};

/// A suggestion to switch to [mode] for the session.
Map<String, Object?> setModeSuggestion(String mode) => {
  'type': 'setMode',
  'mode': mode,
  'destination': 'session',
};

/// A suggestion to let the agent work in [directories] too.
Map<String, Object?> addDirectoriesSuggestion(
  List<String> directories, {
  String destination = 'session',
}) => {
  'type': 'addDirectories',
  'directories': directories,
  'destination': destination,
};

/// `Bash(npm test:*)` as `{toolName: Bash, ruleContent: npm test:*}`.
Map<String, Object?> _ruleValue(String rule) {
  final open = rule.indexOf('(');
  if (open < 0 || !rule.endsWith(')')) return {'toolName': rule};
  return {
    'toolName': rule.substring(0, open),
    'ruleContent': rule.substring(open + 1, rule.length - 1),
  };
}

/// [value] (`{toolName, ruleContent}`) as a rule's string.
String ruleString(Map<String, Object?> value) {
  final tool = '${value['toolName'] ?? ''}';
  final content = value['ruleContent'];
  return content is String && content.isNotEmpty ? '$tool($content)' : tool;
}
