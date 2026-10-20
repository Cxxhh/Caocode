import 'dart:convert';
import 'dart:ui' as ui;

import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:caocode/ide/markdown/markdown_preview.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

late Uint8List _png;

Future<Uint8List> _createPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(Colors.red, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(160, 80);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

final _svg = Uint8List.fromList(
  utf8.encode(
    '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">'
    '<rect width="24" height="24" fill="red"/></svg>',
  ),
);

const _path = '/project/docs/guide.md';

class FakeHost {
  final reads = <String>[];
  final opened = <(String, String?)>[];
  final edited = <(int, int)>[];
  var edits = 0;

  Future<Uint8List> read(String path) async {
    reads.add(path);
    if (path.endsWith('missing.png')) throw StateError('no such file');
    return path.endsWith('.svg') ? _svg : _png;
  }
}

Future<FakeHost> pumpPreview(
  WidgetTester tester,
  EditorDocumentModel model, {
  bool readOnly = false,
}) async {
  final host = FakeHost();
  tester.view.physicalSize = const Size(1000, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: IdeMarkdownPreview(
          path: _path,
          model: model,
          pathContext: p.posix,
          readOnly: readOnly,
          readBytes: host.read,
          onEdited: () => host.edits++,
          onOpenFile: (path, fragment) => host.opened.add((path, fragment)),
          onEdit: (line, column) => host.edited.add((line, column)),
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => precacheImage(
      MemoryImage(_png),
      tester.element(find.byType(IdeMarkdownPreview)),
    ),
  );
  await tester.pumpAndSettle();
  return host;
}

Finder _text(String text) => find.text(text, findRichText: true);

IdeMarkdownPreviewState _state(WidgetTester tester) =>
    tester.state(find.byType(IdeMarkdownPreview));

/// Double clicks the [index]th character of [text] in the text shown as
/// [within] ([text] by default).
Future<void> _doubleClick(
  WidgetTester tester,
  String text, {
  String? within,
  int index = 0,
}) async {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.text(within ?? text, findRichText: true).first,
  );
  final start = paragraph.text.toPlainText().indexOf(text) + index;
  final box = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + 1),
      )
      .first
      .toRect();
  // Just after its left edge: the caret goes before it.
  final at = paragraph.localToGlobal(box.centerLeft + const Offset(1, 0));
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(at);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => _png = await _createPng());

  testWidgets('heading rules use the sidebar divider color', (tester) async {
    await pumpPreview(tester, EditorDocumentModel('# Title\n\n## Section'));
    final separator = AppColors.partBorder;
    for (final title in ['Title', 'Section']) {
      final containers = tester.widgetList<Container>(
        find.ancestor(of: _text(title), matching: find.byType(Container)),
      );
      final borders = containers
          .map((container) => (container.decoration as BoxDecoration?)?.border)
          .whereType<Border>();
      expect(borders.first.bottom.color, separator);
    }
  });

  testWidgets('a double click opens the source at the text clicked', (
    tester,
  ) async {
    const text =
        '# Guide\r\n\r\nSome **bold** and `code`, then bold.\r\n\r\n'
        '- one\r\n- two words\r\n';
    final model = EditorDocumentModel(text);
    final host = await pumpPreview(tester, model);
    // Inline code is shown with room around it.
    const paragraph = 'Some bold and  code , then bold.';

    await _doubleClick(tester, 'bold', within: paragraph);
    // `bold` is the 8th column: after `Some **`.
    expect(host.edited, [(3, 8)]);
    await _doubleClick(tester, 'code', within: paragraph, index: 2);
    expect(host.edited.last, (3, 22));
    // The second `bold`, not the first.
    await _doubleClick(tester, 'bold.', within: paragraph);
    expect(host.edited.last, (3, 32));
    await _doubleClick(tester, 'words', within: 'two words');
    expect(host.edited.last, (6, 7));
    await _doubleClick(tester, 'Guide');
    expect(host.edited.last, (1, 3));
    // Nothing changed.
    expect(model.text, text);
    expect(host.edits, 0);
  });

  test('where the text shown is in the source', () {
    int? at(String source, String shown, int offset, [String? before]) =>
        markdownSourceOffset(
          source,
          shown: shown,
          offset: offset,
          before: before ?? shown.substring(0, offset),
        );

    expect(at('a **b** c', 'a b c', 2), 4);
    expect(at('a **b** c', 'a b c', 4), 8);
    // At a line's end: after what leads to it.
    expect(at('a **b**', 'a b', 3), 5);
    expect(at('x [link](u) x', 'x link x', 7), 12);
    expect(at('', '', 0), isNull);
  });

  testWidgets('a task box ticks its line', (tester) async {
    final model = EditorDocumentModel('- [ ] write\n- [x] read');
    final host = await pumpPreview(tester, model);
    await tester.tap(find.byIcon(Icons.check_box_outline_blank));
    await tester.pumpAndSettle();
    expect(model.text, '- [x] write\n- [x] read');
    expect(host.edits, 1);
  });

  testWidgets('read-only: its task boxes do not tick', (tester) async {
    final model = EditorDocumentModel('- [ ] write\n\nText.');
    await pumpPreview(tester, model, readOnly: true);
    await tester.tap(find.byIcon(Icons.check_box_outline_blank));
    await tester.pumpAndSettle();
    expect(model.text, '- [ ] write\n\nText.');
  });

  testWidgets('a file dropped goes after the block it is let go on', (
    tester,
  ) async {
    final model = EditorDocumentModel('# Title\n\nText.\n');
    final host = await pumpPreview(tester, model);
    _state(tester)
        .insert('![](shot.png)', position: tester.getCenter(_text('Title')));
    await tester.pumpAndSettle();
    expect(model.text, '# Title\n\n![](shot.png)\n\nText.\n');
    _state(tester).insert('[a](a.md)');
    expect(model.text, '# Title\n\n![](shot.png)\n\nText.\n\n[a](a.md)');
    expect(host.edits, 2);
  });

  testWidgets('clicking an image opens a zoomable preview', (tester) async {
    final model = EditorDocumentModel('![shot](img/shot.png)');
    final host = await pumpPreview(tester, model);
    final image = find.byType(Image).first;
    await tester.tap(image);
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    expect(model.text, '![shot](img/shot.png)');
    expect(host.edited, isEmpty);
    final viewer = find.byType(InteractiveViewer);
    final enlarged = find.descendant(of: viewer, matching: find.byType(Image));
    expect(tester.getSize(enlarged).width, greaterThan(160));
    final transform = find
        .descendant(of: viewer, matching: find.byType(Transform))
        .first;
    final before = tester.widget<Transform>(transform).transform.clone();
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(viewer),
        scrollDelta: const Offset(0, -200),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Transform>(transform).transform, isNot(before));
    final zoomed = tester.widget<Transform>(transform).transform.clone();
    await tester.drag(viewer, const Offset(60, 30));
    await tester.pumpAndSettle();
    expect(tester.widget<Transform>(transform).transform, isNot(zoomed));

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(host.reads, ['/project/docs/img/shot.png']);
  });

  testWidgets('an image double click does not open the source', (tester) async {
    final model = EditorDocumentModel('![shot](shot.png)');
    final host = await pumpPreview(tester, model);
    final at = tester.getCenter(find.byType(Image));
    // Both clicks reach the document before the dialog's first frame.
    await tester.tapAt(at);
    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(host.edited, isEmpty);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('network images reuse the loaded image in the preview', (
    tester,
  ) async {
    const provider = NetworkImage('https://example.test/shot.png');
    // Seed Flutter's image cache with a deterministic response; no external I/O.
    final codec = (await tester.runAsync(
      () => ui.instantiateImageCodec(_png),
    ))!;
    final frame = (await tester.runAsync(codec.getNextFrame))!;
    codec.dispose();
    PaintingBinding.instance.imageCache.putIfAbsent(
      provider,
      () => OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: frame.image)),
      ),
    );
    addTearDown(provider.evict);
    final host = await pumpPreview(
      tester,
      EditorDocumentModel('![web](${provider.url})'),
    );
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(InteractiveViewer),
        matching: find.byType(Image),
      ),
    );
    expect(image.image, provider);
    expect(host.reads, isEmpty);
    await tester.tapAt(const Offset(10, 350));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('SVG images can be opened in the preview', (tester) async {
    final model = EditorDocumentModel('![icon](icon.svg)');
    await pumpPreview(tester, model);
    await tester.tap(find.byType(SvgPicture));
    await tester.pumpAndSettle();

    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(SvgPicture), findsNWidgets(2));
  });

  testWidgets('images are read from the project, beside the document', (
    tester,
  ) async {
    final model = EditorDocumentModel(
      '![shot](img/shot%201.png)\n\n![](<../a b.png>)\n\n![gone](missing.png)',
    );
    final host = await pumpPreview(tester, model);
    expect(host.reads, [
      '/project/docs/img/shot 1.png',
      '/project/a b.png',
      '/project/docs/missing.png',
    ]);
    expect(find.byType(Image), findsNWidgets(2));
    // One that cannot be read shows its alt text.
    expect(find.text('gone'), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.broken_image_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('links: anchors scroll to their heading, files open', (
    tester,
  ) async {
    final filler = [for (var i = 0; i < 60; i++) 'Paragraph $i.'].join('\n\n');
    final model = EditorDocumentModel(
      '[Go](#the-end) [Other](../README.md#Usage) [Line](src/a.dart#L3)\n\n'
      '$filler\n\n## The End\n\n$filler',
    );
    final host = await pumpPreview(tester, model);
    expect(_text('The End'), findsNothing);
    await tester.tapOnText(find.textRange.ofSubstring('Go'));
    await tester.pumpAndSettle();
    expect(_text('The End'), findsOneWidget);
    expect(tester.getTopLeft(_text('The End')).dy, lessThan(100));

    _state(tester).revealLine(1);
    await tester.pumpAndSettle();
    await tester.tapOnText(find.textRange.ofSubstring('Other'));
    await tester.tapOnText(find.textRange.ofSubstring('Line'));
    expect(host.opened, [
      ('/project/README.md', 'Usage'),
      ('/project/docs/src/a.dart', 'L3'),
    ]);
  });

  testWidgets('the line at the top, and a line revealed', (tester) async {
    final model = EditorDocumentModel(
      [for (var i = 0; i < 60; i++) 'Paragraph $i.'].join('\n\n'),
    );
    await pumpPreview(tester, model);
    final state = _state(tester);
    expect(state.topLine, 1);
    state.revealLine(81);
    await tester.pumpAndSettle();
    expect(state.topLine, 81);
    expect(tester.getTopLeft(_text('Paragraph 40.')).dy, lessThan(60));
  });
}
