import '../agent_kernel.dart';
import 'codex_process.dart';
import 'codex_rpc.dart';

/// Codex owns the session store; access it through its versioned thread API.
class CodexCatalog implements SessionCatalog {
  const CodexCatalog();
  static final _locations = <String, String>{};
  static void remember(String id, String? cwd) {
    if (cwd != null) _locations[id] = cwd;
  }

  Future<T> _withClient<T>(
    String? cwd,
    Future<T> Function(CodexRpcClient) run,
  ) async {
    final client = CodexRpcClient(localCodexTransport(cwd: cwd));
    // Catalog callers await RPC failures; no view is attached to notifications.
    final subscription = client.messages.listen((_) {}, onError: (Object _) {});
    try {
      await client.initialize();
      return await run(client);
    } finally {
      client.close();
      await subscription.cancel();
      await client.stopped;
    }
  }

  Future<List<SessionRecord>> _list(String? cwd) => _withClient(cwd, (
    client,
  ) async {
    final sessions = <SessionRecord>[];
    String? cursor;
    do {
      final result = await client.request('thread/list', {
        'limit': 100,
        'archived': false,
        'sortKey': 'updated_at',
        if (cwd != null) 'cwd': codexServerPath(cwd),
        'cursor': ?cursor,
      });
      for (final raw in result['data'] as List? ?? const []) {
        final thread = raw as Map;
        final path = thread['cwd'] as String?;
        if (path == null || path.isEmpty) continue;
        final record = SessionRecord(
          id: thread['id'] as String,
          title:
              thread['name'] as String? ?? thread['preview'] as String? ?? '',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            ((thread['updatedAt'] as num?)?.toInt() ?? 0) * 1000,
          ),
          cwd: codexClientPath(path, cwd),
          path: thread['path'] as String?,
        );
        remember(record.id, record.cwd);
        sessions.add(record);
      }
      final next = result['nextCursor'] as String?;
      if (next == cursor) break;
      cursor = next;
    } while (cursor != null);
    return sessions;
  });

  @override
  Future<List<ProjectRecord>> projects() async {
    final grouped = <String, List<SessionRecord>>{};
    for (final session in await _list(null)) {
      (grouped[session.cwd] ??= []).add(session);
    }
    return [
      for (final entry in grouped.entries)
        ProjectRecord(path: entry.key, sessions: entry.value),
    ];
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) => _list(cwd);

  @override
  Future<void> delete(String id) => _withClient(_locations[id], (client) async {
    await client.request('thread/archive', {'threadId': id});
  });

  Future<Map<String, Object?>> read(SessionRecord session) =>
      _withClient(session.cwd, (client) async {
        final result = await client.request('thread/read', {
          'threadId': session.id,
          'includeTurns': true,
        });
        return (result['thread'] as Map).cast<String, Object?>();
      });
}
