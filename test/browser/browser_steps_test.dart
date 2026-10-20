import 'dart:convert';

import 'package:caocode/browser/browser_steps.dart';
import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/kernel/claude_code/claude_code_translator.dart';
import 'package:caocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:caocode/kernel/transcript.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A 1×1 PNG.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

const _report = '''
Web Vitals (of the page as loaded):
  LCP: 2710 ms (needs improvement) — img#hero
  CLS: 0.012 (good)
  FCP: 380 ms (good)
  TTFB: 12 ms (good)
  DOMContentLoaded: 300 ms, load: 900 ms
  Resources: 12

Page now:
  JS heap: 1.2 MB used of 2.0 MB

Main thread: busy 300 ms; scripting 200 ms, rendering 50 ms, parsing 10 ms
  No long task (50 ms or more).

Trace: /tmp/caocode-traces/trace-1.json (12.0 kB; DevTools › Performance › Load profile opens it)''';

void main() {
  group('a call of a browser tool', () {
    setUp(() {
      for (final name in ['browser_click', 'browser_screenshot']) {
        ClaudeSdkTools.register(
          ClaudeSdkTool(
            name: name,
            description: '',
            inputSchema: const {},
            run: (input, call) async => '',
            kind: ToolKind.browser,
            summary: (input, output) => browserStepSummary(name, input, output),
          ),
        );
      }
    });
    tearDown(() {
      ClaudeSdkTools.unregister('browser_click');
      ClaudeSdkTools.unregister('browser_screenshot');
    });

    late Transcript transcript;
    late ClaudeTranslator translator;
    void call(String id, String name, Map<String, Object?> input) {
      translator.translate({
        'type': 'assistant',
        'message': {
          'id': 'm$id',
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
          ],
        },
      });
    }

    void answer(String id, List<Object?> content) => translator.translate({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': [
          {'type': 'tool_result', 'tool_use_id': id, 'content': content},
        ],
      },
    });

    setUp(() {
      transcript = Transcript();
      var seq = 0;
      translator = ClaudeTranslator(
        emit: transcript.apply,
        nextSeq: () => ++seq,
      );
    });

    test('is a browser step, about what it acted on', () {
      call('c1', 'mcp__caocode__browser_click', {'tabId': 3, 'ref': 12});
      var step = transcript.itemAt(0) as ToolCallItem;
      expect(step.kind, ToolKind.browser);
      expect(step.tool, 'browser_click');
      expect(step.status, ToolStatus.running);
      expect(step.label, isNull, reason: 'its verb is the tool’s');
      expect(step.target, '[12]');
      answer('c1', [
        {'type': 'text', 'text': 'Clicked button "Sign in".'},
      ]);
      step = transcript.itemAt(0) as ToolCallItem;
      expect(step.target, '“Sign in”', reason: 'the element, once known');
      expect(step.input['tabId'], 3);
    });

    test('says what the agent said it does', () {
      call('c1', 'mcp__caocode__browser_click', {
        'tabId': 3,
        'ref': 12,
        'description': '点击登录按钮',
      });
      final step = transcript.itemAt(0) as ToolCallItem;
      expect(step.label, '', reason: 'the line, whole');
      expect(step.target, '点击登录按钮');
    });

    test('keeps the pictures it returned', () {
      call('s1', 'mcp__caocode__browser_screenshot', {'tabId': 3});
      answer('s1', [
        {
          'type': 'image',
          'source': {'type': 'base64', 'data': _png, 'media_type': 'image/png'},
        },
      ]);
      final step = transcript.itemAt(0) as ToolCallItem;
      expect(step.images.single.bytes, base64Decode(_png));
      expect(step.images.single.mediaType, 'image/png');
    });

    test('of another MCP server stays an MCP step', () {
      call('x1', 'mcp__other__browser_click', {'ref': 1});
      final step = transcript.itemAt(0) as ToolCallItem;
      expect(step.kind, ToolKind.mcp);
    });
  });

  test('a step is about the page, the element, the key', () {
    expect(
      browserStepSummary('browser_open', {
        'url': 'https://www.example.com/',
      }, null),
      'example.com',
    );
    expect(
      browserStepSummary('browser_navigate', {
        'tabId': 1,
        'action': 'back',
      }, '[1] Example Domain — https://example.com/'),
      'Example Domain',
    );
    expect(
      browserStepSummary('browser_snapshot', {
        'tabId': 1,
      }, 'Title: Live\nURL: http://x/\n'),
      'Live',
    );
    expect(
      browserStepSummary('browser_type', {'tabId': 1, 'text': 'hi'}, null),
      '“hi”',
    );
    expect(
      browserStepSummary('browser_type', {
        'tabId': 1,
        'text': 'hi',
        'ref': 2,
      }, 'Typed into input "Search".'),
      '“Search”',
    );
    expect(
      browserStepSummary('browser_click', {
        'tabId': 1,
        'x': 10.4,
        'y': 20,
      }, 'Clicked at (10, 20).'),
      '(10, 20)',
    );
    expect(
      browserStepSummary('browser_click', {
        'tabId': 1,
        'text': 'Reply',
        'near': 'bob',
      }, null),
      '“Reply”',
      reason: 'its words, while it runs',
    );
    expect(
      browserStepSummary(
        'browser_click',
        {'tabId': 1, 'text': 'Reply'},
        'Clicked button "Reply" [4].\nAppeared:\n  [8] textbox "Reply to bob"',
      ),
      '“Reply”',
    );
    expect(
      browserStepSummary('browser_type', {
        'tabId': 1,
        'text': 'yo',
        'into': 'Reply to alice',
      }, 'Typed into textbox "Reply to alice" [9], then pressed Enter.'),
      '“Reply to alice”',
    );
    expect(
      browserStepSummary('browser_act', {
        'tabId': 1,
        'steps': [
          {'action': 'click', 'text': 'Reply', 'near': 'alice'},
          {'action': 'type', 'into': 'Reply to alice', 'text': 'yo'},
          {'action': 'press', 'key': 'Enter'},
        ],
      }, null),
      '“Reply” → “yo” → Enter',
    );
    expect(
      browserStepSummary('browser_act', {
        'tabId': 1,
        'file': 'scripts/baidu-weather.json',
      }, null),
      'baidu-weather.json',
    );
    expect(
      browserStepSummary('browser_scroll', {'tabId': 1, 'deltaY': -300}, null),
      '↑ 300',
    );
    expect(
      browserStepSummary('browser_request', {
        'tabId': 1,
        'id': '7',
      }, 'POST http://127.0.0.1:8080/api\nType: Fetch'),
      'POST 127.0.0.1:8080/api',
    );
    expect(
      browserStepSummary('browser_network', {
        'tabId': 1,
        'type': 'XHR',
        'save': '/tmp/baidu.har',
      }, null),
      'XHR · → baidu.har',
    );
    expect(
      browserStepSummary('browser_emulate', {
        'tabId': 1,
        'cpu': 4,
        'network': 'fast3g',
        'device': 'none',
      }, null),
      'CPU 4× · fast3g',
    );
    expect(
      browserStepSummary('browser_performance', {'tabId': 1}, _report),
      'LCP 2.71 s · CLS 0.012',
    );
  });

  test('a performance report reads back', () {
    final report = PerformanceReport.parse(_report);
    expect(report.vitals.map((v) => (v.name, v.value, v.rating)), [
      ('LCP', '2.71 s', 'needs improvement'),
      ('CLS', '0.012', 'good'),
      ('FCP', '380 ms', 'good'),
      ('TTFB', '12 ms', 'good'),
    ]);
    expect(report.trace, '/tmp/caocode-traces/trace-1.json');
    expect(report.lines.first, '  DOMContentLoaded: 300 ms, load: 900 ms');
    expect(report.lines.last, '  No long task (50 ms or more).');
  });

  group('the step', () {
    Future<void> pump(WidgetTester tester, ToolCallItem item) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BrowserStep(item: item, expanded: true, onToggle: () {}),
            ),
          ),
        );

    testWidgets('says what it did, with the browser’s icon', (tester) async {
      await pump(
        tester,
        const ToolCallItem(
          kind: ToolKind.browser,
          tool: 'browser_click',
          input: {'tabId': 1, 'ref': 2},
          target: '“Sign in”',
          output: 'Clicked button "Sign in".',
        ),
      );
      expect(
        find.text('Clicked “Sign in”', findRichText: true),
        findsOneWidget,
      );
      // An action's answer says nothing more: nothing to open to.
      expect(find.text('Clicked button "Sign in".'), findsNothing);
    });

    testWidgets('opens to the Web Vitals', (tester) async {
      await pump(
        tester,
        const ToolCallItem(
          kind: ToolKind.browser,
          tool: 'browser_performance',
          input: {'tabId': 1},
          target: '',
          output: _report,
        ),
      );
      expect(find.text('2.71 s'), findsOneWidget);
      expect(find.text('LCP'), findsOneWidget);
      expect(find.textContaining('Show the trace'), findsOneWidget);
    });

    testWidgets('opens to the screenshot', (tester) async {
      await pump(
        tester,
        ToolCallItem(
          kind: ToolKind.browser,
          tool: 'browser_screenshot',
          input: const {'tabId': 1},
          target: '',
          images: [
            ImageAttachment(bytes: base64Decode(_png), mediaType: 'image/png'),
          ],
        ),
      );
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
