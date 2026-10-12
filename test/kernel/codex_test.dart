import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/ask_codex.dart';
import 'package:baocode/kernel/codex/codex_choices.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_process_io.dart';
import 'package:baocode/kernel/codex/codex_rpc.dart';
import 'package:baocode/kernel/codex/codex_transport.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/kernel/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

class Server implements CodexTransport {
  final output = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final List<Map<String, Object?>> calls = [];
  String? reject;
  List<Map<String, Object?>>? savedTurns;
  List<Map<String, Object?>>? models;
  Map<String, Object?> config = {};
  final delayed = <String>{};
  final delayedReplies = <Map<String, Object?>>[];
  int turns = 0;
  @override
  Stream<Map<String, Object?>> get messages => output.stream;
  @override
  void close() {
    unawaited(output.close());
  }

  void notify(String method, Map<String, Object?> params) =>
      output.add({'method': method, 'params': params});
  @override
  void write(Map<String, Object?> message) {
    calls.add(message);
    if (!message.containsKey('method') || !message.containsKey('id')) return;
    if (message['method'] == reject) {
      output.add({
        'id': message['id'],
        'error': {'code': -32602, 'message': 'request rejected'},
      });
      return;
    }
    final result = switch (message['method']) {
      'model/list' => {
        'data':
            models ??
            [
              {'model': 'custom-model', 'displayName': 'Configured model'},
            ],
      },
      'config/read' => {'config': config},
      'thread/start' => {
        'thread': {'id': 'thread', 'cwd': '/project'},
      },
      'thread/resume' => {
        'thread': {
          'id': 'saved',
          'turns':
              savedTurns ??
              [
                {
                  'id': 'old',
                  'status': 'completed',
                  'items': [
                    {
                      'id': 'user',
                      'type': 'userMessage',
                      'content': [
                        {'type': 'text', 'text': 'earlier'},
                      ],
                    },
                    {
                      'id': 'assistant',
                      'type': 'agentMessage',
                      'text': 'answer',
                    },
                  ],
                },
              ],
        },
      },
      'turn/start' => {
        'turn': {'id': 'server-${++turns}', 'status': 'inProgress'},
      },
      _ => <String, Object?>{},
    };
    final reply = <String, Object?>{'id': message['id'], 'result': result};
    if (delayed.contains(message['method'])) {
      delayedReplies.add(reply);
    } else {
      output.add(reply);
    }
  }
}

