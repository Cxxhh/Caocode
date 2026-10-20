import 'package:caocode/chat/widgets/live_selectable_text.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a selection kept while its text wraps anew in a scrolled '
      'box: told to its container after the layout, not during', (
    tester,
  ) async {
    var width = 400.0;
    late StateSetter setWidth;
    final text = List.filled(40, 'streamed words wrap here').join(' ');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: StatefulBuilder(
              builder: (context, setState) {
                setWidth = setState;
                // As in the chat: a capped box that scrolls, in the
                // conversation's list, which scrolls too.
                return ListView(
                  children: [
                    Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: width,
                        height: 200,
                        child: SingleChildScrollView(
                          child: LiveSelectableText(text),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    final live = find.byType(LiveSelectableText);
    RenderLiveSelectableText render() => tester.renderObject(live);
    final rect = tester.getRect(live);
    final drag = await tester.startGesture(
      rect.topLeft + const Offset(20, 10),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await drag.moveTo(rect.topLeft + const Offset(200, 60));
    await tester.pump();
    await drag.up();
    await tester.pump(const Duration(milliseconds: 500));
    String? selected() => render().selection?.textInside(render().text);
    final before = selected();
    expect(before, hasLength(greaterThan(10)));

    // Narrower: the same characters on other lines, other rects.
    for (final next in [260.0, 330.0, 220.0]) {
      setWidth(() => width = next);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(selected(), before);
    }
  });
}
