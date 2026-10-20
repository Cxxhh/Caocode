import 'package:caocode/settings/pages/general_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('patterns are split at commas, not those in a glob', () {
    expect(
      GeneralSettingsPage.excludePatterns(
        '.git, *.{log,tmp} ,build/**, [a,b].txt,, ',
      ),
      ['.git', '*.{log,tmp}', 'build/**', '[a,b].txt'],
    );
    expect(GeneralSettingsPage.excludePatterns(' , '), isNull);
    // An unclosed brace keeps the rest one pattern, as it was typed.
    expect(GeneralSettingsPage.excludePatterns('a{b,c'), ['a{b,c']);
  });
}
