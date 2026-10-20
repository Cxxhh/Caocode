import 'dart:convert';

import 'package:bao_agent/bao_agent.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  late Harness h;

  tearDown(() => h.dispose());

  /// The agent's first request in a session on [model].
  Future<ModelRequest> asked(
    String model, {
    String? effort,
    String? thinkingDisplay,
    Map<String, Object?> settings = const {},
    Map<String, String> environment = const {},
  }) async {
    h = await Harness.start(
      model: model,
      effort: effort,
      thinkingDisplay: thinkingDisplay,
      settings: settings,
      environment: environment,
      script: [Reply.text('ok')],
    );
    await h.turn('hi');
    return h.model.turns.first;
  }

  test('a model of the newest: its own output, effort and thinking, '
      'and the betas for them', () async {
    final request = await asked('claude-sonnet-5-5');
    expect(request.body['max_tokens'], 128000);
    expect(request.body['output_config'], {'effort': 'medium'});
    expect(request.body['thinking'], {'type': 'adaptive'});
    expect(request.body['context_management'], {
      'edits': [
        {'type': 'clear_thinking_20251015', 'keep': 'all'},
      ],
    });
    expect(request.betas, [
      'interleaved-thinking-2025-05-14',
      'context-management-2025-06-27',
      'effort-2025-11-24',
    ]);
    // Nothing of Claude Code's own.
    expect(request.betas.where((b) => b.startsWith('claude-code')), isEmpty);
  });

  test('the effort chosen, and thinking shown as the host asks', () async {
    final request = await asked(
      'claude-opus-5-5',
      effort: 'max',
      thinkingDisplay: 'summarized',
    );
    expect(request.body['output_config'], {'effort': 'max'});
    expect(request.body['thinking'], {
      'type': 'adaptive',
      'display': 'summarized',
    });
  });

  test('a model that thinks on a budget: thinking on unless turned off, '
      'all the output can spare', () async {
    final request = await asked('claude-sonnet-4-5-20250929');
    expect(request.body['max_tokens'], 32000);
    expect(request.body['thinking'], {
      'type': 'enabled',
      'budget_tokens': 31999,
    });
    expect(request.body['output_config'], isNull);
    await h.dispose();

    final off = await asked(
      'claude-haiku-4-5-20251001',
      settings: {'alwaysThinkingEnabled': false},
    );
    expect(off.body['thinking'], isNull);
    expect(off.body['context_management'], isNull);
    expect(off.betas, isEmpty);
  });

  test("a provider's model: nothing it may not take", () async {
    final request = await asked('some-provider-model');
    expect(request.body['max_tokens'], 32000);
    expect(request.body['thinking'], isNull);
    expect(request.body['output_config'], isNull);
    expect(request.body['context_management'], isNull);
    expect(request.betas, isEmpty);
    await h.dispose();

    // Unless told it takes an effort.
    final told = await asked(
      'some-provider-model',
      effort: 'low',
      environment: {'CLAUDE_CODE_ALWAYS_ENABLE_EFFORT': '1'},
    );
    expect(told.body['output_config'], {'effort': 'low'});
    expect(told.betas, isEmpty);
  });

  test('what the provider refuses is left out, the rest kept', () async {
    h = await Harness.start(
      model: 'claude-opus-4-8',
      thinkingDisplay: 'summarized',
      script: [
        Reply.failing(
          const ApiError(
            'Unexpected value(s) for the anthropic-beta header',
            status: 400,
          ),
        ),
        Reply.failing(
          const ApiError(
            'thinking.display: Extra inputs are not permitted',
            status: 400,
          ),
        ),
        Reply.text('fine'),
      ],
    );
    await h.turn('hi');
    expect(h.lastResult['result'], 'fine');
    final [first, second, third] = h.model.turns;
    expect(first.betas, contains('context-management-2025-06-27'));
    expect(second.betas, isEmpty);
    expect(second.body['context_management'], isNull);
    expect(second.body['thinking'], containsPair('display', 'summarized'));
    expect(third.body['thinking'], {'type': 'adaptive'});
    expect(jsonEncode(third.body['output_config']), contains('high'));
  });
}
