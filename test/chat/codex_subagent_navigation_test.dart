import 'package:caocode/chat/agent_view.dart';
import 'package:caocode/chat/chat_feed.dart';
import 'package:caocode/chat/chat_history_view.dart';
import 'package:caocode/chat/chat_screen.dart';
import 'package:caocode/chat/chat_session.dart';
import 'package:caocode/chat/composer/composer.dart';
import 'package:caocode/chat/panels/interaction_panel.dart';
import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/kernel/codex/codex_kernel.dart';
import 'package:caocode/kernel/kernel_registry.dart';
import 'package:caocode/kernel/kernel_types.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel/codex_subagents_test.dart'
    show SubagentServer, spawn, savedTurn, settleProtocol;

void main() {
  late SubagentServer server;
  late CodexKernel kernel;
  late ChatSession session;

  Future<void> show(WidgetTester tester, {double width = 1000}) async {
    tester.view.physicalSize = Size(width, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
        description: '',
        create: (_) => kernel,
      ),
    );
    session.draft.content = Delta()..insert('Unsent parent draft\n');
    await tester.runAsync(() async {
      kernel.send(
        const KernelTurn(
          id: 'parent-turn',
          text: 'Delegate independent checks',
        ),
      );
      await settleProtocol();
    });
    for (final (id, name) in [
      ('one', 'Inspect widgets'),
      ('two', 'Review protocol'),
    ]) {
      server.notify('item/completed', {
        'threadId': 'thread',
        'item': spawn(id, prompt: name),
      });
      server.threads[id] = {
        'id': id,
        'agentNickname': name,
        'status': {'type': 'idle'},
      };
      server.pages[id] = {
        'data': [savedTurn('turn-$id', 'Answer from $name')],
        'nextCursor': null,
      };
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: [
          ...AppLocalizations.localizationsDelegates,
          FlutterQuillLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(session: session, windowTitleBar: false),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> choose(WidgetTester tester, String contains) async {
    await tester.tap(find.byKey(const ValueKey('subagent-switcher')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.textContaining(contains).last);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(settleProtocol);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    // Menu actions run after their route leaves and an end-of-frame; allow
    // the conversation's return animation to finish as well.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  }

  testWidgets(
    'switch across siblings and back without sending or losing the parent draft',
    (tester) async {
      await show(tester);
      final mainHistory = tester.state(find.byType(ChatHistoryView).first);
      final sent = server.calls
          .where((call) => call['method'] == 'turn/start')
          .length;
      await choose(tester, 'Codex · one');
      expect(session.openAgents, ['one']);
      expect(find.byType(SubagentHeader), findsOneWidget);
      expect(find.textContaining('Answer from Inspect widgets'), findsWidgets);
      expect(
        tester.widget<ChatHistoryView>(find.byType(ChatHistoryView).last).feed,
        isA<SubagentFeed>(),
      );
      expect(session.draft.content!.toJson(), [
        {'insert': 'Unsent parent draft\n'},
      ]);
      await choose(tester, 'Codex · two');
      expect(session.openAgents, ['two']);
      expect(find.textContaining('Answer from Review protocol'), findsWidgets);
      await choose(tester, 'Conversation');
      expect(session.openAgents, isEmpty);
      expect(find.byType(SubagentHeader), findsNothing);
      expect(
        tester.state(find.byType(ChatHistoryView).first),
        same(mainHistory),
      );
      expect(find.byType(ChatComposer), findsOneWidget);
      expect(session.draft.content!.toJson(), [
        {'insert': 'Unsent parent draft\n'},
      ]);
      expect(
        server.calls.where((call) => call['method'] == 'turn/start'),
        hasLength(sent),
      );
      expect(
        server.calls.where((call) => call['method'] == 'turn/interrupt'),
        isEmpty,
      );
      await close(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow child view offers retry and still shows attributed approval',
    (tester) async {
      await show(tester, width: 420);
      server.reject = 'thread/read';
      await choose(tester, 'Codex · one');
      expect(
        find.textContaining('Could not read subagent conversation'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      server.reject = null;
      await tester.tap(find.text('Retry'));
      await tester.runAsync(settleProtocol);
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining('Could not read subagent conversation'),
        findsNothing,
      );
      server.output.add({
        'id': 801,
        'method': 'item/commandExecution/requestApproval',
        'params': {'threadId': 'one', 'command': 'git status'},
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(InteractionPanel), findsOneWidget);
      expect(session.pendingInteraction!.title, contains('Inspect widgets'));
      await close(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
