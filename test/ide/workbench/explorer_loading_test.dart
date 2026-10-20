import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:caocode/ide/file_service.dart';
import 'package:caocode/ide/ide_explorer.dart';
import 'package:caocode/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_files.dart';

class _LoadingFiles extends TreeFiles {
  _LoadingFiles() : super({inRoot('README.md'): 'hello'});
  final pending = Completer<void>();
  @override
  Future<List<IdeFile>> list(String directory) async {
    await pending.future;
    return super.list(directory);
  }
}

void main() {
  testWidgets('file loading is visible, then replaced by file rows', (
    tester,
  ) async {
    if (const bool.fromEnvironment('CAOCODE_WSL_FILES_VISUAL')) {
      await tester.runAsync(() async {
        for (final (family, path) in [
          ('visual', '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'),
          ('codicon', 'assets/codicons/codicon.ttf'),
        ]) {
          final loader = FontLoader(family)
            ..addFont(
              Future.value(
                ByteData.sublistView(await File(path).readAsBytes()),
              ),
            );
          await loader.load();
        }
      });
    }
    final files = _LoadingFiles();
    final controller = IdeExplorerController(
      files: files,
      root: testRoot,
      watch: (_) => const Stream.empty(),
    );
    addTearDown(controller.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          textTheme: ThemeData.dark().textTheme.apply(
            fontFamily: const bool.fromEnvironment('CAOCODE_WSL_FILES_VISUAL')
                ? 'visual'
                : null,
          ),
        ),
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 320,
              height: 420,
              child: IdeExplorer(controller: controller, onOpen: (_, _) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('加载'), findsOneWidget);
    Future<void> capture(String state) async {
      if (!const bool.fromEnvironment('CAOCODE_WSL_FILES_VISUAL')) return;
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final picture = await render.toImage(pixelRatio: 2);
        final data = await picture.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/caocode-wsl-files-$state.png')
            .writeAsBytes(data!.buffer.asUint8List());
        picture.dispose();
      });
    }

    await capture('loading');
    files.pending.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('README.md'), findsOneWidget);
    await capture('ready');
  });
}
