import 'package:caocode/stash/stash_skill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the skill names the folder, lets it be read and edited, and says '
      'how a stash is written', () {
    final text = StashSkill.text('/Users/me/Caocode/Stash');
    final front = text.split('\n---\n').first;
    expect(front, startsWith('---\nname: caocode-stash\n'));
    // Quoted: " #12" would start a YAML comment.
    expect(
      RegExp(r'^description: "[^\n]*Stash #12[^\n]*"$', multiLine: true)
          .hasMatch(front),
      isTrue,
    );
    expect(front, contains('  - "Read(//Users/me/Caocode/Stash/**)"'));
    expect(front, contains('  - "Edit(//Users/me/Caocode/Stash/**)"'));
    expect(text, contains(StashSkill.marker));
    expect(text, contains(r'"thread": "${CLAUDE_SESSION_ID}"'));
    expect(text, contains(r'`$…$` and `$$…$$` math'));
    expect(text, contains('`/Users/me/Caocode/Stash/12.md`'));
    // Issues: linked by their link; never written to from here.
    expect(text, contains('| `issues` |'));
    expect(text, contains('Never comment on, close'));
  });

  test("Caocode's skill is written anew; one the user took over is not", () {
    final text = StashSkill.text('/a');
    expect(StashSkill.stale(null, text), isTrue);
    expect(StashSkill.stale(text, text), isFalse);
    expect(StashSkill.stale(StashSkill.text('/b'), text), isTrue);
    final own = text.replaceFirst(StashSkill.marker, '');
    expect(StashSkill.stale(own, text), isFalse);
  });
}
