import 'dart:async';

import 'package:caocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const call = ClaudeSdkCall(cwd: '/p', sessionId: 's');

  tearDown(() => ClaudeSdkTools.unregister('echo'));

  test('no tools, no server', () {
    expect(ClaudeSdkTools.any, isFalse);
    expect(ClaudeSdkTools.servers, isEmpty);
  });

  test('a tool always loaded says so, not to be deferred', () async {
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'echo',
        description: 'Says it back.',
        inputSchema: const {'type': 'object'},
        alwaysLoad: true,
        run: (input, call) async => '',
      ),
    );
    final list = await ClaudeSdkTools.handle({
      'id': 1,
      'method': 'tools/list',
    }, call);
    final tools = (list['result'] as Map)['tools'] as List;
    expect(tools.single, containsPair('_meta', {'anthropic/alwaysLoad': true}));
  });

  test('says its features\' instructions as it is initialized', () async {
    Future<Map> init() async =>
        (await ClaudeSdkTools.handle({
              'id': 0,
              'method': 'initialize',
            }, call))['result']
            as Map;

    expect((await init()).containsKey('instructions'), isFalse);
    ClaudeSdkTools.instruct('a', 'Do A.');
    ClaudeSdkTools.instruct('b', 'Do B.');
    expect((await init())['instructions'], 'Do A.\n\nDo B.');
    ClaudeSdkTools.instruct('a', null);
    ClaudeSdkTools.instruct('b', null);
    expect((await init()).containsKey('instructions'), isFalse);
  });

  test('lists and calls its tools, failures as errors', () async {
    ClaudeSdkTools.register(
      ClaudeSdkTool(
        name: 'echo',
        description: 'Says it back.',
        inputSchema: const {'type': 'object'},
        run: (input, call) async {
          if (input['fail'] == true) throw StateError('no');
          return '${input['text']} in ${call.cwd}';
        },
      ),
    );
    expect(ClaudeSdkTools.servers, ['caocode']);

    final init = await ClaudeSdkTools.handle({
      'jsonrpc': '2.0',
      'id': 0,
      'method': 'initialize',
      'params': {'protocolVersion': '2025-06-18'},
    }, call);
    expect((init['result'] as Map)['protocolVersion'], '2025-06-18');

    final list = await ClaudeSdkTools.handle({
      'id': 1,
      'method': 'tools/list',
    }, call);
    final tools = (list['result'] as Map)['tools'] as List;
    expect(tools.single, containsPair('name', 'echo'));
    expect((tools.single as Map).containsKey('_meta'), isFalse);

    final ok = await ClaudeSdkTools.handle({
      'id': 2,
      'method': 'tools/call',
      'params': {
        'name': 'echo',
        'arguments': {'text': 'hi'},
      },
    }, call);
    expect(ok['id'], 2);
    expect(ok['result'], {
      'content': [
        {'type': 'text', 'text': 'hi in /p'},
      ],
    });

    final failed = await ClaudeSdkTools.handle({
      'id': 3,
      'method': 'tools/call',
      'params': {
        'name': 'echo',
        'arguments': {'fail': true},
      },
    }, call);
    expect((failed['result'] as Map)['isError'], isTrue);

    final unknown = await ClaudeSdkTools.handle({
      'id': 4,
      'method': 'resources/list',
    }, call);
    expect((unknown['error'] as Map)['code'], -32601);
  });

  test(
    'a call is given up as the agent cancels it, or as the turn stops',
    () async {
      ClaudeSdkTools.register(
        ClaudeSdkTool(
          name: 'echo',
          description: 'Waits.',
          inputSchema: const {'type': 'object'},
          run: (input, call) async {
            await call.cancelled;
            return 'given up';
          },
        ),
      );
      Future<String> answered(Future<Map<String, Object?>> answer) async =>
          (((await answer)['result'] as Map)['content'] as List).single['text']
              as String;

      final cancelled = ClaudeSdkTools.handle({
        'id': 7,
        'method': 'tools/call',
        'params': {'name': 'echo', 'arguments': <String, Object?>{}},
      }, call);
      // Another session's call of the same id is not this one.
      await ClaudeSdkTools.handle({
        'method': 'notifications/cancelled',
        'params': {'requestId': 7},
      }, const ClaudeSdkCall(cwd: '/p', sessionId: 'other'));
      await ClaudeSdkTools.handle({
        'method': 'notifications/cancelled',
        'params': {'requestId': 7},
      }, call);
      expect(await answered(cancelled), 'given up');

      final turn = Completer<void>();
      final stopped = ClaudeSdkTools.handle({
        'id': 8,
        'method': 'tools/call',
        'params': {'name': 'echo', 'arguments': <String, Object?>{}},
      }, ClaudeSdkCall(cwd: '/p', sessionId: 's', cancelled: turn.future));
      turn.complete();
      expect(await answered(stopped), 'given up');
    },
  );
}
