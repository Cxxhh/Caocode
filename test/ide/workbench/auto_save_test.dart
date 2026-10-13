import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/ide/ide_workspace.dart';
import 'package:caocode/settings/user_settings.dart';
import 'package:path/path.dart' as p;

import 'fake_files.dart';

/// `files.autoSave`, as VS Code's: off by default; `afterDelay` saves once
/// edits stop for `files.autoSaveDelay`, `onFocusChange` when another
/// editor comes to the front.
void main() {
  UserSettings settingsOf(String json) {
    final temp = Directory.systemTemp.createTempSync('caocode-auto-save');
    addTearDown(() => temp.deleteSync(recursive: true));
    final settings = UserSettings(
      p.join(temp.path, 'User', 'settings.json'),
      debounce: Duration.zero,
    );
    addTearDown(settings.dispose);
    File(settings.path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(json);
    settings.loadSync();
    return settings;
  }

  Map<String, String> contentsOf(IdeWorkspace workspace) =>
      (workspace.files as TreeFiles).contents;

  testWidgets('off by default: an edit stays unsaved', (tester) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a'},
      open: ['a.txt'],
      settings: settingsOf('{}'),
    );
    workspace.edit(inRoot('a.txt'), 'edited');
    await tester.pump(const Duration(seconds: 5));

    expect(contentsOf(workspace)[inRoot('a.txt')], 'a');
    expect(workspace.active!.dirty, isTrue);
  });

  testWidgets('afterDelay saves once edits stop for the delay', (
    tester,
  ) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a'},
      open: ['a.txt'],
      settings: settingsOf(
        '{"files.autoSave": "afterDelay", "files.autoSaveDelay": 500}',
      ),
    );
    final path = inRoot('a.txt');
    workspace.edit(path, 'a1');
    await tester.pump(const Duration(milliseconds: 300));
    workspace.edit(path, 'a12');
    await tester.pump(const Duration(milliseconds: 300));
    expect(contentsOf(workspace)[path], 'a');

    await tester.pump(const Duration(milliseconds: 300));
    expect(contentsOf(workspace)[path], 'a12');
    expect(workspace.active!.dirty, isFalse);
  });

  testWidgets('onFocusChange saves when another editor comes to the front', (
    tester,
  ) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a', 'b.txt': 'b'},
      open: ['a.txt', 'b.txt'],
      settings: settingsOf('{"files.autoSave": "onFocusChange"}'),
    );
    workspace.select(inRoot('a.txt'));
    await tester.pump();
    workspace.edit(inRoot('a.txt'), 'edited');
    await tester.pump(const Duration(seconds: 5));
    expect(contentsOf(workspace)[inRoot('a.txt')], 'a');

    workspace.select(inRoot('b.txt'));
    await tester.pump();
    expect(contentsOf(workspace)[inRoot('a.txt')], 'edited');
  });

  testWidgets('a file changed on disk is left for saving by hand, told once', (
    tester,
  ) async {
    final workspace = await pumpWorkbench(
      tester,
      {'a.txt': 'a'},
      open: ['a.txt'],
      settings: settingsOf(
        '{"files.autoSave": "afterDelay", "files.autoSaveDelay": 100}',
      ),
    );
    final path = inRoot('a.txt');
    contentsOf(workspace)[path] = 'theirs';
    workspace.edit(path, 'mine');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(contentsOf(workspace)[path], 'theirs');
    expect(workspace.notifications.notifications, hasLength(1));

    workspace.edit(path, 'mine again');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(contentsOf(workspace)[path], 'theirs');
    expect(workspace.notifications.notifications, hasLength(1));
  });
}
