@TestOn('vm')
library;

import 'dart:io';

import 'package:caocode/chat/chat_session.dart';
import 'package:caocode/chat/composer/composer.dart';
import 'package:caocode/chat/composer/composer_embeds.dart';
import 'package:caocode/chat/composer/composer_files.dart';
import 'package:caocode/chat/composer/remote_drops.dart';
import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../ide/workbench/fake_files.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('caocode_drops_');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  String local(String relative, [String text = 'x']) {
    final file = File(p.join(temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
    return file.path;
  }

  test('copies files and folders to a folder of their own on the host, '
      'the same name from two folders numbered', () async {
    final host = TreeFiles({});
    final a = local('one/a.txt', 'first');
    final other = local('two/a.txt', 'second');
    local('dir/b.txt', 'b');
    final copies = await RemoteDrops.copy(host, [
      ComposerFile(a),
      ComposerFile(other),
      ComposerFile(p.join(temp.path, 'dir'), directory: true),
    ], now: DateTime.fromMicrosecondsSinceEpoch(36 * 36));
    const into = '${RemoteDrops.folder}/100';
    expect(copies, [
      const ComposerFile('$into/a.txt'),
      const ComposerFile('$into/a 2.txt'),
      const ComposerFile('$into/dir', directory: true),
    ]);
    expect(String.fromCharCodes(host.bytes['$into/a.txt']!), 'first');
    expect(String.fromCharCodes(host.bytes['$into/a 2.txt']!), 'second');
    expect(String.fromCharCodes(host.bytes['$into/dir/b.txt']!), 'b');

    // Again: the folder there already, another of their own in it.
    final again = await RemoteDrops.copy(host, [
      ComposerFile(a),
    ], now: DateTime.fromMicrosecondsSinceEpoch(37 * 36));
    expect(again.single.path, startsWith('${RemoteDrops.folder}/'));
    expect(host.bytes[again.single.path], isNotNull);
  });

  group('the composer', () {
    Future<ChatComposerState> pump(
      WidgetTester tester, {
      required String cwd,
      TreeFiles? host,
    }) async {
      final session = ChatSession(
        historyCount: 0,
        kernelContext: KernelContext(cwd: cwd),
      );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatComposer(session: session, hostFiles: host),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.state<ChatComposerState>(find.byType(ChatComposer));
    }

    List<String> tags(WidgetTester tester) => [
      for (final op
          in tester
              .widget<QuillEditor>(find.byType(QuillEditor))
              .controller
              .document
              .toDelta()
              .toList())
        if (op.data case final Map<dynamic, dynamic> data
            when data.containsKey(ComposerTokenEmbed.type))
          ComposerTokenEmbed.plainText(data[ComposerTokenEmbed.type]),
    ];

    testWidgets("of a remote project tags copies on the host of this "
        "machine's files let go on it", (tester) async {
      final host = TreeFiles({});
      final state = await pump(
        tester,
        cwd: 'ssh://box/home/me/app',
        host: host,
      );
      final file = local('notes.md');
      await tester.runAsync(() async {
        state.fileDrop(Offset.zero, [ComposerFile(file)]);
        // The copy reads and writes for real.
        for (var i = 0; i < 20 && host.bytes.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      final copied = host.bytes.keys.single;
      expect(copied, startsWith('${RemoteDrops.folder}/'));
      expect(copied, endsWith('/notes.md'));
      expect(tags(tester), ['@$copied']);
    });

    testWidgets("of a local project tags this machine's files as they are", (
      tester,
    ) async {
      final state = await pump(tester, cwd: p.join(temp.path, 'app'));
      final file = local('elsewhere/notes.md');
      state.fileDrop(Offset.zero, [ComposerFile(file)]);
      await tester.pump();
      expect(tags(tester), ['@$file']);
    });
  });
}
