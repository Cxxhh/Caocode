import 'package:caocode/chat/chat_feed.dart';
import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/chat/chat_session.dart';
import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/kernel/codex/codex_kernel.dart';
import 'package:caocode/kernel/kernel_registry.dart';
import 'package:caocode/kernel/kernel_types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'codex_test.dart' show Server;

class SubagentServer extends Server {
  final Map<String, Map<String, Object?>> threads = {};
  final Map<String, Map<String, Object?>> pages = {};
  final Map<String, Map<String, Object?>> olderPages = {};
  final Map<String, Map<String, Object?>> held = {};
  bool holdReads = false;
  bool legacy = false;

  void reply(Map<String, Object?> request, Map<String, Object?> result) =>
      output.add({'id': request['id'], 'result': result});

  @override
  void write(Map<String, Object?> message) {
    final method = message['method'];
    if (method != 'thread/read' && method != 'thread/turns/list') {
      super.write(message);
      return;
    }
    calls.add(message);
    final params = message['params'] as Map;
    final id = params['threadId'] as String;
    if (method == reject || (!threads.containsKey(id))) {
      output.add({
        'id': message['id'],
        'error': {'code': -32600, 'message': 'child unavailable'},
      });
    } else if (method == 'thread/read') {
      if (holdReads) {
        held[id] = message;
        return;
      }
      reply(message, {'thread': threads[id]});
    } else if (legacy) {
      output.add({
        'id': message['id'],
        'error': {'code': -32601, 'message': 'unknown method'},
      });
    } else {
      reply(
        message,
        (params['cursor'] == null ? pages[id] : olderPages[id]) ??
            {'data': [], 'nextCursor': null},
      );
    }
  }
}

Map<String, Object?> spawn(
  String id, {
  String parent = 'thread',
  String prompt = 'Inspect files',
  String? model,
}) => {
  'id': 'spawn-$id',
  'type': 'collabAgentToolCall',
  'tool': 'spawnAgent',
  'status': 'completed',
  'senderThreadId': parent,
  'receiverThreadIds': [id],
  'prompt': prompt,
  'model': model,
  'agentsStates': {
    id: {'status': 'running'},
  },
};

Map<String, Object?> savedTurn(
  String id,
  String text, {
  String status = 'completed',
}) => {
  'id': id,
  'status': status,
  'items': [
    {
      'id': 'u-$id',
      'type': 'userMessage',
      'content': [
        {'type': 'text', 'text': 'Task $id'},
      ],
    },
    {'id': 'a-$id', 'type': 'agentMessage', 'text': text},
  ],
};

