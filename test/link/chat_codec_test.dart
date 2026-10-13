import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/link/chat_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'restored Codex summaries stay completed without an invented duration',
    () {
      const item = ThinkingItem(
        text:
            '**Check callbacks**\n\nMove control operations off the UI thread.',
        tokens: 0,
        summarized: true,
        streaming: false,
      );
      final decoded = ChatCodec.decode(ChatCodec.encode(item))! as ThinkingItem;
      expect(decoded.text, item.text);
      expect(decoded.summarized, isTrue);
      expect(decoded.streaming, isFalse);
      expect(decoded.seconds, isNull);
      expect(decoded.startedAt, isNull);
    },
  );

  test('older thoughts still infer completion from a recorded duration', () {
    final decoded =
        ChatCodec.decode({
              't': 'thinking',
              'text': 'Done',
              'tokens': 3,
              'seconds': 4,
            })!
            as ThinkingItem;
    expect(decoded.streaming, isFalse);
    expect(decoded.summarized, isFalse);
  });

  test('a timed turn keeps the known usage across a phone update', () {
    const item = UserMessageItem(
      text: 'Fix the callback',
      worked: Duration(seconds: 45),
      usage: TurnUsage(
        inputTokens: 1200,
        outputTokens: 300,
        tokensPerSecond: 25,
      ),
    );
    final decoded =
        ChatCodec.decode(ChatCodec.encode(item))! as UserMessageItem;
    expect(decoded.worked, item.worked);
    expect(decoded.usage?.inputTokens, 1200);
    expect(decoded.usage?.outputTokens, 300);
    expect(decoded.usage?.tokensPerSecond, 25);
    expect(decoded.usage?.costUsd, isNull);
  });
}