Iterable<KernelEvent> historyEvents(Iterable<KernelEvent> events) =>
    events.whereType<HistoryReplayed>().expand((event) => event.events);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Server server;
  late CodexKernel kernel;
  late List<KernelEvent> events;
  setUp(() {
    server = (Server());
    kernel = CodexKernel(
      KernelRegistry.codex,
      server,
      context: const KernelContext(cwd: '/project'),
    );
    events = [];
    kernel.events.listen(events.add);
  });
  tearDown(() => kernel.dispose());

  test(
    'initialization is shared and respects the CLI default model and cwd',
    () async {
      kernel.prepare();
      kernel.prepare();
      kernel.send(const KernelTurn(id: 'one', text: 'hello'));
      await pumpEventQueue();
      expect(server.calls.map((call) => call['method']), [
        'initialize',
        'initialized',
        'model/list',
        'config/read',
        'thread/start',
        'turn/start',
      ]);
      expect(kernel.model.options.map((option) => option.id), [
        'default',
        'custom-model',
      ]);
      final start = server.calls.last['params'] as Map;
      expect(start['cwd'], '/project');
      expect(start['summary'], 'auto');
      expect(start.containsKey('model'), isFalse);
      expect(kernel.sessionId, 'thread');
      expect(kernel.health.status, KernelHealthStatus.ready);
    },
  );

  test(
    'permission presets route approvals and review stays read-only',
    () async {
      for (final choice in [
        (
          permission: 'default',
          text: 'edit a file',
          sandbox: 'workspaceWrite',
          reviewer: 'user',
        ),
        (
          permission: 'auto',
          text: 'run tools',
          sandbox: 'workspaceWrite',
          reviewer: 'auto_review',
        ),
        (
          permission: 'full-access',
          text: 'use full access',
          sandbox: 'dangerFullAccess',
          reviewer: 'user',
        ),
        (
          permission: 'full-access',
          text: '/review',
          sandbox: 'readOnly',
          reviewer: 'user',
        ),
        (
          permission: 'auto',
          text: '/diff',
          sandbox: 'readOnly',
          reviewer: 'user',
        ),
      ]) {
        kernel.permission.select(choice.permission);
        kernel.send(KernelTurn(id: choice.text, text: choice.text));
        await pumpEventQueue();
        final start = server.calls.last['params'] as Map;
        final policy = start['sandboxPolicy'] as Map;
        expect(policy['type'], choice.sandbox);
        expect(
          start['approvalPolicy'],
          choice.sandbox == 'workspaceWrite' ? 'on-request' : 'never',
        );
        expect(start['approvalsReviewer'], choice.reviewer);
        if (choice.sandbox == 'workspaceWrite') {
          expect(policy['writableRoots'], ['/project']);
          expect(policy['networkAccess'], isFalse);
        }
        server.notify('turn/completed', {
          'threadId': 'thread',
          'turn': {'id': 'server-${server.turns}', 'status': 'completed'},
        });
      }
    },
  );

  test(
    'custom restores current config after full access, including roots',
    () async {
      kernel.permission.select('full-access');
      kernel.send(const KernelTurn(id: 'full', text: 'first'));
      await pumpEventQueue();
      server.notify('turn/completed', {
        'threadId': 'thread',
        'turn': {'id': 'server-1', 'status': 'completed'},
      });
      server.config = {
        'approval_policy': 'untrusted',
        'approvals_reviewer': 'user',
        'sandbox_mode': 'workspace-write',
        'sandbox_workspace_write': {
          'writable_roots': ['/additional'],
          'network_access': true,
          'exclude_tmpdir_env_var': true,
          'exclude_slash_tmp': true,
        },
      };
      kernel.permission.select('custom');
      kernel.send(const KernelTurn(id: 'custom', text: 'second'));
      await pumpEventQueue();
      final params = server.calls.last['params'] as Map;
      expect(params['approvalPolicy'], 'untrusted');
      expect(params['approvalsReviewer'], 'user');
      expect(params['sandboxPolicy'], {
        'type': 'workspaceWrite',
        'writableRoots': ['/project', '/additional'],
        'networkAccess': true,
        'excludeTmpdirEnvVar': true,
        'excludeSlashTmp': true,
      });
      expect(
        server.calls.where((call) => call['method'] == 'config/read'),
        hasLength(2),
      );
    },
  );

  test(
    'custom honors a named permissions profile and config read failures',
    () async {
      server.config = {
        'default_permissions': 'restricted-profile',
        'approval_policy': 'on-request',
        'approvals_reviewer': 'auto_review',
      };
      kernel.prepare();
      await pumpEventQueue();
      kernel.permission.select('custom');
      kernel.send(const KernelTurn(id: 'profile', text: 'hello'));
      await pumpEventQueue();
      final params = server.calls.last['params'] as Map;
      expect(params['permissions'], 'restricted-profile');
      expect(params.containsKey('sandboxPolicy'), isFalse);
      expect(params['approvalsReviewer'], 'auto_review');
      server.notify('turn/completed', {
        'threadId': 'thread',
        'turn': {'id': 'server-1', 'status': 'completed'},
      });
      server.reject = 'config/read';
      kernel.send(const KernelTurn(id: 'failed', text: 'again'));
      await pumpEventQueue();
      expect(
        server.calls.where((call) => call['method'] == 'turn/start'),
        hasLength(1),
      );
      expect(kernel.health.status, KernelHealthStatus.failed);
    },
  );

  test(
    'model efforts use the catalog, keep each choice, and reset CLI defaults',
    () async {
      server.config = {
        'model': 'custom-model',
        'model_reasoning_effort': 'high',
      };
      server.models = [
        {
          'model': 'custom-model',
          'displayName': 'Configured model',
          'defaultReasoningEffort': 'medium',
          'supportedReasoningEfforts': [
            for (final level in ['low', 'medium', 'high', 'xhigh'])
              {'reasoningEffort': level, 'description': '$level thinking'},
          ],
        },
        {
          'model': 'other-model',
          'displayName': 'Other model',
          'defaultReasoningEffort': 'low',
          'supportedReasoningEfforts': [
            for (final level in ['low', 'high'])
              {'reasoningEffort': level, 'description': '$level thinking'},
          ],
        },
      ];
      kernel.prepare();
      await pumpEventQueue();
      expect(kernel.effort.optionsFor('default').map((option) => option.id), [
        'low',
        'medium',
        'high',
        'xhigh',
      ]);
      expect(kernel.effort.selected, 'high');
      expect(kernel.effort.selectedFor('other-model'), 'low');
      kernel.effort.select('custom-model', 'xhigh');
      expect(kernel.model.selected, 'custom-model');
      expect(kernel.effort.selected, 'xhigh');
      kernel.effort.select('other-model', 'high');
      expect(kernel.model.selected, 'other-model');
      kernel.effort.select('other-model', 'xhigh');
      expect(
        kernel.effort.selected,
        'high',
        reason: 'unsupported efforts are ignored',
      );
      kernel.model.select('custom-model');
      expect(kernel.effort.selected, 'xhigh');
      kernel.send(const KernelTurn(id: 'explicit', text: 'hello'));
      await pumpEventQueue();
      expect((server.calls.last['params'] as Map)['effort'], 'xhigh');
      server.notify('turn/completed', {
        'threadId': 'thread',
        'turn': {'id': 'server-1', 'status': 'completed'},
      });
      kernel.model.select('default');
      kernel.send(const KernelTurn(id: 'default', text: 'again'));
      await pumpEventQueue();
      final params = server.calls.last['params'] as Map;
      expect(params['model'], 'custom-model');
      expect(
        params['effort'],
        'high',
        reason: 'CLI defaults replace the previous overrides',
      );
    },
  );

  test(
    'saved permission and per-model efforts are restored and validated',
    () async {
      kernel.dispose();
      server = Server();
      kernel = CodexKernel(
        KernelRegistry.codex,
        server,
        context: const KernelContext(
          settings: {
            'model': 'custom-model',
            'permission': 'auto',
            'effort': 'low',
            'effort@custom-model': 'high',
            'effort@other-model': 'xhigh',
          },
        ),
      );
      server.models = [
        for (final id in ['custom-model', 'other-model'])
          {
            'model': id,
            'defaultReasoningEffort': 'low',
            'supportedReasoningEfforts': [
              for (final level in ['low', 'high']) {'reasoningEffort': level},
            ],
          },
      ];
      kernel.prepare();
      await pumpEventQueue();
      expect(kernel.permission.options, hasLength(4));
      expect(kernel.permission.selected, 'auto');
      expect(kernel.effort.selected, 'high');
      expect(kernel.effort.selectedFor('other-model'), 'low');
      expect(kernel.effort.optionsFor('unknown-model'), isEmpty);
    },
  );

  test('images are transmitted as data URLs', () async {
    kernel.send(
      KernelTurn(
        id: 'image',
        text: 'look',
        images: [
          ImageAttachment(
            bytes: Uint8List.fromList([1, 2, 3]),
            mediaType: 'image/png',
          ),
        ],
      ),
    );
    await pumpEventQueue();
    final input = (server.calls.last['params'] as Map)['input'] as List;
    expect(input.last, {'type': 'image', 'url': 'data:image/png;base64,AQID'});
  });

  test(
    'RPC failures finish the turn and rejected rollback preserves history',
    () async {
      server.reject = 'turn/start';
      kernel.send(const KernelTurn(id: 'bad', text: 'hello'));
      await pumpEventQueue();
      expect(events.whereType<TurnEnded>().single.turnId, 'bad');
      expect(kernel.health.status, KernelHealthStatus.failed);
      expect(
        events.whereType<ItemUpserted>().any(
          (event) => event.item is NoticeItem,
        ),
        isTrue,
      );
      server.reject = 'thread/rollback';
      expect(await kernel.rewind(itemId: 'bad', index: 0, turns: 1), isFalse);
      expect(events.whereType<Rewound>(), isEmpty);
    },
  );

  test(
    'restored sessions replay once and concurrent prepare reconnects once',
    () async {
      kernel.dispose();
      server = Server();
      var reconnects = 0;
      kernel = CodexKernel(
        KernelRegistry.codex,
        server,
        context: KernelContext(
          cwd: '/project',
          resume: SessionRecord(
            id: 'saved',
            title: 'saved',
            updatedAt: DateTime(2026),
            cwd: '/project',
          ),
        ),
        reconnect: () {
          reconnects++;
          return Server();
        },
      );
      events = [];
      kernel.events.listen(events.add);
      kernel.prepare();
      await pumpEventQueue();
      expect(
        historyEvents(events)
            .whereType<ItemUpserted>()
            .where((event) => event.item is UserMessageItem)
            .length,
        1,
      );
      kernel.release();
      kernel.prepare();
      kernel.prepare();
      await pumpEventQueue();
      expect(reconnects, 1);
      expect(kernel.health.status, KernelHealthStatus.ready);
      expect(
        historyEvents(events)
            .whereType<ItemUpserted>()
            .where((event) => event.item is UserMessageItem)
            .length,
        1,
      );
    },
  );

  test(
    'a saved session reopens after a single prepare call on each visit',
    () async {
      kernel.dispose();
      var reconnects = 0;
      kernel = CodexKernel(
        KernelRegistry.codex,
        Server(),
        context: KernelContext(
          cwd: '/project',
          resume: SessionRecord(
            id: 'saved',
            title: 'saved',
            updatedAt: DateTime(2026),
            cwd: '/project',
          ),
        ),
        reconnect: () {
          reconnects++;
          return Server();
        },
      );
      final transcript = <ItemUpserted>[];
      kernel.events.listen((event) {
        if (event is HistoryReplayed) {
          transcript.addAll(event.events.whereType<ItemUpserted>());
        }
      });
      kernel.prepare();
      await pumpEventQueue();
      expect(kernel.health.status, KernelHealthStatus.ready);
      for (var visit = 1; visit <= 3; visit++) {
        kernel.release();
        await kernel.stopped;
        kernel.prepare();
        await pumpEventQueue();
        expect(kernel.health.status, KernelHealthStatus.ready);
        expect(reconnects, visit);
      }
      expect(
        transcript.where((event) => event.item is UserMessageItem),
        hasLength(1),
      );
    },
  );

  test('history is visible before a slow model list finishes', () async {
    kernel.dispose();
    server = (Server.new)();
    server.delayed.add('model/list');
    kernel = CodexKernel(
      KernelRegistry.codex,
      server,
      context: KernelContext(
        cwd: '/project',
        resume: SessionRecord(
          id: 'saved',
          title: 'saved',
          updatedAt: DateTime(2026),
          cwd: '/project',
        ),
      ),
    );
    events = [];
    kernel.events.listen(events.add);
    kernel.prepare();
    await pumpEventQueue();
    expect(historyEvents(events).whereType<ItemUpserted>(), hasLength(2));
    expect(
      server.calls.map((call) => call['method']),
      contains('thread/resume'),
    );
    expect(kernel.health.status, KernelHealthStatus.starting);
    for (final reply in server.delayedReplies) {
      server.output.add(reply);
    }
    await pumpEventQueue();
    expect(kernel.health.status, KernelHealthStatus.ready);
  });

  test(
    'restored reasoning keeps summaries without inventing a duration',
    () async {
      kernel.dispose();
      server = Server();
      server.savedTurns = [
        {
          'id': 'old',
          'status': 'completed',
          'items': [
            {
              'id': 'reason',
              'type': 'reasoning',
              'summary': [
                '**检查串口配置**\n\n核对物理串口、TCP 端口与参数。',
                '**修正接口回调**\n\n将控制操作交给后台线程。',
              ],
              'content': ['Raw content is not the summary.'],
            },
            {'id': 'empty', 'type': 'reasoning', 'summary': <String>[]},
            {'id': 'answer', 'type': 'agentMessage', 'text': '已修正。'},
          ],
        },
      ];
      kernel = CodexKernel(
        KernelRegistry.codex,
        server,
        context: KernelContext(
          resume: SessionRecord(
            id: 'saved',
            title: 'saved',
            updatedAt: DateTime(2026),
            cwd: '/project',
          ),
        ),
      );
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.prepare();
      await pumpEventQueue();
      expect(transcript.length, 2);
      final thought = transcript.itemAt(0) as ThinkingItem;
      expect(thought.text, contains('检查串口配置'));
      expect(thought.text, contains('修正接口回调'));
      expect(thought.text, isNot(contains('Raw content')));
      expect(thought.seconds, isNull);
      expect(thought.startedAt, isNull);
      expect(thought.streaming, isFalse);
      expect(thought.summarized, isTrue);
      expect(transcript.hasStreamingItem, isFalse);
    },
  );

  test('the completed reasoning summary replaces partial deltas', () async {
    final transcript = Transcript();
    kernel.events.listen(transcript.apply);
    kernel.send(const KernelTurn(id: 'one', text: 'check'));
    await pumpEventQueue();
    server.notify('item/started', {
      'item': {'type': 'reasoning', 'id': 'reason', 'summary': <String>[]},
    });
    server.notify('item/reasoning/summaryTextDelta', {
      'itemId': 'reason',
      'summaryIndex': 0,
      'delta': '**未完成的标题',
    });
    final at = transcript.indexOf('reason')!;
    final live = transcript.itemAt(at) as ThinkingItem;
    expect(live.streaming, isTrue);
    expect(live.summarized, isTrue);
    server.notify('item/completed', {
      'item': {
        'type': 'reasoning',
        'id': 'reason',
        'summary': ['**核对共享端口**\n\n检查重复绑定与断线状态。'],
      },
    });
    final completed = transcript.itemAt(at) as ThinkingItem;
    expect(completed.text, '**核对共享端口**\n\n检查重复绑定与断线状态。');
    expect(completed.streaming, isFalse);
    expect(completed.seconds, 0);
  });

  test('empty completed reasoning leaves no placeholder row', () async {
    final transcript = Transcript();
    kernel.events.listen(transcript.apply);
    server.notify('item/started', {
      'item': {'type': 'reasoning', 'id': 'empty'},
    });
    expect(transcript.length, 1);
    server.notify('item/completed', {
      'item': {'type': 'reasoning', 'id': 'empty', 'summary': <String>[]},
    });
    expect(transcript.length, 0);
    expect(transcript.hasStreamingItem, isFalse);
  });

  test(
    'turn interruption preserves the reasoning summary received so far',
    () async {
      final transcript = Transcript();
      kernel.events.listen(transcript.apply);
      kernel.send(const KernelTurn(id: 'one', text: 'check'));
      await pumpEventQueue();
      server.notify('item/started', {
        'item': {'type': 'reasoning', 'id': 'reason'},
      });
      server.notify('item/reasoning/summaryTextDelta', {
        'itemId': 'reason',
        'summaryIndex': 0,
        'delta': '**检查中断恢复**\n\n保留已收到的摘要。',
      });
      server.notify('turn/completed', {
        'turn': {'id': 'server-1', 'status': 'interrupted'},
      });
      final thought = transcript.itemAt(1) as ThinkingItem;
      expect(thought.text, contains('保留已收到的摘要'));
      expect(thought.streaming, isFalse);
      expect(transcript.hasStreamingItem, isFalse);
    },
  );

  test('large history notifies the session once with settled items', () async {
    kernel.dispose();
    server = (Server.new)();
    server.savedTurns = [
      for (var n = 0; n < 2000; n++)
        {
          'id': 'old-$n',
          'status': 'completed',
          'items': [
            {
              'id': 'user-$n',
              'type': 'userMessage',
              'content': [
                {'type': 'text', 'text': 'Question $n'},
              ],
            },
            {'id': 'answer-$n', 'type': 'agentMessage', 'text': 'Answer $n'},
          ],
        },
    ];
    kernel = CodexKernel(
      KernelRegistry.codex,
      server,
      context: KernelContext(
        resume: SessionRecord(
          id: 'saved',
          title: 'saved',
          updatedAt: DateTime(2026),
          cwd: '/project',
        ),
      ),
    );
    final session = ChatSession(
      historyCount: 0,
      kernel: KernelDescriptor(
        id: 'saved',
        label: 'Saved',
        description: 'Saved conversation',
        icon: KernelRegistry.codex.icon,
        create: (_) => kernel,
      ),
    );
    addTearDown(session.dispose);
    final lengths = <int>[];
    final streaming = <bool>[];
    session.addListener(() {
      lengths.add(session.itemCount);
      streaming.add(session.isStreaming);
    });
    kernel.prepare();
    await pumpEventQueue();
    expect(session.itemCount, 4000);
    expect((session.itemAt(3999) as AssistantTextItem).text, 'Answer 1999');
    expect(lengths, everyElement(anyOf(0, 4000)));
    expect(lengths.length, lessThanOrEqualTo(4));
    expect(streaming, everyElement(false));
  });

  test('queued messages wait for completion and can be withdrawn', () async {
    kernel.send(const KernelTurn(id: 'one', text: 'one'));
    await pumpEventQueue();
    kernel.send(const KernelTurn(id: 'two', text: 'two'));
    kernel.send(const KernelTurn(id: 'three', text: 'three'));
    expect(await kernel.cancelQueued('three'), isTrue);
    expect(server.turns, 1);
    server.notify('turn/completed', {
      'turn': {'id': 'server-1', 'status': 'completed'},
    });
    await pumpEventQueue();
    expect(server.turns, 2);
    expect(events.whereType<TurnStarted>().map((event) => event.turnId), [
      'one',
      'two',
    ]);
  });

  test('questions are answered by their RPC ids and unknown requests fail promptly', () async {
    server.output.add({
      'id': 20,
      'method': 'item/tool/requestUserInput',
      'params': {
        'questions': [
          {
            'id': 'library',
            'header': 'Library',
            'question': 'Which?',
            'options': [
              {'label': 'A', 'description': 'one'},
            ],
          },
        ],
      },
    });
    kernel.answer(
      'question:20',
      const QuestionAnswer([
        ['A'],
      ]),
    );
    expect(server.calls.last['result'], {
      'answers': {
        'library': {
          'answers': ['A'],
        },
      },
    });
    server.output.add({
      'id': 21,
      'method': 'unsupported/request',
      'params': <String, Object?>{},
    });
    expect((server.calls.last['error'] as Map)['code'], -32601);
  });

  test('WSL UNC parsing preserves the distribution and Linux path', () {
    final project = wslProject(
      r'\\wsl.localhost\Ubuntu-24.04-dev\home\noxae\My Project',
    );
    expect(project?.distribution, 'Ubuntu-24.04-dev');
    expect(project?.path, '/home/noxae/My Project');
    expect(wslProject(r'\\wsl$\Ubuntu\home\dev')?.path, '/home/dev');
    expect(wslProject(r'C:\project'), isNull);
  });

  test('a missing executable fails pending RPCs and stops cleanly', () async {
    final transport = CodexProcessTransport(
      cwd: Directory.current.path,
      executable: '/missing-caocode-test-executable',
    );
    final client = CodexRpcClient(transport);
    final subscription = client.messages.listen((_) {}, onError: (Object _) {});
    try {
      await expectLater(client.initialize(), throwsA(isA<ProcessException>()));
      await transport.stopped.timeout(const Duration(seconds: 5));
    } finally {
      client.close();
      await subscription.cancel();
    }
  });

  test(
    'installed CLI accepts initialization, model discovery and thread listing',
    () async {
      final client = CodexRpcClient(
        localCodexTransport(cwd: Directory.current.path),
      );
      final subscription = client.messages.listen(
        (_) {},
        onError: (Object _) {},
      );
      try {
        await client.initialize();
        final models = await client.request('model/list', {'limit': 100});
        expect(models['data'], isNotEmpty);
        final threads = await client.request('thread/list', {
          'limit': 1,
          'sortKey': 'updated_at',
          'archived': false,
        });
        expect(threads['data'], isA<List>());
      } finally {
        client.close();
        await subscription.cancel();
        await client.stopped;
      }
    },
    skip: !const bool.fromEnvironment('CAOCODE_REAL_CLI'),
  );

  test(
    'installed CLI accepts effort settings and all four permission presets',
    () async {
      final client = CodexRpcClient(
        localCodexTransport(cwd: Directory.current.path),
      );
      final subscription = client.messages.listen(
        (_) {},
        onError: (Object _) {},
      );
      try {
        await client.initialize();
        final settings = await client.request('config/read', {
          'includeLayers': false,
          'cwd': Directory.current.path,
        });
        final config = settings['config'] as Map;
        final catalog = await client.request('model/list', {'limit': 100});
        final models = (catalog['data'] as List).cast<Map>();
        final choice = CodexEffort(LocalChoice([]), {}, () {});
        choice.configure(config);
        choice.loadModels(models);
        for (final option in codexPermissionOptions) {
          final policy = codexPermissionParams(option.id, [
            Directory.current.path,
          ], config);
          final started = await client.request('thread/start', {
            'cwd': Directory.current.path,
            'ephemeral': true,
            'model': ?choice.resolvedModel,
            'approvalPolicy': policy['approvalPolicy'],
            'approvalsReviewer': policy['approvalsReviewer'],
            if (policy['permissions'] case final String profile)
              'permissions': profile
            else
              'sandbox': switch ((policy['sandboxPolicy'] as Map)['type']) {
                'dangerFullAccess' => 'danger-full-access',
                'workspaceWrite' => 'workspace-write',
                _ => 'read-only',
              },
            'config': {
              'model_reasoning_effort': ?choice.selected,
              'sandbox_workspace_write': ?config['sandbox_workspace_write'],
            },
          });
          expect(started['approvalPolicy'], policy['approvalPolicy']);
          expect(started['approvalsReviewer'], policy['approvalsReviewer']);
          if (choice.selected case final effort?) {
            expect(started['reasoningEffort'], effort);
          }
        }
      } finally {
        client.close();
        await subscription.cancel();
        await client.stopped;
      }
    },
    skip: !const bool.fromEnvironment('CAOCODE_REAL_CLI'),
  );

  test(
    'installed CLI completes an ephemeral read-only model turn',
    () async {
      final reply = await askCodex(
        'Reply exactly CAOCODE_READY.',
        'Verify the connection.',
        location: Directory.current.path,
      );
      expect(reply.trim(), 'CAOCODE_READY');
    },
    skip: !const bool.fromEnvironment('CAOCODE_REAL_INFERENCE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