Future<void> settleProtocol() async {
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SubagentServer server;
  late CodexKernel kernel;
  late ChatSession session;

  setUp(() {
    server = SubagentServer();
    kernel = CodexKernel(
      KernelRegistry.codex,
      server,
      context: const KernelContext(cwd: '/project'),
    );
    session = ChatSession(
      historyCount: 0,
      kernel: KernelDescriptor(
        id: 'codex',
        label: 'Codex',
        icon: KernelRegistry.codex.icon,
        description: 'Codex',
        create: (_) => kernel,
      ),
    );
  });
  tearDown(() => session.dispose());

  Future<void> begin() async {
    kernel.send(const KernelTurn(id: 'user-turn', text: 'Delegate this task'));
    await settleProtocol();
  }

  void notifyItem(Map<String, Object?> item, {String thread = 'thread'}) =>
      server.notify('item/completed', {
        'threadId': thread,
        'turnId': 'server-1',
        'item': item,
      });

  AgentItem agent(String id) =>
      session.subagents.firstWhere((entry) => entry.agent.id == id).agent;

  void save(String id, {String status = 'idle', String name = 'Explorer'}) {
    server.threads[id] = {
      'id': id,
      'agentNickname': name,
      'agentRole': 'explorer',
      'status': {'type': status},
    };
    server.pages[id] = {
      'data': [savedTurn('turn-1', 'Child answer')],
      'nextCursor': null,
    };
  }

  test(
    'spawn tool completion keeps agent running; wait updates one stable card',
    () async {
      await begin();
      notifyItem(spawn('child', model: 'custom-model'));
      expect(agent('child').status, CommandStatus.running);
      expect(agent('child').model, 'custom-model');
      notifyItem({
        ...spawn('child'),
        'id': 'wait-1',
        'tool': 'wait',
        'agentsStates': {
          'child': {'status': 'completed', 'message': 'Done'},
        },
      });
      expect(session.subagents, hasLength(1));
      expect(agent('child').status, CommandStatus.succeeded);
      expect(agent('child').result, 'Done');
      expect(
        server.calls.where((call) => call['method'] == 'thread/read'),
        isEmpty,
      );
    },
  );

  test(
    'viewing reads child history without resuming or stopping either thread',
    () async {
      await begin();
      notifyItem(spawn('child'));
      save('child');
      final callsBefore = server.calls.length;
      kernel.viewSubagent('child');
      await settleProtocol();
      final feed = SubagentFeed(session, ['child']);
      addTearDown(feed.dispose);
      expect(feed.canEditMessages, isFalse);
      expect(
        List.generate(
          feed.itemCount,
          feed.itemAt,
        ).whereType<AssistantTextItem>().single.text,
        'Child answer',
      );
      expect(
        List.generate(feed.itemCount, feed.itemAt).whereType<UserMessageItem>(),
        hasLength(1),
      );
      expect(agent('child').description, 'Explorer');
      expect(session.isStreaming, isTrue);
      expect(
        server.calls.skip(callsBefore).map((call) => call['method']),
        everyElement(isIn(['thread/read', 'thread/turns/list'])),
      );
      kernel.viewSubagent(null);
      expect(session.isStreaming, isTrue);
    },
  );

  test(
    'current CLI activity creates stable cards and restarts completed agents',
    () async {
      await begin();
      Map<String, Object?> activity(String id, String kind) => {
        'id': 'activity-$id-$kind',
        'type': 'subAgentActivity',
        'agentThreadId': id,
        'agentPath': id == 'child' ? 'inspector' : 'inspector/checker',
        'kind': kind,
        'model': kind == 'started' ? 'custom-model' : null,
      };
      notifyItem(activity('child', 'started'));
      notifyItem(activity('nested', 'started'), thread: 'child');
      expect(session.subagents.map((entry) => entry.path), [
        ['child'],
        ['child', 'nested'],
      ]);
      expect(agent('child').description, 'inspector');
      expect(agent('child').model, 'custom-model');
      notifyItem(activity('child', 'completed'));
      expect(agent('child').status, CommandStatus.succeeded);
      notifyItem(activity('child', 'interacted'));
      expect(agent('child').status, CommandStatus.running);
      expect(agent('child').model, 'custom-model');
      notifyItem(activity('child', 'interrupted'));
      expect(agent('child').status, CommandStatus.failed);
      expect(session.subagents, hasLength(2));
    },
  );

  test(
    'live text and command deltas continue after reading an active snapshot',
    () async {
      await begin();
      notifyItem(spawn('child'));
      save('child', status: 'active');
      server.pages['child'] = {
        'data': [
          {
            'id': 'active-turn',
            'status': 'inProgress',
            'items': [
              {'id': 'answer', 'type': 'agentMessage', 'text': 'Partial'},
              {
                'id': 'command',
                'type': 'commandExecution',
                'command': 'git status',
                'cwd': '/project',
                'status': 'inProgress',
                'aggregatedOutput': 'On branch',
              },
            ],
          },
        ],
        'nextCursor': null,
      };
      kernel.viewSubagent('child');
      await settleProtocol();
      server.notify('item/agentMessage/delta', {
        'threadId': 'child',
        'itemId': 'answer',
        'delta': ' answer',
      });
      server.notify('item/commandExecution/outputDelta', {
        'threadId': 'child',
        'itemId': 'command',
        'delta': ' main',
      });
      expect(
        agent('child').children.whereType<AssistantTextItem>().single.text,
        'Partial answer',
      );
      expect(
        agent('child').children.whereType<TerminalItem>().single.output,
        contains('On branch main'),
      );
      expect(agent('child').status, CommandStatus.running);
      kernel.viewSubagent(null);
    },
  );

  test(
    'parent and sibling deltas never appear in another child transcript',
    () async {
      await begin();
      notifyItem(spawn('one'));
      notifyItem(spawn('two'));
      for (final id in ['one', 'two']) {
        server.notify('item/started', {
          'threadId': id,
          'item': {'id': 'same-item', 'type': 'agentMessage'},
        });
        server.notify('item/agentMessage/delta', {
          'threadId': id,
          'itemId': 'same-item',
          'delta': 'From $id',
        });
      }
      notifyItem({
        'id': 'main-text',
        'type': 'agentMessage',
        'text': 'Parent only',
      });
      expect(
        agent('one').children.whereType<AssistantTextItem>().single.text,
        'From one',
      );
      expect(
        agent('two').children.whereType<AssistantTextItem>().single.text,
        'From two',
      );
      expect(
        List.generate(
          session.itemCount,
          session.itemAt,
        ).whereType<AssistantTextItem>().single.text,
        'Parent only',
      );
      server.notify('turn/completed', {
        'threadId': 'one',
        'turn': {'id': 'child-turn', 'status': 'completed'},
      });
      expect(agent('one').status, CommandStatus.succeeded);
      expect(agent('two').status, CommandStatus.running);
      expect(session.isStreaming, isTrue);
    },
  );

  test(
    'nested delegates remain below their parent and can be opened by path',
    () async {
      await begin();
      notifyItem(spawn('child'));
      notifyItem(spawn('nested', parent: 'child'), thread: 'child');
      expect(session.subagents.map((entry) => entry.path), [
        ['child'],
        ['child', 'nested'],
      ]);
      final feed = SubagentFeed(session, ['child', 'nested']);
      addTearDown(feed.dispose);
      expect(feed.agent!.id, 'nested');
      notifyItem({
        'id': 'nested-answer',
        'type': 'agentMessage',
        'text': 'Nested answer',
      }, thread: 'nested');
      expect(
        List.generate(
          feed.itemCount,
          feed.itemAt,
        ).whereType<AssistantTextItem>().single.text,
        'Nested answer',
      );
      expect(session.subagents, hasLength(2));
    },
  );

  test(
    'child approvals are attributed and survive parent completion',
    () async {
      await begin();
      notifyItem(spawn('child'));
      server.output.add({
        'id': 501,
        'method': 'item/commandExecution/requestApproval',
        'params': {'threadId': 'child', 'command': 'git status'},
      });
      expect(
        session.pendingInteraction!.title,
        contains(agent('child').description),
      );
      server.notify('turn/completed', {
        'threadId': 'thread',
        'turn': {'id': 'server-1', 'status': 'completed'},
      });
      expect(session.pendingInteraction, isNotNull);
      kernel.answer(
        'approval:501',
        const ApprovalAnswer(ApprovalDecision.allowOnce),
      );
      expect(server.calls.last['id'], 501);
      expect(server.calls.last['result'], {'decision': 'accept'});
      expect(session.pendingInteraction, isNull);
    },
  );

  test('child completion resolves only its own pending requests', () async {
    await begin();
    notifyItem(spawn('one'));
    notifyItem(spawn('two'));
    for (final (id, rpc) in [('one', 501), ('two', 502)]) {
      server.output.add({
        'id': rpc,
        'method': 'item/commandExecution/requestApproval',
        'params': {'threadId': id, 'command': 'git status'},
      });
    }
    server.notify('turn/completed', {
      'threadId': 'one',
      'turn': {'id': 'child-turn', 'status': 'completed'},
    });
    expect(session.pendingInteraction!.id, 'approval:502');
    kernel.answer('approval:502', const ApprovalAnswer(ApprovalDecision.deny));
    expect(session.pendingInteraction, isNull);
  });

  test(
    'unrelated thread requests are rejected promptly without a visible card',
    () async {
      await begin();
      server.output.add({
        'id': 500,
        'method': 'item/commandExecution/requestApproval',
        'params': {'threadId': 'unrelated', 'command': 'echo'},
      });
      expect(server.calls.last['error'], isNotNull);
      expect(session.pendingInteraction, isNull);
      expect(session.subagents, isEmpty);
    },
  );

  test(
    'failed history reads are retryable without losing received messages',
    () async {
      await begin();
      notifyItem(spawn('child'));
      notifyItem({
        'id': 'live',
        'type': 'agentMessage',
        'text': 'Already received',
      }, thread: 'child');
      server.reject = 'thread/read';
      kernel.viewSubagent('child');
      await settleProtocol();
      expect(kernel.subagentHistory('child').error, contains('unavailable'));
      expect(
        agent('child').children.whereType<AssistantTextItem>().single.text,
        'Already received',
      );
      save('child');
      server.reject = null;
      await kernel.refreshSubagent('child');
      expect(kernel.subagentHistory('child').error, isNull);
      expect(
        agent('child').children.whereType<AssistantTextItem>().single.text,
        'Child answer',
      );
    },
  );

  test(
    'older pages prepend chronologically and remain after recent refresh',
    () async {
      await begin();
      notifyItem(spawn('child'));
      save('child');
      server.pages['child'] = {
        'data': [savedTurn('z', 'newest')],
        'nextCursor': 'older',
      };
      server.olderPages['child'] = {
        'data': [savedTurn('a', 'oldest')],
        'nextCursor': null,
      };
      kernel.viewSubagent('child');
      await settleProtocol();
      expect(kernel.subagentHistory('child').hasEarlier, isTrue);
      await kernel.refreshSubagent('child', earlier: true);
      expect(
        agent('child').children
            .whereType<AssistantTextItem>()
            .map((item) => item.text),
        ['oldest', 'newest'],
      );
      expect(kernel.subagentHistory('child').hasEarlier, isFalse);
      await kernel.refreshSubagent('child');
      expect(
        agent('child').children
            .whereType<AssistantTextItem>()
            .map((item) => item.text),
        ['oldest', 'newest'],
      );
      expect(kernel.subagentHistory('child').hasEarlier, isFalse);
    },
  );

  test(
    'a notification received during a read wins over the older snapshot',
    () async {
      await begin();
      notifyItem(spawn('child'));
      save('child', status: 'active');
      server.holdReads = true;
      kernel.viewSubagent('child');
      await settleProtocol();
      notifyItem({
        'id': 'live',
        'type': 'agentMessage',
        'text': 'New live content',
      }, thread: 'child');
      server.holdReads = false;
      server.reply(server.held['child']!, {'thread': server.threads['child']});
      await settleProtocol();
      expect(
        agent('child').children.whereType<AssistantTextItem>().single.text,
        'New live content',
      );
      expect(kernel.subagentHistory('child').loading, isFalse);
    },
  );

  test(
    'legacy CLIs use full read only when pagination method is unavailable',
    () async {
      await begin();
      notifyItem(spawn('child'));
      save('child');
      server.legacy = true;
      server.threads['child']!['turns'] = [
        savedTurn('legacy', 'Legacy answer'),
      ];
      kernel.viewSubagent('child');
      await settleProtocol();
      expect(
        agent('child').children.whereType<AssistantTextItem>().single.text,
        'Legacy answer',
      );
      expect(
        server.calls.where((call) => call['method'] == 'thread/resume'),
        isEmpty,
      );
    },
  );

  test(
    'thread source discovers a child before its spawn tool finishes',
    () async {
      await begin();
      server.notify('thread/started', {
        'thread': {
          'id': 'child',
          'agentNickname': 'Inspector',
          'agentRole': 'explorer',
          'source': {
            'subAgent': {
              'thread_spawn': {'parent_thread_id': 'thread', 'depth': 1},
            },
          },
        },
      });
      expect(agent('child').description, 'Inspector');
      expect(agent('child').agentType, 'explorer');
      notifyItem(spawn('child'));
      expect(session.subagents, hasLength(1));
      expect(agent('child').description, 'Inspector');
    },
  );

  test(
    'parent activity received during a read wins over the old child status',
    () async {
      await begin();
      notifyItem(spawn('child'));
      save('child', status: 'active');
      server.pages['child'] = {
        'data': [savedTurn('active', 'Old text', status: 'inProgress')],
        'nextCursor': null,
      };
      server.holdReads = true;
      kernel.viewSubagent('child');
      await settleProtocol();
      notifyItem({
        'id': 'done',
        'type': 'subAgentActivity',
        'agentThreadId': 'child',
        'agentPath': 'inspector',
        'kind': 'completed',
      });
      server.holdReads = false;
      server.reply(server.held['child']!, {'thread': server.threads['child']});
      await settleProtocol();
      expect(agent('child').status, CommandStatus.succeeded);
      expect(kernel.subagentHistory('child').loading, isFalse);
    },
  );

  test(
    'restored parent history re-creates cards without loading every child',
    () async {
      server.savedTurns = [
        {
          'id': 'saved-parent-turn',
          'status': 'completed',
          'items': [spawn('saved-child', parent: 'saved')],
        },
      ];
      session.dispose();
      server = SubagentServer()..savedTurns = server.savedTurns;
      kernel = CodexKernel(
        KernelRegistry.codex,
        server,
        context: KernelContext(
          resume: SessionRecord(
            id: 'saved',
            title: 'Saved parent',
            cwd: '/project',
            updatedAt: DateTime(2026),
          ),
        ),
      );
      session = ChatSession(
        historyCount: 0,
        kernel: KernelDescriptor(
          id: 'codex',
          label: 'Codex',
          icon: KernelRegistry.codex.icon,
          description: '',
          create: (_) => kernel,
        ),
      );
      kernel.prepare();
      await settleProtocol();
      expect(session.subagents.single.agent.id, 'saved-child');
      expect(
        server.calls.where((call) => call['method'] == 'thread/read'),
        isEmpty,
      );
    },
  );
}
