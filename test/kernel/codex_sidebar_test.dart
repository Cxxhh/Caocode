import 'dart:async';

import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/chat/chat_screen.dart';
import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/kernel/codex/codex_kernel.dart';
import 'package:caocode/kernel/codex/codex_transport.dart';
import 'package:caocode/kernel/kernel_types.dart';
import 'package:caocode/main.dart';
import 'package:caocode/sidebar/sidebar.dart';
import 'package:caocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _SavedSessions implements SessionCatalog {
  final records = [
    for (final id in ['alpha', 'beta'])
      SessionRecord(
        id: id,
        title: 'Chat $id',
        cwd: '/project',
        updatedAt: DateTime(2026),
      ),
  ];

  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(path: '/project', sessions: records),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => records;

  @override
  Future<void> delete(String id) async {}
}

/// Restores distinct messages for each thread without starting a CLI process.
class _HistoryServer implements CodexTransport {
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void close() => unawaited(_messages.close());

  @override
  void write(Map<String, Object?> message) {
    if (!message.containsKey('id')) return;
    final params = message['params'] as Map;
    final id = params['threadId'];
    final result = switch (message['method']) {
      'model/list' => {'data': <Object?>[]},
      'thread/resume' => {
        'thread': {
          'id': id,
          'turns': [
            {
              'id': 'turn-$id',
              'status': 'completed',
              'items': [
                {
                  'id': 'user-$id',
                  'type': 'userMessage',
                  'content': [
                    {'type': 'text', 'text': 'Question for $id'},
                  ],
                },
                {
                  'id': 'answer-$id',
                  'type': 'agentMessage',
                  'text': 'Answer for $id',
                },
              ],
            },
          ],
        },
      },
      _ => <String, Object?>{},
    };
    _messages.add({'id': message['id'], 'result': result});
  }
}

void main() {
  testWidgets('single clicks switch and reopen saved Codex conversations', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connections = <String, int>{};
    late final KernelDescriptor codex;
    codex = KernelDescriptor(
      id: 'codex',
      label: 'Codex CLI',
      icon: Icons.bolt_rounded,
      description: '',
      catalog: _SavedSessions(),
      create: (context) {
        CodexTransport connect() {
          final id = context.resume?.id ?? 'new';
          connections.update(id, (count) => count + 1, ifAbsent: () => 1);
          return _HistoryServer();
        }

        return CodexKernel(
          codex,
          connect(),
          context: context,
          reconnect: connect,
        );
      },
    );
    final workspace = Workspace(kernels: [codex]);
    await tester.pumpWidget(CaocodeApp(workspace: workspace));
    await tester.runAsync(workspace.load);
    await tester.pump();

    for (final id in ['alpha', 'beta', 'alpha', 'beta', 'alpha']) {
      final previous = workspace.current!;
      await tester.tap(
        find.descendant(
          of: find.byType(Sidebar),
          matching: find.text('Chat $id'),
        ),
      );
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();

      final thread = workspace.current!;
      final session = thread.session;
      expect(thread.record?.id, id);
      expect(
        tester.widget<ChatScreen>(find.byType(ChatScreen)).session,
        session,
      );
      expect(session.health.status, KernelHealthStatus.ready);
      expect(session.itemCount, 2);
      expect((session.itemAt(0) as UserMessageItem).text, 'Question for $id');
      expect((session.itemAt(1) as AssistantTextItem).text, 'Answer for $id');
      expect(
        find.descendant(
          of: find.byType(ChatScreen),
          matching: find.text('Question for $id'),
        ),
        findsWidgets,
      );
      expect(previous.session.health.status, KernelHealthStatus.idle);
      expect(tester.takeException(), isNull);
    }
    expect(connections['alpha'], 3);
    expect(connections['beta'], 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
