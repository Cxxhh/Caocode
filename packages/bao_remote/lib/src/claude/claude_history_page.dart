/// Some of a kept session's conversation, along the branch it ended on:
/// its last turns, or those before others already read.
class ClaudeHistoryPage {
  const ClaudeHistoryPage(this.entries, {this.earlier});

  /// The whole of it: nothing before.
  const ClaudeHistoryPage.whole(this.entries) : earlier = null;

  factory ClaudeHistoryPage.fromJson(Map<String, Object?> json) =>
      ClaudeHistoryPage([
        for (final entry in json['entries'] as List)
          (entry as Map).cast<String, Object?>(),
      ], earlier: json['earlier'] as String?);

  /// Its lines, oldest first.
  final List<Map<String, Object?>> entries;

  /// What to read the turns before it by (`before`); null when it begins
  /// the conversation.
  final String? earlier;

  Map<String, Object?> toJson() => {'entries': entries, 'earlier': earlier};
}
