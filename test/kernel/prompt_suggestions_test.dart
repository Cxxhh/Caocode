import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:caocode/kernel/claude_code/claude_code_transport.dart';
import 'package:caocode/kernel/kernel_types.dart';
import 'package:caocode/kernel/mock/mock_kernels.dart';
import 'package:caocode/kernel/prompt_suggestions.dart';

import '../kernel_test.dart' show FakeCli;

void main() {
  var suggests = true;
  setUp(() {
    suggests = true;
    PromptSuggestions.current = () => suggests;
  });
  tearDown(() => PromptSuggestions.current = () => true);

  ({ClaudeCodeKernel kernel, List<ClaudeLaunch> launches, List<FakeCli> clis})
  start() {
    final launches = <ClaudeLaunch>[];
    final clis = <FakeCli>[];
    final kernel = ClaudeCodeKernel(
      MockKernels.claudeCode,
      const KernelContext(cwd: '/p'),
      start: (launch) async {
        launches.add(launch);
        return clis.last;
      },
    );
    return (kernel: kernel, launches: launches, clis: clis);
  }

  test('the setting reads on unless set to false', () {
    expect(PromptSuggestions.enabled(null), isTrue);
    expect(PromptSuggestions.enabled(true), isTrue);
    expect(PromptSuggestions.enabled('off'), isTrue);
    expect(PromptSuggestions.enabled(false), isFalse);
  });

  test('turned off, Claude Code is started without them', () async {
    suggests = false;
    final (:kernel, :launches, :clis) = start();
    clis.add(FakeCli());
    kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
    await pumpEventQueue();
    expect(launches.single.promptSuggestions, isFalse);
    expect(launches.single.arguments, isNot(contains('--prompt-suggestions')));
    expect(
      clis.single.requests('initialize').single['promptSuggestions'],
      isFalse,
    );
    kernel.dispose();
  });

  test('turned off mid-conversation, none is offered, and the next message '
      'starts Claude Code again without them', () async {
    final (:kernel, :launches, :clis) = start();
    clis.add(FakeCli());
    kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
    await pumpEventQueue();
    expect(launches.single.arguments, contains('--prompt-suggestions'));
    clis.last
      ..push({'type': 'system', 'subtype': 'init', 'session_id': 's1'})
      ..push({'type': 'result', 'subtype': 'success', 'is_error': false});
    await pumpEventQueue();

    suggests = false;
    clis.last.push({'type': 'prompt_suggestion', 'suggestion': 'Run tests'});
    await pumpEventQueue();
    expect(kernel.promptSuggestion, isNull);

    final first = clis.last;
    clis.add(FakeCli());
    kernel.send(const KernelTurn(id: 'u2', text: 'go on'));
    await pumpEventQueue();
    expect(first.closed, isTrue);
    expect(launches, hasLength(2));
    expect(launches.last.resume, 's1');
    expect(launches.last.promptSuggestions, isFalse);
    expect(clis.last.users.single['uuid'], 'u2');
    kernel.dispose();
  });

  test('left as it was, the next message goes to the same process', () async {
    final (:kernel, :launches, :clis) = start();
    clis.add(FakeCli());
    kernel.send(const KernelTurn(id: 'u1', text: 'hi'));
    await pumpEventQueue();
    clis.last
      ..push({'type': 'system', 'subtype': 'init', 'session_id': 's1'})
      ..push({'type': 'result', 'subtype': 'success', 'is_error': false});
    await pumpEventQueue();
    kernel.send(const KernelTurn(id: 'u2', text: 'go on'));
    await pumpEventQueue();
    expect(launches, hasLength(1));
    expect(clis.single.users.map((u) => u['uuid']), ['u1', 'u2']);
    kernel.dispose();
  });
}
