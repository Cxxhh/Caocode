import 'dart:convert';

import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/chat/widgets/image_thumbnails.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pixel.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  testWidgets('a gallery goes from one image to the next with its arrows '
      'and the keys, reading each as it shows', (tester) async {
    final read = <int>[];
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );
    showImageGallery(
      context,
      count: 4,
      index: 1,
      load: (index) async {
        read.add(index);
        return ImageAttachment(
          bytes: Uint8List.fromList(_png),
          mediaType: 'image/png',
          name: '$index.png',
        );
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('2 / 4'), findsOneWidget);
    // It and the ones beside it.
    expect(read.toSet(), {0, 1, 2});

    await tester.tap(find.byKey(const ValueKey('image-next')));
    await tester.pumpAndSettle();
    expect(find.text('3 / 4'), findsOneWidget);
    expect(read.toSet(), {0, 1, 2, 3});

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('4 / 4'), findsOneWidget);
    // The last: no further.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('4 / 4'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.tap(find.byKey(const ValueKey('image-previous')));
    await tester.pumpAndSettle();
    expect(find.text('2 / 4'), findsOneWidget);
    // Read once each.
    expect(read, hasLength(4));

    // The arrows are not the backdrop: it stays; a click beside closes it.
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tapAt(const Offset(400, 10));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('one image alone has no arrows', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      ),
    );
    showImagePreview(
      context,
      ImageAttachment(bytes: Uint8List.fromList(_png), mediaType: 'image/png'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    // Zooming must have the whole window to paint into, even for a tiny
    // image; the original image's bounds used to clip the zoomed content.
    expect(
      tester.getRect(find.byType(InteractiveViewer)),
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio),
    );
    expect(find.byKey(const ValueKey('image-next')), findsNothing);
    expect(find.textContaining(' / '), findsNothing);
  });
}
