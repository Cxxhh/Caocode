import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/main.dart';
import 'package:caocode/theme/code_font.dart';
import 'package:caocode/theme/ui_zoom.dart';
import 'package:caocode/workspace/workspace.dart';

void main() {
  testWidgets('lays out in the space divided by its scale, and paints, hits '
      'and places what it holds scaled back up', (tester) async {
    tester.view.physicalSize = const Size(600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    var taps = 0;
    late MediaQueryData inner;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: UiZoom.zoomed(const MediaQueryData(size: Size(600, 400)), 1.5),
          child: UiZoom(
            scale: 1.5,
            child: Builder(
              builder: (context) {
                inner = MediaQuery.of(context);
                return Align(
                  alignment: Alignment.topLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 100, top: 20),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => taps++,
                      child: SizedBox(key: key, width: 40, height: 22),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(inner.size, const Size(400, 400 / 1.5));
    expect(inner.devicePixelRatio, 1.5);
    // Its own size, in its own units; in the window's, half as much again.
    expect(tester.getSize(find.byKey(key)), const Size(40, 22));
    final box = tester.renderObject<RenderBox>(find.byKey(key));
    expect(box.localToGlobal(Offset.zero), const Offset(150, 30));
    expect(
      box.localToGlobal(const Offset(40, 22)),
      const Offset(150 + 60, 30 + 33),
    );

    // Hit where it is drawn, not where it would be unscaled.
    await tester.tapAt(const Offset(205, 60));
    expect(taps, 1);
    await tester.tapAt(const Offset(120, 25));
    expect(taps, 1);
  });

  testWidgets('at 1 it adds no layer', (tester) async {
    await tester.pumpWidget(
      const UiZoom(scale: 1, child: SizedBox.expand()),
    );
    expect(
      tester.renderObject<RenderUiZoom>(find.byType(UiZoom)).debugLayer,
      isNull,
    );
  });

  testWidgets('the window grows with the interface size: its rows as its '
      'text, and code keeps its own size', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => CodeFont.uiScale.value = CodeFont.defaultUiScale);

    Future<Rect> rowAt(int percent) async {
      CodeFont.uiScale.value = percent;
      await tester.pumpWidget(CaocodeApp(workspace: Workspace.mock()));
      await tester.pump();
      final row = find.text('Sticky user message on scroll');
      final box = tester.renderObject<RenderBox>(row);
      return box.localToGlobal(Offset.zero) &
          (box.localToGlobal(box.size.bottomRight(Offset.zero)) -
                  box.localToGlobal(Offset.zero))
              .toSize();
    }

    final normal = await rowAt(100);
    final large = await rowAt(150);
    expect(large.height, moreOrLessEquals(normal.height * 1.5, epsilon: 0.01));
    expect(large.top, moreOrLessEquals(normal.top * 1.5, epsilon: 0.01));

    // The interface's text scale is the system's, the zoom doing the rest;
    // code's takes the zoom back off.
    final context = tester.element(find.text('Sticky user message on scroll'));
    expect(MediaQuery.textScalerOf(context).scale(10), 10);
    expect(SystemTextScale.maybeOf(context)!.scale(15), moreOrLessEquals(10));

    // A right click opens the menu where it was.
    final at = tester.getCenter(find.text('Sticky user message on scroll'));
    await tester.tapAt(at, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    final rename = tester.getTopLeft(find.text('Rename'));
    expect((rename - at).distance, lessThan(80));
  });
}

extension on Offset {
  Size toSize() => Size(dx, dy);
}
