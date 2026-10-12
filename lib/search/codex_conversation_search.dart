import '../kernel/agent_kernel.dart';
import '../kernel/codex/codex_catalog.dart';
import 'conversation_search.dart';

/// Cache the text of stored Codex threads by their last update time.
class CodexConversationSearch implements ConversationSearch {
  CodexConversationSearch({this.catalog = const CodexCatalog()});
  final CodexCatalog catalog;
  final Map<String, ({DateTime updatedAt, String text})> _cache = {};
  List<SessionRecord> _sessions = [];
  Future<void>? _preparing;

  @override
  Future<void> prepare() =>
      _preparing ??= _prepare().whenComplete(() => _preparing = null);

  Future<void> _prepare() async {
    final projects = await catalog.projects();
    _sessions = [for (final project in projects) ...project.sessions]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final ids = _sessions.map((session) => session.id).toSet();
    _cache.removeWhere((id, _) => !ids.contains(id));
  }

  @override
  Future<List<ConversationHit>> search(String query, {int limit = 50}) async {
    if (query.trim().isEmpty) return [];
    final hits = <ConversationHit>[];
    for (final session in _sessions) {
      var cached = _cache[session.id];
      if (cached == null || cached.updatedAt != session.updatedAt) {
        final thread = await catalog.read(session);
        cached = (updatedAt: session.updatedAt, text: codexThreadText(thread));
        _cache[session.id] = cached;
      }
      if (findIn(session.id, cached.text, query) case final hit?) hits.add(hit);
      if (hits.length >= limit) break;
    }
    return hits;
  }
}

String codexThreadText(Map thread) {
  final out = StringBuffer();
  for (final rawTurn in thread['turns'] as List? ?? const []) {
    for (final rawItem in (rawTurn as Map)['items'] as List? ?? const []) {
      final item = rawItem as Map;
      if (item['type'] == 'agentMessage') {
        out.writeln(item['text'] ?? '');
      } else if (item['type'] == 'userMessage') {
        for (final raw in item['content'] as List? ?? const []) {
          final content = raw as Map;
          final text = content['text'];
          if (content['type'] == 'text' &&
              text is String &&
              !text.startsWith('<caocode_context>')) {
            out.writeln(text);
          }
        }
      }
    }
  }
  return out.toString();
}
