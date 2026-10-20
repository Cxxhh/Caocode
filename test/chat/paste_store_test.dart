import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/chat/composer/composer_embeds.dart';
import 'package:caocode/chat/composer/composer_files.dart';
import 'package:caocode/chat/composer/paste_store.dart';
import 'package:caocode/chat/widgets/text_preview.dart';
import 'package:caocode/chat/widgets/user_message_bubble.dart';
import 'package:caocode/kernel/claude_code/claude_code_transport.dart';
import 'package:caocode/platform/data_dir.dart';
import 'package:caocode/theme/app_theme.dart';

/// A paste of [lines] lines.
String _log(int lines) =>
    [for (var i = 1; i <= lines; i++) '2026-10-13 12:00:00 INFO line $i']
        .join('\n');

/// A message referring to [pastes], carrying them after its text.
String _message(List<PastedText> pastes) =>
    'Why does it fail? ${pastes.map((paste) => paste.reference).join(' ')}'
    '${codeAppendix(pastes)}';

void main() {
  setUp(() {
    final folder = Directory(DataDirectory.current.pastesDir);
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  test('a paste too long to send goes in a file the message names; a '
      'shorter one, in the message', () async {
    final long = PastedText(number: 1, text: _log(1500));
    final short = PastedText(number: 2, text: _log(400));
    expect(PasteStore.isStored(long.text), isTrue);
    expect(PasteStore.isStored(short.text), isFalse);
    expect(PasteStore.isStored('x' * (PasteStore.maxSentLength + 1)), isTrue);

    final sent = PasteStore.offload(_message([long, short]));
    final file = Directory(DataDirectory.current.pastesDir).listSync().single;
    expect(await File(file.path).readAsString(), long.text);
    expect(sent, isNot(contains('line 1500')));
    expect(sent, contains('saved in full to `${file.path}`'));
    // The other goes whole.
    expect(sent, contains('INFO line 400\n```'));

    // Read back: the same tags, the kept one by its file.
    final references = splitCodeAppendix(sent).references;
    final kept = references[long.reference]! as PastedText;
    expect(kept.file, file.path);
    expect(kept.extraLines, 1499);
    expect(kept.reference, long.reference);
    expect(references[short.reference], short);
    expect(await PasteStore.read(kept.file!), long.text);

    // Sent again (a message edited): as it was, the paste kept once.
    expect(PasteStore.offload(sent), sent);
    PasteStore.offload(_message([long]));
    expect(Directory(DataDirectory.current.pastesDir).listSync(), hasLength(1));
  });

  test('a message without long pastes goes as it is', () {
    final text = _message([PastedText(number: 1, text: _log(30))]);
    expect(PasteStore.offload(text), text);
    expect(PasteStore.offload('Just words'), 'Just words');
  });

  test('Claude Code may read the folder they are kept in', () {
    expect(
      ClaudeLaunch.readRule(
        '/Users/me/Library/Application Support/caocode/pastes',
      ),
      'Read(//Users/me/Library/Application Support/caocode/pastes/**)',
    );
    expect(
      ClaudeLaunch.readRule(r'C:\Users\me\AppData\Roaming\caocode\pastes'),
      'Read(//c/Users/me/AppData/Roaming/caocode/pastes/**)',
    );
    expect(
      const ClaudeLaunch(cwd: '/p', readable: ['/data/pastes']).settings,
      containsPair('permissions', {
        'allow': ['Read(//data/pastes/**)'],
      }),
    );
    expect(
      const ClaudeLaunch(cwd: '/p').settings,
      isNot(contains('permissions')),
    );
  });

  testWidgets('a kept paste shows as the same tag, and opens whole', (
    tester,
  ) async {
    final long = PastedText(number: 1, text: _log(1500));
    final sent = await tester.runAsync(
      () async => PasteStore.offload(_message([long])),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(body: UserMessageBubble(text: sent!)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pasted text #1'), findsOneWidget);
    expect(find.text(' +1499 lines'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byType(ComposerPastedTextChip));
      // Read from its file.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.byType(TextPreview), findsOneWidget);
    expect(find.text('2026-10-13 12:00:00 INFO line 1'), findsOneWidget);
  });
}
