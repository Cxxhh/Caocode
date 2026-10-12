import 'dart:convert';

import '../chat/chat_models.dart';

/// The history's items as JSON, for the phones paired with the desktop
/// (see `package:bao_link`). The phone has this file as it is (its
/// lib/link/chat_codec.dart), over its copy of chat_models.dart.
abstract final class ChatCodec {
  /// What a tool's or a command's output keeps, at most: the phone shows it
  /// on demand, and a build's log would weigh on every update.
  static const maxOutput = 64 * 1024;

  static Map<String, Object?> encode(ChatItem item) => switch (item) {
    UserMessageItem() => {
      't': 'user',
      'text': item.text,
      if (item.queued) 'queued': true,
      if (item.images.isNotEmpty)
        'images': [
          for (final image in item.images)
            {
              'data': base64.encode(image.bytes),
              'type': image.mediaType,
              'name': ?image.name,
              'n': ?image.number,
            },
        ],
      'worked': ?item.worked?.inMilliseconds,
      if (item.usage case final usage?)
        'usage': {
          'inputTokens': ?usage.inputTokens,
          'outputTokens': ?usage.outputTokens,
          'tokensPerSecond': ?usage.tokensPerSecond,
          'costUsd': ?usage.costUsd,
        },
    },
    AssistantTextItem() => {'t': 'text', 'text': item.text},
    ThinkingItem() => {
      't': 'thinking',
      'text': item.text,
      'tokens': item.tokens,
      'seconds': ?item.seconds,
      'startedAt': ?item.startedAt?.millisecondsSinceEpoch,
      if (item.summarized) 'summarized': true,
      'streaming': item.streaming,
    },
    ToolCallItem() => {
      't': 'tool',
      'kind': item.kind.name,
      'target': item.target,
      'detail': ?item.detail,
      'path': ?item.path,
      if (item.results.isNotEmpty) 'results': item.results,
      'label': ?item.label,
      'status': item.status.name,
      'output': ?_head(item.output),
    },
    AgentItem() => {
      't': 'agent',
      'description': item.description,
      'id': ?item.id,
      'agentType': ?item.agentType,
      'prompt': ?item.prompt,
      'status': item.status.name,
      'tokens': ?item.tokens,
      'toolUses': ?item.toolUses,
      'lastTool': ?item.lastTool,
      'activity': ?item.activity,
      'startedAt': ?item.startedAt?.millisecondsSinceEpoch,
      'duration': ?item.duration?.inMilliseconds,
      'model': ?item.model,
      if (item.children.isNotEmpty)
        'children': [for (final child in item.children) encode(child)],
      'result': ?item.result,
      if (item.background) 'background': true,
    },
    NoticeItem() => {'t': 'notice', 'kind': item.kind.name, 'text': item.text},
    PlanItem() => {
      't': 'plan',
      'path': item.path,
      'round': item.round,
      'title': ?item.title,
      'text': ?item.text,
      'status': item.status.name,
      'writes': item.writes,
      'feedback': ?item.feedback,
    },
    TerminalItem() => {
      't': 'terminal',
      'command': item.command,
      'output': _tail(item.output),
      'description': ?item.description,
      'status': item.status.name,
      if (item.background) 'background': true,
      'startedAt': ?item.startedAt?.millisecondsSinceEpoch,
    },
    CodeDiffItem() => {
      't': 'diff',
      'fileName': item.fileName,
      'directory': item.directory,
      'lines': [
        for (final line in item.lines)
          [line.type.index, line.lineNumber, line.text],
      ],
      'added': item.added,
      'removed': item.removed,
    },
    LiveStatusItem() => {
      't': 'live',
      'label': item.label,
      if (item.whimsical) 'whimsical': true,
      if (!item.visible) 'visible': false,
    },
  };

