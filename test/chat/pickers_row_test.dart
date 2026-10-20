import 'package:caocode/chat/composer/pickers_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const label = 'Default · 400K · X-High · a long model name';

  // As the composer has them: a scroll view the width of the room left.
  Future<void> pump(WidgetTester tester, double width) => tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: width,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: PickersRow(
                maxWidth: constraints.maxWidth,
                children: [
                  const SizedBox(key: Key('agent'), width: 100, height: 22),
                  // A picker's chip: its label cut short, the arrow kept.
                  Row(
                    key: const Key('model'),
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      SizedBox(key: Key('arrow'), width: 15, height: 15),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  bool cut(WidgetTester tester) =>
      tester.renderObject<RenderParagraph>(find.text(label)).didExceedMaxLines;

  testWidgets('the last is cut short to what is left, its arrow in view', (
    tester,
  ) async {
    await pump(tester, 250);
    expect(tester.getSize(find.byKey(const Key('model'))).width, 150);
    expect(cut(tester), isTrue);
    final row = tester.getRect(find.byType(PickersRow));
    expect(row.width, 250);
    expect(
      row.contains(
        tester.getRect(find.byKey(const Key('arrow'))).bottomRight -
            const Offset(0.5, 0.5),
      ),
      isTrue,
    );
  });

  testWidgets('with room, all of it', (tester) async {
    await pump(tester, 2000);
    expect(cut(tester), isFalse);
    expect(tester.getSize(find.byType(PickersRow)).width, lessThan(2000));
  });

  testWidgets('too narrow even so: cut down to its least, and scrolled', (
    tester,
  ) async {
    await pump(tester, 120);
    expect(tester.getSize(find.byKey(const Key('model'))).width, 64);
    expect(tester.getSize(find.byType(PickersRow)).width, 164);
    expect(tester.takeException(), isNull);
  });
}
