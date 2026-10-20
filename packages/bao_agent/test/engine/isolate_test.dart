import 'dart:io';

import 'package:bao_agent/bao_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_api.dart';
import '../support/fake_model.dart';

/// The engine as the app runs it: in an isolate of its own, on the API
/// over HTTP.
void main() {
  late FakeApi api;
  late String root;

  setUp(() async {
    api = await FakeApi.start();
    root = Directory.systemTemp
        .createTempSync('bao_isolate_')
        .resolveSymbolicLinksSync();
    Directory(p.join(root, 'project')).createSync();
    Directory(p.join(root, 'config')).createSync();
  });

  tearDown(() async {
    await api.close();
    Directory(root).deleteSync(recursive: true);
  });

  EngineOptions options({Map<String, String> env = const {}}) => EngineOptions(
    cwd: p.join(root, 'project'),
    configDir: p.join(root, 'config'),
    environment: {
      'HOME': root,
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      'ANTHROPIC_BASE_URL': api.baseUrl,
      'ANTHROPIC_API_KEY': 'sk-isolate',
      ...env,
    },
  );

  Map<String, Object?> user(String text) => {
    'type': 'user',
    'uuid': 'u-$text',
    'message': {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
    'parent_tool_use_id': null,
    'session_id': '',
  };

  test('a turn, a tool, and closing', () async {
    api.model.script.addAll([
      Reply.tool('Write', {
        'file_path': p.join(root, 'project', 'out.txt'),
        'content': 'from the isolate',
      }),
      Reply.text('wrote it'),
    ]);
    final agent = await AgentIsolate.spawn(options(), debugName: 'test');
    final messages = <Map<String, Object?>>[];
    agent.messages.listen((m) {
      messages.add(m);
      // Permission asked: allowed.
      if (m['type'] == 'control_request') {
        final request = m['request'] as Map;
        agent.write({
          'type': 'control_response',
          'response': {
            'subtype': 'success',
            'request_id': m['request_id'],
            'response': {'behavior': 'allow', 'updatedInput': request['input']},
          },
        });
      }
    });
    final result = agent.messages.firstWhere((m) => m['type'] == 'result');
    agent.write(user('write'));
    expect(
      (await result.timeout(const Duration(seconds: 30)))['result'],
      'wrote it',
    );
    expect(
      File(p.join(root, 'project', 'out.txt')).readAsStringSync(),
      'from the isolate',
    );
    expect(api.headers.first['x-api-key'], 'sk-isolate');
    expect(messages.first['type'], 'system');
    agent.close();
    await agent.exited.timeout(const Duration(seconds: 20));
    expect(agent.errors, isEmpty);
    // Written to after it ended: nothing happens.
    agent.write(user('late'));
  });

  test('end_session ends the isolate', () async {
    final agent = await AgentIsolate.spawn(options());
    agent.write({
      'type': 'control_request',
      'request_id': 'r1',
      'request': {'subtype': 'end_session'},
    });
    await agent.exited.timeout(const Duration(seconds: 20));
  });

  test('no key: the turn says how to set one up', () async {
    final agent = await AgentIsolate.spawn(
      options(env: {'ANTHROPIC_API_KEY': ''}),
    );
    final result = agent.messages.firstWhere((m) => m['type'] == 'result');
    agent.write(user('hi'));
    final ended = await result.timeout(const Duration(seconds: 30));
    expect(ended['is_error'], isTrue);
    expect(ended['result'], contains('ANTHROPIC_API_KEY'));
    agent.close();
    await agent.exited;
  });
}
