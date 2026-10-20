import 'package:bao_link/bao_link.dart';
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:caocode/chat/chat_session.dart' show ComposerMessage;
import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:caocode/link/chat_codec.dart';
import 'package:caocode/link/workspace_bridge.dart';
import 'package:caocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

/// A conversation of six turns (a prompt and an answer each), read three
/// at a time from its end: u4..u6, then u1..u3.
void main() {
  Map<String, Object?> prompt(String id) => {
    'type': 'user',
    'uuid': id,
    'message': {'role': 'user', 'content': id},
  };

  Map<String, Object?> answer(String id) => {
    'type': 'assistant',
    'uuid': 'a-$id',
    'message': {
      'id': 'm-$id',
      'role': 'assistant',
      'model': 'claude-opus-5-5',
      'content': [
        {'type': 'text', 'text': 'answer $id'},
      ],
    },
  };

  ClaudeHistoryPage page(List<String> ids, {String? earlier}) =>
      ClaudeHistoryPage([
        for (final id in ids) ...[prompt(id), answer(id)],
      ], earlier: earlier);

  final asked = <String?>[];

  late Workspace workspace;
  late WorkspaceBridge bridge;
  late LinkPeer phone;
  late String id;
  final updates = <LinkSessionUpdate>[];

  setUp(() async {
    asked.clear();
    updates.clear();
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) => ClaudeCodeKernel(
        descriptor,
        KernelContext(
          cwd: '/p',
          resume: SessionRecord(
            id: 's',
            title: 't',
            updatedAt: DateTime(2026),
            cwd: '/p',
          ),
        ),
        start: (_) async => FakeCli(),
        readHistoryPage: (session, {required turns, before}) async {
          asked.add(before);
          return switch (before) {
            null => page(['u4', 'u5', 'u6'], earlier: 'u4'),
            'u4' => page(['u1', 'u2', 'u3']),
            _ => page(const []),
          };
        },
      ),
    );
    workspace = Workspace(
      projects: const [Project('p', '/p')],
      kernels: [descriptor],
    );
    final thread = workspace.startAgent(workspace.projects.first);
    thread.session.attach();
    await pumpEventQueue();
    id = WorkspaceBridge.idOf(thread);

    final (a, b) = MemoryLinkSocket.pair();
    final desktop = LinkIdentity.generate();
    final accepted = SecureChannel.accept(b, identity: desktop);
    final connected = await SecureChannel.connect(
      a,
      identity: LinkIdentity.generate(),
      serverKey: desktop.publicKey,
    );
    phone = LinkPeer(connected);
    bridge = WorkspaceBridge(
      workspace: workspace,
      peer: LinkPeer(await accepted),
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      throttle: const Duration(milliseconds: 10),
    )..start();
    final sub = phone.events
        .where((e) => e.name == LinkEvents.session)
        .listen(
          (e) => updates.add(
            LinkSessionUpdate.fromJson(e.data! as Map<String, Object?>),
          ),
        );
    addTearDown(sub.cancel);
  });

  tearDown(() {
    bridge.dispose();
    workspace.dispose();
  });

  Future<LinkSessionUpdate> open([int? window]) async =>
      LinkSessionUpdate.fromJson(
        (await bridge.handle(LinkMethods.open, {
              'session': id,
              'window': ?window,
            }))!
            as Map<String, Object?>,
      );

  List<String> texts(List<Object?> items) => [
    for (final json in items)
      switch (ChatCodec.decode(json)) {
        UserMessageItem(:final text) => text,
        _ => '-',
      },
  ];

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();
  }

  group('without a window', () {
    test('gives everything, and says nothing of earlier', () async {
      final opened = await open();
      expect(opened.start, 0);
      expect(opened.count, 6);
      expect(opened.earlier, isNull);
      expect(opened.toJson().containsKey('earlier'), isFalse);
    });

    test('an earlier call is refused', () async {
      await open();
      expect(
        bridge.handle(LinkMethods.earlier, {'session': id}),
        throwsA(isA<LinkRemoteException>()),
      );
    });

    test(
      'is sent all again from the start once the desktop prepends',
      () async {
        await open();
        final session = workspace.threads.first.session;
        await session.loadEarlier();
        await settle();
        final update = updates.last;
        expect(update.start, 0);
        expect(update.count, 12);
        expect(update.earlier, isNull);
      },
    );
  });

  group('with a window', () {
    test('gives the last items, counted from the first of them', () async {
      final opened = await open(4);
      expect(opened.start, 0);
      expect(opened.count, 4);
      expect(texts(opened.items), ['u5', '-', 'u6', '-']);
      expect(opened.earlier, isTrue);
    });

    test('a window beyond the items has all, and no earlier', () async {
      final opened = await open(100);
      expect(opened.count, 6);
      // u3's history is not read yet.
      expect(opened.earlier, isTrue);
    });

    test('a new item is a delta counted from the first', () async {
      await open(4);
      final session = workspace.threads.first.session;
      session.send(const ComposerMessage(text: 'more'));
      await settle();
      final update = updates.last;
      expect(update.start, 4);
      expect(update.count, greaterThan(4));
      expect(texts(update.items).first, 'more');
    });

    test(
      'the desktop reading earlier changes nothing but what is known',
      () async {
        await open(4);
        final session = workspace.threads.first.session;
        await session.loadEarlier();
        await settle();
        // Nothing of the phone's items changed: no update, or one of nothing.
        for (final update in updates) {
          expect(update.items, isEmpty);
          expect(update.count, 4);
        }
        // Its next item lands after the window, not at the shifted index.
        session.send(const ComposerMessage(text: 'more'));
        await settle();
        expect(updates.last.start, 4);
      },
    );

    test('earlier gives the items before, oldest first', () async {
      await open(4);
      final reply =
          (await bridge.handle(LinkMethods.earlier, {
                'session': id,
                'count': 2,
              }))!
              as Map<String, Object?>;
      expect(texts(reply['items']! as List), ['u4', '-']);
      expect(reply['earlier'], isTrue);
      final more =
          (await bridge.handle(LinkMethods.earlier, {'session': id}))!
              as Map<String, Object?>;
      // The window reached the start: the desktop read earlier ones.
      expect(asked, [null, 'u4']);
      expect(texts(more['items']! as List), [
        'u1', '-', 'u2', '-', 'u3', '-', //
      ]);
      expect(more['earlier'], isFalse);
    });

    test('deltas stay right after earlier', () async {
      await open(2);
      await bridge.handle(LinkMethods.earlier, {'session': id, 'count': 4});
      updates.clear();
      final session = workspace.threads.first.session;
      session.send(const ComposerMessage(text: 'more'));
      await settle();
      // 2 + 4 items now; the new one comes right after them.
      expect(updates.last.start, 6);
      expect(texts(updates.last.items).first, 'more');
    });

    test(
      'earlier reads the history when the window reaches the first',
      () async {
        await open(6);
        expect(asked, [null]);
        final reply =
            (await bridge.handle(LinkMethods.earlier, {
                  'session': id,
                  'count': 4,
                }))!
                as Map<String, Object?>;
        expect(asked, [null, 'u4']);
        expect(texts(reply['items']! as List), ['u2', '-', 'u3', '-']);
        expect(reply['earlier'], isTrue);
      },
    );

    test('earlier of a session not followed is refused', () async {
      expect(
        bridge.handle(LinkMethods.earlier, {'session': id}),
        throwsA(isA<LinkRemoteException>()),
      );
    });
  });

  test('a plan is not started while none awaits', () async {
    await open();
    expect(
      bridge.handle(LinkMethods.startPlan, {'session': id}),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.notFound,
        ),
      ),
    );
  });
}
