import 'dart:async';
import 'dart:convert';

import '../../chat/chat_models.dart' show ImageAttachment;

import 'codex_process.dart';
import 'codex_rpc.dart';
import 'codex_transport.dart';

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
  List<({String name, ImageAttachment image})> images = const [],
  List<String> readable = const [],
  CodexTransport? transport,
}) async {
  final client = CodexRpcClient(
    transport ?? localCodexTransport(cwd: location),
  );
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
          '$instructions\n${readable.isEmpty ? 'Use only the provided text and images. Do not run tools.' : 'You may read the supplied attachments under these folders: ${readable.map(codexServerPath).join(', ')}. Use only read-only file commands. Do not modify files, access the network, or run other tools.'}',
      if (location != null) 'cwd': codexServerPath(location),
      if (model != null && model != 'default') 'model': model,
    });
    threadId = (started['thread'] as Map)['id'] as String;
    await client.request('turn/start', {
      'threadId': threadId,
      'input': [
        {'type': 'text', 'text': text},
        for (final (:name, :image) in images) ...[
          {'type': 'text', 'text': '[Picture: $name]'},
          {
            'type': 'image',
            'url':
                'data:${image.mediaType};base64,${base64Encode(image.bytes)}',
          },
        ],
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
