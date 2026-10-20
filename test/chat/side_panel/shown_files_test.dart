import 'dart:io';

import 'package:caocode/chat/side_panel/file_open.dart';
import 'package:caocode/chat/side_panel/shown_files.dart';
import 'package:caocode/chat/side_panel/shown_files_io.dart' show pruneShown;
import 'package:caocode/chat/side_panel/side_panel_controller.dart';
import 'package:caocode/chat/widgets/text_preview.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/platform/data_dir.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('what text holds, by its look', () {
    String of(String text) => ShownFiles.extensionFor(text);
    expect(of('{"a": [1, 2]}'), '.json');
    expect(of('{not json'), isNot('.json'));
    expect(of('diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@'), '.diff');
    expect(of('<!DOCTYPE html>\n<html></html>'), '.html');
    expect(of('<?xml version="1.0"?>\n<a/>'), '.xml');
    expect(of('#!/usr/bin/env python3\nprint(1)'), '.py');
    expect(of('#!/bin/bash\necho hi'), '.sh');
    expect(
      of('Traceback (most recent call last):\n  File "a.py", line 1'),
      '.log',
    );
    expect(
      of(
        '2026-10-13 12:00:01 INFO start\n'
        '2026-10-13 12:00:02 ERROR boom\n'
        '2026-10-13 12:00:03 INFO done',
      ),
      '.log',
    );
    expect(of('# Title\n\nSome words.'), '.md');
    expect(of('name: app\nversion: 1\ndeps:\n  - a'), '.yaml');
    expect(of('just a few words\nand more'), '.txt');
  });

  test('written once by what it holds, named as asked', () {
    final text = '{"shown": ${DateTime.now().microsecondsSinceEpoch}}';
    final path = ShownFiles.text(text, name: 'Pasted text #1')!;
    expect(p.isWithin(DataDirectory.current.cacheDir, path), isTrue);
    expect(p.basename(path), 'Pasted text #1.json');
    expect(File(path).readAsStringSync(), text);
    expect(ShownFiles.text(text, name: 'Pasted text #1'), path);
    // A name with its own extension keeps it; no separators in it.
    expect(
      p.basename(ShownFiles.text('x', name: 'lib/a (1-3).dart')!),
      'lib_a (1-3).dart',
    );
  });

  test('a look takes over the tab of the last look; a pinned one stays', () {
    final panel = AgentSidePanel();
    final chat = Object();
    FileOpenRequest look(String path) =>
        FileOpenRequest(path, local: true, readOnly: true, preview: true);
    List<String> tabs() => [
      for (final tab in panel.tabsOf(chat).files)
        '${p.basename(tab.path)}${tab.preview ? '*' : ''}',
    ];

    panel.open(chat, const FileOpenRequest('/p/a.dart'));
    panel.open(chat, look('/c/one.txt'));
    expect(tabs(), ['a.dart', 'one.txt*']);
    panel.open(chat, look('/c/two.json'));
    expect(tabs(), ['a.dart', 'two.json*']);

    panel.pin(panel.tabsOf(chat).active!);
    panel.open(chat, look('/c/three.log'));
    expect(tabs(), ['a.dart', 'two.json', 'three.log*']);
    // Opened for itself: kept.
    panel.open(chat, const FileOpenRequest('/c/three.log'));
    expect(tabs(), ['a.dart', 'two.json', 'three.log']);
  });

  testWidgets('a long text shown where the files open, as a file, '
      'read-only, in the tab of the last look', (tester) async {
    final opened = <FileOpenRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        home: FileOpenScope(
          root: '/p',
          onOpen: opened.add,
          existence: FileExistence(null),
          child: Builder(
            builder: (context) => GestureDetector(
              onTap: () => showTextPreview(
                context,
                title: 'Pasted text #2',
                text: '[1, 2, 3]',
              ),
              child: const Text('tag'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('tag'));
    await tester.pump();
    final request = opened.single;
    expect(p.basename(request.path), 'Pasted text #2.json');
    expect(request.local && request.readOnly && request.preview, isTrue);
    // No dialog.
    expect(find.byType(TextPreview), findsNothing);
  });

  test('those not shown for a week are removed, the folders left empty '
      'too', () async {
    final root = Directory.systemTemp.createTempSync('shown');
    addTearDown(() => root.deleteSync(recursive: true));
    final now = DateTime(2026, 10, 15);
    File write(String folder, String name, Duration age) =>
        File(p.join(root.path, folder, name))
          ..createSync(recursive: true)
          ..writeAsStringSync('secret')
          ..setLastModifiedSync(now.subtract(age));
    final old = write('aaaa', 'paste.txt', const Duration(days: 8));
    final recent = write('bbbb', 'paste.txt', const Duration(days: 2));
    final mixedOld = write('cccc', 'a.png', const Duration(days: 30));
    final mixedNew = write('cccc', 'b.png', const Duration(hours: 1));
    await pruneShown(root.path, now: now);
    expect(old.existsSync(), isFalse);
    expect(old.parent.existsSync(), isFalse);
    expect(recent.existsSync(), isTrue);
    expect(mixedOld.existsSync(), isFalse);
    expect(mixedNew.existsSync(), isTrue);
  });
}
