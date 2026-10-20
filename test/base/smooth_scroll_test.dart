import 'package:bao_editor/monaco/flutter/wheel_glide.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/base/smooth_scroll.dart';

const _frame = Duration(microseconds: 16667);

/// Two lists of 100 rows 40 high side by side, each with a controller of
/// its own ([SmoothScrolling]); the left one's handed to [left].
Future<void> _lists(
  WidgetTester tester,
  void Function(ScrollController controller) left,
) async {
  Widget list(void Function(ScrollController controller)? shown) => Expanded(
    child: SmoothScrolling(
      builder: (context, controller) {
        shown?.call(controller);
        return ListView.builder(
          controller: controller,
          itemCount: 100,
          itemExtent: 40,
          itemBuilder: (context, index) => Text('Row $index'),
        );
      },
    ),
  );
  await tester.pumpWidget(
    MaterialApp(home: Row(children: [list(left), list(null)])),
  );
}

Future<void> _wheel(
  WidgetTester tester,
  Offset at,
  double dy, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
}) => tester.sendEventToBinding(
  PointerScrollEvent(position: at, scrollDelta: Offset(0, dy), kind: kind),
);

void main() {
  testWidgets('a mouse wheel glides a list: under way in the frame after the '
      'notch, a third of the way, and there in 120 ms; a trackpad\'s scroll '
      'moves it at once', (tester) async {
    late ScrollController controller;
    await _lists(tester, (shown) => controller = shown);
    final at = tester.getCenter(find.byType(ListView).first);

    await _wheel(tester, at, 120);
    await tester.pump(_frame);
    expect(controller.offset / 120, inInclusiveRange(0.3, 0.4));
    expect((controller as SmoothScrollController).headedTo, 120);
    await tester.pump(WheelGlide.duration);
    expect(controller.offset, 120);
    expect(controller.position.isScrollingNotifier.value, isFalse);

    await _wheel(tester, at, 50, kind: PointerDeviceKind.trackpad);
    expect(controller.offset, 170);
  });

  testWidgets('the next notch adds to what the last had left, from where the '
      'list is; one back stops it; a glide stops at the end', (tester) async {
    late ScrollController controller;
    await _lists(tester, (shown) => controller = shown);
    final at = tester.getCenter(find.byType(ListView).first);

    await _wheel(tester, at, 100);
    await tester.pump(_frame);
    await _wheel(tester, at, 100);
    var last = controller.offset;
    while (last < 200 - 0.01) {
      await tester.pump(_frame);
      // Never still on the way, nor back.
      expect(controller.offset, greaterThan(last));
      last = controller.offset;
    }
    await tester.pump(WheelGlide.duration);
    expect(controller.offset, moreOrLessEquals(200));

    // Back the way it came, all it had left: it stops where it is.
    await _wheel(tester, at, 100);
    await tester.pump(_frame);
    final stopped = controller.offset;
    final headedTo = (controller as SmoothScrollController).headedTo;
    await _wheel(tester, at, stopped - headedTo);
    await tester.pump(_frame);
    await tester.pump(WheelGlide.duration);
    expect(controller.offset, stopped);

    final end = controller.position.maxScrollExtent;
    await _wheel(tester, at, 1e5);
    await tester.pump(_frame);
    await tester.pump(WheelGlide.duration);
    expect(controller.offset, end);
    expect(controller.position.isScrollingNotifier.value, isFalse);
  });

  testWidgets('each list its own: wheeling one leaves the other', (
    tester,
  ) async {
    late ScrollController controller;
    await _lists(tester, (shown) => controller = shown);
    final right = find.byType(ListView).last;
    await _wheel(tester, tester.getCenter(right), 200);
    await tester.pump(_frame);
    await tester.pump(WheelGlide.duration);
    expect(controller.offset, 0);
    final other = tester.state<ScrollableState>(
      find.descendant(of: right, matching: find.byType(Scrollable)),
    );
    expect(other.position.pixels, 200);
  });
}
