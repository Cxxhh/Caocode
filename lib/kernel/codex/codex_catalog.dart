import 'dart:async';
import 'dart:convert';

import '../agent_kernel.dart';
import 'codex_config_setting.dart';
import 'codex_environment.dart';
import 'codex_path_setting.dart';
import 'codex_process.dart';
import 'codex_rpc.dart';
import 'codex_transport.dart';

/// Codex owns the session store; access it through its versioned thread API.
class CodexCatalog implements ProgressiveSessionCatalog {
  const CodexCatalog({this.environments, this.transport});
  final CodexEnvironmentController? environments;
  final CodexTransport Function(String? cwd)? transport;
  @override
  String get cacheKey {
    final controller = environments ?? CodexEnvironmentController.instance;
    final cwd = controller.supported ? controller.selected.root : null;
    return jsonEncode([
      controller.supported ? controller.selected.id : 'native',
      CodexPathSetting.forLocation(cwd),
      CodexConfigSetting.forLocation(cwd),
    ]);
  }

  static final _locations = <String, String>{};
  static void remember(String id, String? cwd) {
    if (cwd != null) _locations[id] = cwd;
  }

  Future<T> _withClient<T>(
    String? cwd,
    Future<T> Function(CodexRpcClient) run,
  ) async {
    final client = CodexRpcClient(
      transport?.call(cwd) ?? localCodexTransport(cwd: cwd),
    );
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

  Stream<({List<SessionRecord> sessions, String? nextCursor})> _pages(
    String? cwd, {
    bool inDirectory = true,
    String? cursor,
    bool onePage = false,
  }) async* {
    final client = CodexRpcClient(
      transport?.call(cwd) ?? localCodexTransport(cwd: cwd),
    );
    final subscription = client.messages.listen((_) {}, onError: (Object _) {});
    try {
      await client.initialize();
      do {
        final result = await client.request('thread/list', {
          'limit': 100,
          'archived': false,
          'sortKey': 'updated_at',
          if (inDirectory && cwd != null) 'cwd': codexServerPath(cwd),
          'cursor': ?cursor,
        });
        final sessions = <SessionRecord>[];
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
            cwd: inDirectory && cwd != null ? cwd : codexClientPath(path, cwd),
            path: thread['path'] as String?,
          );
          remember(record.id, record.cwd);
          sessions.add(record);
        }
        final next = result['nextCursor'] as String?;
        yield (sessions: sessions, nextCursor: next == cursor ? null : next);
        if (onePage) break;
        if (next == cursor) break;
        cursor = next;
      } while (cursor != null);
    } finally {
      client.close();
      await subscription.cancel();
      // Reaping a process must not delay displaying metadata already received.
      unawaited(client.stopped);
    }
  }

  @override
  Stream<List<ProjectRecord>> projectPages() {
    final controller = environments ?? CodexEnvironmentController.instance;
    final cwd = controller.supported ? controller.selected.root : null;
    return _pages(cwd, inDirectory: false).map((page) => _group(page.sessions));
  }

  @override
  Future<ProjectCatalogPage> projectPage({String? cursor}) async {
    final controller = environments ?? CodexEnvironmentController.instance;
    final cwd = controller.supported ? controller.selected.root : null;
    final page = await _pages(
      cwd,
      inDirectory: false,
      cursor: cursor,
      onePage: true,
    ).first;
    return ProjectCatalogPage(
      _group(page.sessions),
      nextCursor: page.nextCursor,
    );
  }

  List<ProjectRecord> _group(List<SessionRecord> sessions) {
    final grouped = <String, List<SessionRecord>>{};
    for (final session in sessions) {
      (grouped[session.cwd] ??= []).add(session);
    }
    return [
      for (final entry in grouped.entries)
        ProjectRecord(path: entry.key, sessions: entry.value),
    ];
  }

  @override
  Future<List<ProjectRecord>> projects() async => _group([
    await for (final page in projectPages())
      for (final project in page) ...project.sessions,
  ]);

  @override
  Stream<List<SessionRecord>> sessionPages(String cwd) =>
      _pages(cwd).map((page) => page.sessions);

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => [
    await for (final page in sessionPages(cwd)) ...page,
  ];

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
