import 'dart:async';
import 'dart:typed_data';

import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/kernel/codex/ask_codex.dart';
import 'package:caocode/kernel/codex/codex_rpc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'codex_test.dart' show Server;

void main() {
  test(
    'auxiliary images keep their names and use an ephemeral read-only turn',
    () async {
      final peer = Server();
      final reply = askCodex(
        'Describe the attachment.',
        'A captured requirement.',
        transport: peer,
        images: [
          (
            name: '界面.png',
            image: ImageAttachment(
              bytes: Uint8List.fromList([1, 2, 3]),
              mediaType: 'image/png',
            ),
          ),
        ],
        readable: const ['/attachments'],
      );
      await pumpEventQueue();
      Map params(String method) =>
          peer.calls.firstWhere((call) => call['method'] == method)['params']
              as Map;
      expect(params('thread/start')['ephemeral'], isTrue);
      expect(params('thread/start')['sandbox'], 'read-only');
      expect(
        params('thread/start')['developerInstructions'],
        contains('/attachments'),
      );
      expect(params('turn/start')['sandboxPolicy'], {'type': 'readOnly'});
      expect(params('turn/start')['approvalPolicy'], 'never');
      expect(params('turn/start')['input'], [
        {'type': 'text', 'text': 'A captured requirement.'},
        {'type': 'text', 'text': '[Picture: 界面.png]'},
        {'type': 'image', 'url': 'data:image/png;base64,AQID'},
      ]);
      peer.notify('item/completed', {
        'threadId': 'thread',
        'item': {'type': 'agentMessage', 'text': 'An attachment.'},
      });
      peer.notify('turn/completed', {
        'threadId': 'thread',
        'turn': {'status': 'completed'},
      });
      expect(await reply, 'An attachment.');
      expect(peer.output.isClosed, isTrue);
    },
  );

  test('cancelling an auxiliary request closes its transport', () async {
    final peer = Server();
    final cancel = Completer<void>();
    final reply = askCodex(
      'Polish.',
      'Some words.',
      transport: peer,
      cancel: cancel.future,
    );
    final expectation = expectLater(reply, throwsA(isA<CodexCancelled>()));
    await pumpEventQueue();
    cancel.complete();
    await expectation;
    expect(peer.output.isClosed, isTrue);
  });

  test(
    'initialization failure closes its transport and reaches the caller',
    () async {
      final peer = Server()..reject = 'initialize';
      await expectLater(
        askCodex('Polish.', 'Some words.', transport: peer),
        throwsA(isA<CodexRpcException>()),
      );
      expect(peer.output.isClosed, isTrue);
    },
  );
}