  /// The item [json] is; null for one of a kind this side does not know
  /// (a newer desktop's).
  static ChatItem? decode(Object? json) {
    if (json is! Map<String, Object?>) return null;
    String text(String key) => json[key] as String? ?? '';
    String? optional(String key) => json[key] as String?;
    int? number(String key) => (json[key] as num?)?.toInt();
    DateTime? time(String key) => switch (number(key)) {
      final ms? => DateTime.fromMillisecondsSinceEpoch(ms),
      null => null,
    };
    Duration? duration(String key) => switch (number(key)) {
      final ms? => Duration(milliseconds: ms),
      null => null,
    };
    T named<T extends Enum>(List<T> values, String key, T fallback) =>
        values.asNameMap()[json[key]] ?? fallback;
    return switch (json['t']) {
      'user' => UserMessageItem(
        text: text('text'),
        queued: json['queued'] == true,
        images: [
          for (final image in (json['images'] as List?) ?? const [])
            if (image case {
              'data': final String data,
              'type': final String type,
            })
              ImageAttachment(
                bytes: base64.decode(data),
                mediaType: type,
                name: image['name'] as String?,
                number: (image['n'] as num?)?.toInt(),
              ),
        ],
        worked: duration('worked'),
        usage: switch (json['usage']) {
          final Map<String, Object?> usage => TurnUsage(
            inputTokens: (usage['inputTokens'] as num?)?.toInt(),
            outputTokens: (usage['outputTokens'] as num?)?.toInt(),
            tokensPerSecond: (usage['tokensPerSecond'] as num?)?.toDouble(),
            costUsd: (usage['costUsd'] as num?)?.toDouble(),
          ),
          _ => null,
        },
      ),
      'text' => AssistantTextItem(text('text')),
      'thinking' => ThinkingItem(
        text: text('text'),
        tokens: number('tokens') ?? 0,
        seconds: number('seconds'),
        startedAt: time('startedAt'),
        summarized: json['summarized'] == true,
        streaming: json['streaming'] as bool?,
      ),
      'tool' => ToolCallItem(
        kind: named(ToolKind.values, 'kind', ToolKind.other),
        target: text('target'),
        detail: optional('detail'),
        path: optional('path'),
        results: [...?(json['results'] as List?)?.whereType<String>()],
        label: optional('label'),
        status: named(ToolStatus.values, 'status', ToolStatus.succeeded),
        output: optional('output'),
      ),
      'agent' => AgentItem(
        description: text('description'),
        id: optional('id'),
        agentType: optional('agentType'),
        prompt: optional('prompt'),
        status: named(CommandStatus.values, 'status', CommandStatus.running),
        tokens: number('tokens'),
        toolUses: number('toolUses'),
        lastTool: optional('lastTool'),
        activity: optional('activity'),
        startedAt: time('startedAt'),
        duration: duration('duration'),
        model: optional('model'),
        children: [
          for (final child in (json['children'] as List?) ?? const [])
            ?decode(child),
        ],
        result: optional('result'),
        background: json['background'] == true,
      ),
      'notice' => NoticeItem(
        named(NoticeKind.values, 'kind', NoticeKind.info),
        text('text'),
      ),
      'plan' => PlanItem(
        path: text('path'),
        round: number('round') ?? 1,
        title: optional('title'),
        text: optional('text'),
        status: named(PlanStatus.values, 'status', PlanStatus.drafting),
        writes: number('writes') ?? 0,
        feedback: optional('feedback'),
      ),
      'terminal' => TerminalItem(
        command: text('command'),
        output: text('output'),
        description: optional('description'),
        status: named(CommandStatus.values, 'status', CommandStatus.succeeded),
        background: json['background'] == true,
        startedAt: time('startedAt'),
      ),
      'diff' => CodeDiffItem(
        fileName: text('fileName'),
        directory: text('directory'),
        lines: [
          for (final line in (json['lines'] as List?) ?? const [])
            if (line case [final int type, final int number, final String text]
                when type >= 0 && type < DiffLineType.values.length)
              DiffLine(DiffLineType.values[type], number, text),
        ],
        added: number('added'),
        removed: number('removed'),
      ),
      'live' => LiveStatusItem(
        text('label'),
        whimsical: json['whimsical'] == true,
        visible: json['visible'] != false,
      ),
      _ => null,
    };
  }

  static String? _head(String? text) => text == null || text.length <= maxOutput
      ? text
      : '${text.substring(0, maxOutput)}\n…';

  static String _tail(String text) => text.length <= maxOutput
      ? text
      : '…\n${text.substring(text.length - maxOutput)}';
}
