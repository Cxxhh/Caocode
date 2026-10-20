import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/ide/ide_hover.dart';
import 'package:caocode/theme/codicons.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: child)),
    ),
  );

  Future<void> hover(WidgetTester tester, Finder target) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(target));
    await tester.pump();
  }

  testWidgets('shows after the workbench delay, in the workbench look', (
    tester,
  ) async {
    await pump(
      tester,
      IdeActionButton(
        icon: Codicons.refresh,
        tooltip: 'Refresh Explorer',
        onPressed: () {},
      ),
    );
    // Screen readers and finders see it as the tooltip.
    expect(find.byTooltip('Refresh Explorer'), findsOneWidget);
    await hover(tester, find.byIcon(Codicons.refresh));
    await tester.pump(ideHoverDelay - const Duration(milliseconds: 50));
    expect(find.text('Refresh Explorer'), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Refresh Explorer'), findsOneWidget);

    final box = tester.widget<DecoratedBox>(
      find
          .ancestor(
            of: find.text('Refresh Explorer'),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = box.decoration as BoxDecoration;
    expect(decoration.color, IdeHoverColors.background);
    expect(decoration.border, Border.all(color: IdeHoverColors.border));
    expect(decoration.borderRadius, BorderRadius.circular(5));
    final text = tester.widget<Text>(find.text('Refresh Explorer'));
    final style = DefaultTextStyle.of(
      tester.element(find.text('Refresh Explorer')),
    ).style.merge(text.style);
    expect(style.fontSize, 12);
    expect(style.color, IdeHoverColors.foreground);
    // Below the button, centered on it.
    final hoverRect = tester.getRect(find.byWidget(box));
    final target = tester.getRect(find.byType(IdeActionButton));
    expect(hoverRect.top, greaterThan(target.bottom));
    expect(hoverRect.center.dx, closeTo(target.center.dx, 1));
  });

  testWidgets('a long hover is at most 90% of a narrow window, clear of '
      'its edges', (tester) async {
    tester.view.physicalSize = const Size(500, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final message = 'A long explanation of where the models come from. ' * 6;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: IdeHover(
              message: message,
              child: const SizedBox(width: 24, height: 24),
            ),
          ),
        ),
      ),
    );
    await hover(tester, find.byType(SizedBox).last);
    await tester.pump(ideHoverDelay + const Duration(milliseconds: 200));
    final rect = tester.getRect(
      find.ancestor(of: find.text(message), matching: find.byType(IdeHoverBox)),
    );
    expect(rect.width, lessThanOrEqualTo(500 * ideHoverMaxWidthFactor));
    expect(rect.left, greaterThanOrEqualTo(ideHoverEdgeMargin));
    expect(rect.right, lessThanOrEqualTo(500 - ideHoverEdgeMargin));
  });

  test('a hover kept in the window, at least the margin from its edges', () {
    const overlay = Size(400, 300);
    const size = Size(100, 20);
    expect(
      clampHoverOffset(const Offset(-20, -5), size, overlay),
      const Offset(ideHoverEdgeMargin, ideHoverEdgeMargin),
    );
    expect(
      clampHoverOffset(const Offset(390, 295), size, overlay),
      const Offset(
        400 - 100 - ideHoverEdgeMargin,
        300 - 20 - ideHoverEdgeMargin,
      ),
    );
    // Too wide for the margins: centered.
    expect(
      clampHoverOffset(const Offset(0, 50), const Size(390, 20), overlay).dx,
      5,
    );
  });

  testWidgets('the delay is 500 ms everywhere, macOS too', (tester) async {
    expect(ideHoverDelay, const Duration(milliseconds: 500));
  });

  testWidgets('a hover with a pointer sits beside its target', (tester) async {
    await pump(
      tester,
      const IdeHover(
        message: 'Explorer',
        position: IdeHoverPosition.right,
        pointer: true,
        child: SizedBox(width: 48, height: 48, child: Icon(Codicons.files)),
      ),
    );
    await hover(tester, find.byIcon(Codicons.files));
    await tester.pump(ideHoverDelay + const Duration(milliseconds: 150));
    final hoverRect = tester.getRect(
      find
          .ancestor(
            of: find.text('Explorer'),
            matching: find.byType(IdeHoverBox),
          )
          .first,
    );
    final target = tester.getRect(find.byType(SizedBox).last);
    expect(hoverRect.left, greaterThan(target.right));
    expect(hoverRect.center.dy, closeTo(target.center.dy, 1));
  });

  testWidgets('a list row\'s title follows the pointer, as the `mouse` '
      'placement does', (tester) async {
    await pump(
      tester,
      const IdeHover(
        message: '~/project/assets',
        followMouse: true,
        child: SizedBox(width: 300, height: 22, child: Text('assets')),
      ),
    );
    final target = tester.getRect(find.byType(SizedBox).last);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    final at = Offset(target.left + 180, target.center.dy);
    await mouse.moveTo(at);
    await tester.pump();
    await tester.pump(ideHoverDelay + const Duration(milliseconds: 150));
    final hoverRect = tester.getRect(
      find
          .ancestor(
            of: find.text('~/project/assets'),
            matching: find.byType(IdeHoverBox),
          )
          .first,
    );
    // 10px right of the pointer, 2px over the row's bottom.
    expect(hoverRect.left, closeTo(at.dx + 10, 0.01));
    expect(hoverRect.top, closeTo(target.bottom - 2, 0.01));
  });

  testWidgets('scrolling over a file row tooltip still scrolls the list', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              const SizedBox(height: 100),
              const IdeHover(
                message: '~/project/a/very/long/file/path.dart',
                followMouse: true,
                child: SizedBox(height: 32, child: Text('file.dart')),
              ),
              for (var i = 0; i < 40; i++)
                SizedBox(height: 32, child: Text('$i')),
            ],
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('file.dart')));
    await tester.pump();
    await tester.pump(ideHoverDelay + const Duration(milliseconds: 150));
    const message = '~/project/a/very/long/file/path.dart';
    final tip = find.ancestor(
      of: find.text(message),
      matching: find.byType(IdeHoverBox),
    );
    expect(tip, findsOneWidget);
    final at = tester.getCenter(tip);
    await mouse.moveTo(at);
    await tester.pump();
    expect(find.text(message), findsOneWidget);

    await tester.sendEventToBinding(
      PointerScrollEvent(position: at, scrollDelta: const Offset(0, 120)),
    );
    await tester.pump();
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('interactive hover forwards wheel without losing its button', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              const SizedBox(height: 140),
              IdeHover(
                content: TextButton(
                  onPressed: () => taps++,
                  child: const Text('Open detail'),
                ),
                interactive: true,
                child: const SizedBox(height: 32, child: Text('row')),
              ),
              for (var i = 0; i < 40; i++)
                SizedBox(height: 32, child: Text('$i')),
            ],
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('row')));
    await tester.pump();
    await tester.pump(ideHoverDelay + const Duration(milliseconds: 150));
    final at = tester.getCenter(find.text('Open detail'));
    await mouse.moveTo(at);
    await tester.pump();
    await tester.sendEventToBinding(
      PointerScrollEvent(position: at, scrollDelta: const Offset(0, 30)),
    );
    await tester.pump();
    expect(controller.offset, greaterThan(0));
    await tester.tap(find.text('Open detail'));
    expect(taps, 1);
  });

  test('codicons are the pinned VS Code ones, and the font is bundled', () {
    // Spot checks against src/vs/base/common/codiconsLibrary.ts.
    expect(Codicons.files.codePoint, 0xeaf0);
    expect(Codicons.search.codePoint, 0xea6d);
    expect(Codicons.symbolClass.codePoint, 0xeb5b);
    expect(Codicons.lightBulb.codePoint, 0xea61);
    expect(Codicons.byName['source-control'], Codicons.sourceControl);
    expect(Codicons.files.fontFamily, 'codicon');
    expect(File('assets/codicons/codicon.ttf').lengthSync(), greaterThan(0));
    expect(
      File('assets/codicons/LICENSE').readAsStringSync(),
      contains('Attribution 4.0 International'),
    );
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('asset: assets/codicons/codicon.ttf'),
    );
  });
}
