import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/ide/ide_editor.dart';
import 'package:caocode/ide/ide_tab_bar.dart';
import 'package:caocode/ide/lsp/lsp_protocol.dart';

import 'fake_files.dart';

String _status(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.textContaining(RegExp(r'^Ln \d+, Col')),
  );
  return text.data ?? text.textSpan!.toPlainText();
}

Finder _tab(String name) =>
    find.descendant(of: find.byType(IdeTabBar), matching: find.text(name));

void main() {
  final long = [for (var i = 1; i <= 200; i++) 'line $i'].join('\n');

  // Another file's tab, an image's or a Markdown preview's in front: the
  // last two let the editor go, and the carets with it, until #101.
  for (final other in ['b.dart', 'c.png', 'd.md']) {
    testWidgets('a file shown again after $other has its caret where it was', (
      tester,
    ) async {
      await pumpWorkbench(
        tester,
        {'a.dart': long, 'b.dart': long, 'c.png': '', 'd.md': '# d'},
        open: ['a.dart', other],
        nativeEditor: true,
      );
      await tester.pumpAndSettle();
      await tester.tap(_tab('a.dart'));
      await tester.pumpAndSettle();
      const position = LspPosition(119, 3);
      tester
          .state<IdeEditorState>(find.byType(IdeEditor))
          .revealRange(const LspRange(position, position));
      await tester.pumpAndSettle();
      expect(_status(tester), 'Ln 120, Col 4');

      await tester.tap(_tab(other));
      await tester.pumpAndSettle();
      await tester.tap(_tab('a.dart'));
      await tester.pumpAndSettle();
      expect(_status(tester), 'Ln 120, Col 4');
    });
  }
}
