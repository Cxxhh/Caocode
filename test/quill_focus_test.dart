import 'package:caocode/chat/chat_session.dart';
import 'package:caocode/chat/composer/composer.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/stash/stash_disk.dart';
import 'package:caocode/stash/stash_editor.dart';
import 'package:caocode/stash/stash_store.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final stash in [false, true]) {
    testWidgets(
      'dirty ${stash ? 'stash editors' : 'composers'} yield focus '
      'before the next frame',
      (tester) async {
        final session = ChatSession(historyCount: 0);
        final store = StashStore(MemoryStashDisk());
        final controllers = [QuillController.basic(), QuillController.basic()];
        final externalFocus = [FocusNode(), FocusNode()];
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            localizationsDelegates: const [
              AppLocalizations.delegate,
              FlutterQuillLocalizations.delegate,
            ],
            home: Scaffold(
              body: Column(
                children: [
                  for (var i = 0; i < 2; i++)
                    Expanded(
                      child: stash
                          ? StashEditor(
                              controller: controllers[i],
                              focusNode: externalFocus[i],
                              store: store,
                              ensureNote: () async => i + 1,
                            )
                          : ChatComposer(
                              session: session,
                              draft: session.draft,
                            ),
                    ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        final editors = tester
            .widgetList<QuillEditor>(find.byType(QuillEditor))
            .toList();
        final nodes = [for (final editor in editors) editor.focusNode];
        nodes.first.requestFocus();
        await tester.pump();

        // Bound a regression: otherwise the unfixed microtask loop hangs the
        // test runner too, preventing even its timeout from running.
        var notifications = 0;
        void limitFocusLoop() {
          if (++notifications > 20) {
            for (final node in nodes) {
              node.canRequestFocus = false;
            }
          }
        }

        for (final node in nodes) {
          node.addListener(limitFocusLoop);
        }
        for (final editor in editors) {
          editor.controller.replaceText(
            0,
            0,
            'a',
            const TextSelection.collapsed(offset: 1),
          );
        }
        for (final editor in editors) {
          expect(
            (editor.config.editorKey!.currentState as QuillRawEditorState)
                .dirty,
            isTrue,
          );
        }
        nodes.last.requestFocus();
        await tester.idle();
        for (final node in nodes) {
          node.removeListener(limitFocusLoop);
        }
        final settled = notifications <= 20;
        final focused = nodes.last.hasFocus;
        final skipConsumed = editors.every(
          (editor) => !editor.controller.skipRequestKeyboard,
        );
        await tester.pump();
        var typed = false, refocused = false;
        if (settled) {
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: 'typed\n',
              selection: TextSelection.collapsed(offset: 5),
            ),
          );
          await tester.pump();
          typed = editors.last.controller.document.toPlainText() == 'typed\n';
          nodes.first.requestFocus();
          await tester.idle();
          refocused = nodes.first.hasFocus;
          await tester.pump();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        for (final controller in controllers) {
          controller.dispose();
        }
        for (final node in externalFocus) {
          node.dispose();
        }
        store.dispose();
        session.dispose();
        expect(
          settled,
          isTrue,
          reason: 'Focus must settle without the safety cap.',
        );
        expect(focused, isTrue);
        expect(skipConsumed, isTrue);
        expect(typed, isTrue);
        expect(refocused, isTrue);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      }),
    );
  }
}
