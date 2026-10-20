import 'package:caocode/kernel/claude_code/claude_haiku.dart'
    show ClaudeHaikuCancelled;
import 'package:caocode/stash/stash_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => stashClarifier = null);

  const note = '这里的滚动条不对 [/s/10/shot.png]';

  /// The model answering [replies] in turn, the prompts it was asked kept.
  List<String> answer(List<String> replies) {
    final asked = <String>[];
    stashClarifier =
        (system, prompt, {pictures = const [], cancellation}) async {
          asked.add(prompt);
          return replies[asked.length - 1];
        };
    return asked;
  }

  test('a rewrite that keeps its markers is taken at once', () async {
    final asked = answer(['对话时间线左侧的滚动条拖动时会跳 [/s/10/shot.png]']);
    expect(await clarifyStashText(note), '对话时间线左侧的滚动条拖动时会跳 [/s/10/shot.png]');
    expect(asked, hasLength(1));
  });

  test('a picture described in place of its marker: asked again, saying '
      'so', () async {
    final asked = answer([
      '[图片：/s/10/shot.png]（截图中红框标出了左侧滚动条）这里的滚动条不对',
      '对话时间线左侧的滚动条不对 [/s/10/shot.png]',
    ]);
    expect(await clarifyStashText(note), '对话时间线左侧的滚动条不对 [/s/10/shot.png]');
    expect(asked, hasLength(2));
    expect(
      asked.last,
      contains(
        'It lost or changed these markers: '
        '[/s/10/shot.png]',
      ),
    );
    expect(asked.last, contains('<rewrite>'));
  });

  test('asked again no better: the first kept (its marker put after it '
      'later)', () async {
    answer(['滚动条不对（截图见左侧）', '[Picture: /s/10/shot.png] 滚动条不对']);
    expect(await clarifyStashText(note), '滚动条不对（截图见左侧）');
  });

  test('cancellation does not ask again after an unusable answer', () async {
    final signal = StashClarifyCancellation();
    var asked = 0;
    stashClarifier =
        (system, prompt, {pictures = const [], cancellation}) async {
          asked++;
          expect(cancellation, same(signal));
          signal.cancel();
          return '滚动条不对';
        };
    await expectLater(
      clarifyStashText(note, cancellation: signal),
      throwsA(isA<ClaudeHaikuCancelled>()),
    );
    expect(asked, 1);
  });
}
