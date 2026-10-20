import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/chat/widgets/thinking_section.dart';

void main() {
  group('a summarized thought', () {
    test('is headed by its title, the rest its body', () {
      expect(thoughtSummary('**Planning the fix**\nLooking at a.dart.'), (
        title: 'Planning the fix',
        body: 'Looking at a.dart.',
      ));
    });

    test('of many parts, by its latest part\'s title, all titles in it', () {
      expect(
        thoughtSummary('**Reading**\n\nThe driver.\n\n**Planning**\n\nFour.'),
        (
          title: 'Planning',
          body: 'Reading\n\nThe driver.\n\nPlanning\n\nFour.',
        ),
      );
    });

    test('is none without a bold first line', () {
      expect(thoughtSummary('Just thinking.'), isNull);
    });
  });

  test('a long thought tells its minutes', () {
    expect(thinkingParts(185), ('Thought', '3m 5s'));
    expect(thinkingParts(12), ('Thought', '12s'));
  });
}
