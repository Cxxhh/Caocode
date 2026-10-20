import 'dart:convert';

import '../../chat/chat_models.dart';

/// What a turn took and spent, as its footer shows it once it ends: kept,
/// for the footer to show again when the session is opened later, which
/// Claude Code's own session file does not tell.
typedef TurnRecord = ({Duration worked, TurnUsage? usage});

/// The turns' records of Claude Code sessions, by session; each turn by its
/// prompt's uuid (the turn's id, as Caocode sends it and the session file
/// keeps it).
abstract class TurnStats {
  /// Keeps [record] for turn [turnId] of session [sessionId].
  void write(String sessionId, String turnId, TurnRecord record);

  /// The records of session [sessionId]'s turns, by turn; none when it has
  /// none, or they cannot be read.
  Future<Map<String, TurnRecord>> read(String sessionId);

  /// [record] as one line of a session's file.
  static String encode(String turnId, TurnRecord record) {
    final usage = record.usage;
    return jsonEncode({
      'turn': turnId,
      'workedMs': record.worked.inMilliseconds,
      if (usage != null) ...{
        'inputTokens': ?usage.inputTokens,
        'outputTokens': ?usage.outputTokens,
        'tokensPerSecond': ?usage.tokensPerSecond,
        'costUsd': ?usage.costUsd,
      },
    });
  }

  /// A session file's [lines], by turn: the last line of a turn's standing;
  /// a line that does not read (cut off as the app ended) passed over.
  static Map<String, TurnRecord> decode(Iterable<String> lines) {
    final records = <String, TurnRecord>{};
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final Object? json;
      try {
        json = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (json
          case {'turn': final String turn, 'workedMs': final int ms} &&
              final Map<String, Object?> json) {
        int? count(String key) => (json[key] as num?)?.toInt();
        final input = count('inputTokens');
        final output = count('outputTokens');
        final speed = (json['tokensPerSecond'] as num?)?.toDouble();
        final cost = (json['costUsd'] as num?)?.toDouble();
        records[turn] = (
          worked: Duration(milliseconds: ms),
          usage:
              input == null && output == null && speed == null && cost == null
              ? null
              : TurnUsage(
                  inputTokens: input,
                  outputTokens: output,
                  tokensPerSecond: speed,
                  costUsd: cost,
                ),
        );
      }
    }
    return records;
  }
}
