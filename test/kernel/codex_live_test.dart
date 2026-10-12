import 'dart:async';
import 'dart:io';

import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/codex/codex_catalog.dart';
import 'package:baocode/kernel/codex/codex_kernel.dart';
import 'package:baocode/kernel/codex/codex_process_io.dart';
import 'package:baocode/kernel/codex/codex_rpc.dart';
import 'package:baocode/kernel/kernel_event.dart';
import 'package:baocode/kernel/kernel_registry.dart';
import 'package:baocode/kernel/kernel_types.dart';
import 'package:baocode/search/codex_conversation_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real CLI streams a turn, persists it and restores its history',
    () async {
      final temporary = Directory.systemTemp.createTempSync('caocode-live-');
      final cwd =
          Platform.environment['CAOCODE_WSL_TEST_CWD'] ?? temporary.path;
      final kernel = CodexKernel(
        KernelRegistry.codex,
        localCodexTransport(cwd: cwd),
        context: KernelContext(cwd: cwd, settings: const {'mode': 'ask'}),
      );
      final items = <ItemCompleted>[];
      final ended = Completer<void>();
      final subscription = kernel.events.listen((event) {
        if (event is ItemCompleted) items.add(event);
        if (event is TurnEnded && !ended.isCompleted) ended.complete();
      });
      String? id;
      try {
        kernel.send(
          const KernelTurn(
            id: 'smoke',
            text: 'Reply exactly CAOCODE_READY. Do not run tools.',
          ),
        );
        await ended.future.timeout(const Duration(minutes: 2));
        expect(kernel.health.status, KernelHealthStatus.ready);
        expect(
          items
              .map((event) => event.item)
              .whereType<AssistantTextItem>()
              .last
              .text
              .trim(),
          'CAOCODE_READY',
        );
        id = kernel.sessionId;
        expect(id, isNotNull);
        kernel.dispose();
        await kernel.stopped;
        const catalog = CodexCatalog();
        final record = (await catalog.sessionsIn(cwd))
            .singleWhere((record) => record.id == id);
        final saved = await catalog.read(record);
        expect(codexThreadText(saved), contains('CAOCODE_READY'));
        final restored = CodexKernel(
          KernelRegistry.codex,
          localCodexTransport(cwd: cwd),
          context: KernelContext(cwd: cwd, resume: record),
        );
        final history = <ItemUpserted>[];
        final ready = Completer<void>();
        final restoredSubscription = restored.events.listen((event) {
          if (event is ItemUpserted) history.add(event);
          if (restored.health.status == KernelHealthStatus.ready &&
              !ready.isCompleted) {
            ready.complete();
          }
        });
        try {
          restored.prepare();
          await ready.future.timeout(const Duration(seconds: 30));
          expect(
            history
                .map((event) => event.item)
                .whereType<UserMessageItem>()
                .single
                .text,
            contains('CAOCODE_READY'),
          );
        } finally {
          restored.dispose();
          await restoredSubscription.cancel();
          await restored.stopped;
        }
      } finally {
        id ??= kernel.sessionId;
        kernel.dispose();
        await subscription.cancel();
        await kernel.stopped;
        if (id != null) {
          final rpc = CodexRpcClient(localCodexTransport(cwd: cwd));
          final listener = rpc.messages.listen((_) {}, onError: (Object _) {});
          try {
            await rpc.initialize();
            await rpc.request('thread/archive', {'threadId': id});
          } finally {
            rpc.close();
            await listener.cancel();
            await rpc.stopped;
          }
        }
        temporary.deleteSync();
      }
    },
    skip: !const bool.fromEnvironment('CAOCODE_LIVE_KERNEL'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
