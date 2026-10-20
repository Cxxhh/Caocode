import 'dart:io';

import 'package:bao_editor/monaco/flutter/language_assets.dart';
import 'package:bao_editor/monaco/flutter/language_overrides.dart';
import 'package:caocode/ide/ide_quick_input.dart';
import 'package:caocode/ide/ide_status_bar.dart';
import 'package:caocode/ide/language_mode.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/settings/user_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final overrides = EditorLanguageOverrides.instance;
  tearDown(() => overrides.load(const {}));

  test('a language picked for a path is the one its editors take', () async {
    const assets = MonacoLanguageAssets();
    expect(
      (await assets.registrationForPath('/x/notes.txt'))?.id,
      isNot('python'),
    );

    var told = 0;
    void listener() => told++;
    overrides.addListener(listener);
    overrides.set('/x/notes.txt', 'python');
    expect(told, 1);
    expect((await assets.registrationForPath('/x/notes.txt'))?.id, 'python');
    // Plain text: none, whatever its name says.
    overrides.set('/x/a.json', EditorLanguageOverrides.plainText);
    expect(await assets.registrationForPath('/x/a.json'), isNull);
    overrides.set('/x/a.json', EditorLanguageOverrides.plainText);
    expect(told, 2);
    overrides.removeListener(listener);

    await IdeLanguageNames.load();
    expect(IdeLanguageNames.forPath('/x/notes.txt'), 'Python');
    expect(IdeLanguageNames.forPath('/x/a.json'), 'Plain Text');
    overrides.set('/x/notes.txt', null);
    expect(IdeLanguageNames.forPath('/x/notes.txt'), isNot('Python'));
  });

  test('the pick lists Auto Detect first, the one picked active', () async {
    await IdeLanguageNames.load();
    overrides.set('/x/a.log', 'python');
    final pick = languageModePick(englishLocalizations, '/x/a.log');
    final items = pick.items.whereType<IdeQuickPickItem>().toList();
    expect(items.first.label, 'Auto Detect');
    expect(pick.activeItems!.single.label, 'Python');
    // Each language once.
    final ids = [for (final item in items.skip(2)) item.description];
    expect(ids.toSet().length, ids.length);

    items.first.onAccept!();
    expect(overrides.of('/x/a.log'), isNull);
  });

  test('the picks are kept in the global storage, and read back', () async {
    final folder = await Directory.systemTemp.createTemp('language_modes');
    addTearDown(() => folder.delete(recursive: true));
    final storage = GlobalStorage(
      '${folder.path}/storage.json',
      debounce: Duration.zero,
    );
    await storage.load();
    keepLanguageModes(storage);
    overrides.set('/x/run', 'shellscript');
    // Written as it is kept, off the call.
    for (var i = 0; i < 100; i++) {
      if (storage.get<Map<Object?, Object?>>(languageModesKey) != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // Queued after the edit: once it is written.
    await storage.load();
    expect(storage.get<Map<Object?, Object?>>(languageModesKey), {
      '/x/run': 'shellscript',
    });

    overrides.load(const {});
    final again = GlobalStorage('${folder.path}/storage.json');
    await again.load();
    overrides.load(again.get<Map<Object?, Object?>>(languageModesKey));
    expect(overrides.of('/x/run'), 'shellscript');
  });
}
