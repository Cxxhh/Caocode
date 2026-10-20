import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/chat/widgets/edge_fade_mask.dart';
import 'package:caocode/chat/widgets/scroll_edge_fade.dart';

void main() {
  Future<ScrollController> pump(WidgetTester tester, int items) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            height: 100,
            child: ScrollEdgeFade(
              child: ListView(
                controller: controller,
                children: [
                  for (var i = 0; i < items; i++) const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  (bool, bool) edges(WidgetTester tester) {
    final mask = tester.widget<EdgeFadeMask>(find.byType(EdgeFadeMask));
    return (mask.top, mask.bottom);
  }

  testWidgets('fades the edges more of the list is past', (tester) async {
    final controller = await pump(tester, 10);
    expect(edges(tester), (false, true));

    controller.jumpTo(100);
    await tester.pump();
    expect(edges(tester), (true, true));

    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    expect(edges(tester), (true, false));
  });

  testWidgets('no fade when it all fits', (tester) async {
    await pump(tester, 2);
    expect(edges(tester), (false, false));
  });

  testWidgets('content grown past the bottom fades there the frame it '
      'grows, not a frame later', (tester) async {
    final tall = ValueNotifier(false);
    addTearDown(tall.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            height: 100,
            child: ScrollEdgeFade(
              child: ListView(
                children: [
                  ScrollEdgeFadeContent(
                    child: ValueListenableBuilder(
                      valueListenable: tall,
                      builder: (context, tall, _) =>
                          SizedBox(height: tall ? 300 : 40),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    RenderEdgeFadeMask mask() =>
        tester.renderObject<RenderEdgeFadeMask>(find.byType(EdgeFadeMask));
    expect(mask().debugLayer, isNull);

    tall.value = true;
    await tester.pump();
    expect(mask().debugLayer, isA<ShaderMaskLayer>());

    tall.value = false;
    await tester.pump();
    expect(mask().debugLayer, isNull);
  });

  testWidgets('a scrolled list whose content shrinks under it settles '
      'without a build asked for while laid out', (tester) async {
    final items = ValueNotifier(20);
    addTearDown(items.dispose);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            height: 100,
            child: ScrollEdgeFade(
              child: ValueListenableBuilder(
                valueListenable: items,
                builder: (context, items, _) => ListView(
                  controller: controller,
                  physics: const _KeepsPixels(),
                  children: [
                    for (var i = 0; i < items; i++) const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    controller.jumpTo(600);
    await tester.pump();
    // A shorter page in its place, the position left past its end (as a
    // bouncing list can be): it goes back in range as it is laid out, and
    // tells of that scroll then.
    items.value = 4;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(edges(tester), (true, false));
  });
}

/// Bounces, and leaves the position where it was when the content changes
/// (out of range, then).
class _KeepsPixels extends BouncingScrollPhysics {
  const _KeepsPixels({super.parent});

  @override
  _KeepsPixels applyTo(ScrollPhysics? ancestor) =>
      _KeepsPixels(parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) => newPosition.pixels;
}
