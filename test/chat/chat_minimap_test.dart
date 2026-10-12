import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/widgets/assistant_text.dart';
import 'package:baocode/chat/widgets/chat_minimap.dart';
import 'package:baocode/theme/app_theme.dart';

class _Feed extends ChangeNotifier implements ChatFeed {
  _Feed(this.items);

  final List<ChatItem> items;
  int reads = 0;

  @override
  int get itemCount => items.length;

  @override
  ChatItem itemAt(int index) {
    reads++;
    return items[index];
  }

  @override
  bool get isStreaming => false;

  @override
  bool get isUnprompted => false;

  @override
  bool get canEditMessages => false;

  @override
  ({int index, ComposerDraft draft})? get editing => null;

  @override
  set editing(({int index, ComposerDraft draft})? value) {}

  @override
  void editMessage(int index, ComposerMessage message) {}

  @override
  VoidCallback? moveToBackgroundAt(int index) => null;

  @override
  VoidCallback? stopAt(int index) => null;
}

/// [turns] questions, each answered at length: with a heading, a list, a
/// code block and a table.
List<ChatItem> _conversation(int turns) => [
  for (var n = 0; n < turns; n++) ...[
    UserMessageItem(text: '问题 $n：这个函数为什么会在窄窗口下溢出？'),
    AssistantTextItem(
      '## Answer $n\n\n'
      '${'The column keeps its width while the pane shrinks. ' * 6}\n\n'
      '- first point\n- second point\n\n'
      '```dart\nfinal width = math.min(maxWidth, available);\n'
      '  return width;\n```\n\n'
      '| a | b |\n|---|---|\n| 1 | 2 |\n',
    ),
  ],
];

Future<void> _pump(
  WidgetTester tester,
  ChatFeed feed, {
  double width = 1200,
  double maxWidth = 720,
  bool minimap = true,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: ChatHistoryView(
          feed: feed,
          maxContentWidth: maxWidth,
          minimap: minimap,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

Finder get _strip => find.descendant(
  of: find.byType(ChatMinimap),
  matching: find.byType(CustomPaint),
);

/// The minimap's track: its paint but the room either side for the glass,
/// which is a little wider.
Rect _track(WidgetTester tester) {
  final strip = tester.getRect(_strip);
  final outset = (strip.width - 24) / 2;
  expect(outset, greaterThan(0));
  return Rect.fromLTRB(
    strip.left + outset,
    strip.top,
    strip.right - outset,
    strip.bottom,
  );
}

double _opacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.descendant(
        of: find.byType(ChatMinimap),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

Scrollbar _scrollbar(WidgetTester tester) =>
    tester.widget<Scrollbar>(find.byType(Scrollbar).first);

void main() {
  testWidgets('scrolling does not reread the whole history for the minimap', (
    tester,
  ) async {
    final feed = _Feed(_conversation(300));
    await _pump(tester, feed);
    final position = _position(tester);
    // A first seek also fills the list's extent estimates. Once those
    // exist, changing the scroll overlays must not resample every row.
    position.jumpTo(position.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    feed.reads = 0;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(feed.reads, lessThan(feed.itemCount));
    expect(_strip, findsOneWidget);
  });

  testWidgets('shows in the margin left of the column', (tester) async {
    await _pump(tester, _Feed(_conversation(30)));
    expect(_opacity(tester), 1);
    final strip = _track(tester);
    // The column is 720 wide in the middle of 1200 (less its gutters).
    expect(strip.right, lessThanOrEqualTo(240 - 16));
    expect(strip.left, greaterThanOrEqualTo(16));
    // However roomy the margin, as narrow.
    expect(strip.width, 24);
    // It stands in for the scrollbar.
    expect(_scrollbar(tester).interactive, isFalse);
  });

  for (final width in [1300.0, 790.0]) {
    testWidgets(
      'a column as wide as a ${width.round()} window leaves it room',
      (tester) async {
        await _pump(
          tester,
          _Feed(_conversation(30)),
          width: width,
          maxWidth: 1200,
        );
        expect(_opacity(tester), 1);
        final strip = _track(tester);
        final text = tester.getRect(find.byType(AssistantText).first);
        expect(strip.left, greaterThanOrEqualTo(12));
        // Room to breathe beside the text, as much on the other side.
        expect(strip.right, lessThanOrEqualTo(text.left - 20));
        expect(text.left, greaterThanOrEqualTo(ChatMinimap.room));
        expect(width - text.right, greaterThanOrEqualTo(ChatMinimap.room));
      },
    );
  }

  testWidgets('gives way in a narrow pane', (tester) async {
    await _pump(tester, _Feed(_conversation(30)), width: 600);
    expect(_opacity(tester), 0);
    // The scrollbar is back.
    expect(_scrollbar(tester).interactive, isTrue);
  });

  testWidgets('not while all of the history shows', (tester) async {
    await _pump(tester, _Feed(_conversation(1)));
    expect(_opacity(tester), 0);
  });

  testWidgets('not where it is not asked for (the IDE)', (tester) async {
    await _pump(tester, _Feed(_conversation(30)), minimap: false);
    expect(find.byType(ChatMinimap), findsNothing);
  });

  testWidgets('a press scrolls there, a drag to the end back to it', (
    tester,
  ) async {
    await _pump(tester, _Feed(_conversation(30)));
    final position = _position(tester);
    expect(position.pixels, position.maxScrollExtent);
    final strip = tester.getRect(_strip);

    // Near its top: the start of the conversation.
    await tester.tapAt(strip.topCenter + const Offset(0, 4));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(position.maxScrollExtent * 0.1));

    // Its glass dragged all the way down: at the end, and held there.
    final gesture = await tester.startGesture(
      strip.topCenter + const Offset(0, 6),
    );
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(Offset(0, strip.height / 10));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('the wheel over it scrolls the history', (tester) async {
    await _pump(tester, _Feed(_conversation(30)));
    final position = _position(tester);
    final before = position.pixels;
    final strip = tester.getRect(_strip);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(strip.center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -300)));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(before));
  });
}
