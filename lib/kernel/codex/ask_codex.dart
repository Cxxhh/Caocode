import 'dart:async';

import 'codex_process.dart';
import 'codex_rpc.dart';

class CodexCancelled implements Exception {
  const CodexCancelled();
}

/// Auxiliary requests use CLI configuration and leave no persistent thread.
Future<String> askCodex(
  String instructions,
  String text, {
  String? location,
  String? model,
  Future<void>? cancel,
}) async {
  final client = CodexRpcClient(localCodexTransport(cwd: location));
  final completed = Completer<String>();
  final messages = <String, StringBuffer>{};
  String? threadId;
  String? lastMessage;
  var cancelled = false;
  final subscription = client.messages.listen(
    (message) {
      final params = message['params'] as Map?;
      if (params == null) return;
      if (threadId != null &&
          params['threadId'] != null &&
          params['threadId'] != threadId) {
        return;
      }
      if (message.containsKey('id')) {
        client.transport.write({
          'id': message['id'],
          'error': {'code': -32601, 'message': '辅助请求不支持交互式工具'},
        });
        return;
      }
      switch (message['method']) {
        case 'item/agentMessage/delta':
          (messages[params['itemId'] as String] ??= StringBuffer()).write(
            params['delta'],
          );
        case 'item/completed':
          final item = params['item'] as Map?;
          if (item?['type'] == 'agentMessage') {
            lastMessage = item?['text'] as String?;
          }
        case 'turn/completed':
          if (completed.isCompleted) return;
          final turn = params['turn'] as Map;
          if (turn['status'] == 'completed') {
            completed.complete(
              lastMessage ?? messages.values.lastOrNull?.toString() ?? '',
            );
          } else {
            completed.completeError(
              CodexRpcException(
                (turn['error'] as Map?)?['message'] as String? ?? 'Codex 请求未完成',
              ),
            );
          }
      }
    },
    onError: (Object error) {
      if (!completed.isCompleted) completed.completeError(error);
    },
  );
  final reply = completed.future.timeout(const Duration(minutes: 2));
  // Initialization may fail before the caller awaits the turn result.
  unawaited(reply.then((_) {}, onError: (Object _) {}));
  if (cancel != null) {
    unawaited(
      cancel.then((_) {
        cancelled = true;
        if (!completed.isCompleted) {
          completed.completeError(const CodexCancelled());
        }
        client.close();
      }, onError: (Object _) {}),
    );
  }
  try {
    await client.initialize();
    if (cancelled) throw const CodexCancelled();
    final started = await client.request('thread/start', {
      'ephemeral': true,
      'sandbox': 'read-only',
      'approvalPolicy': 'never',
      'developerInstructions':
          '$instructions\nUse only the provided text. Do not run tools.',
      if (location != null) 'cwd': codexServerPath(location),
      if (model != null && model != 'default') 'model': model,
    });
    threadId = (started['thread'] as Map)['id'] as String;
    await client.request('turn/start', {
      'threadId': threadId,
      'input': [
        {'type': 'text', 'text': text},
      ],
      'approvalPolicy': 'never',
      'sandboxPolicy': {'type': 'readOnly'},
    });
    return await reply;
  } on Object {
    if (cancelled) throw const CodexCancelled();
    rethrow;
  } finally {
    if (!completed.isCompleted) {
      completed.completeError(const CodexRpcException('请求已关闭'));
    }
    client.close();
    await subscription.cancel();
    await client.stopped;
  }
}
