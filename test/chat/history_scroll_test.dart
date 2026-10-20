import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:caocode/chat/chat_feed.dart';
import 'package:caocode/chat/chat_history_view.dart';
import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/chat/chat_session.dart';
import 'package:caocode/chat/composer/composer_draft.dart';
import 'package:caocode/chat/widgets/turn_footer.dart';
import 'package:caocode/chat/reply_scroll.dart';
import 'package:caocode/theme/app_theme.dart';

/// A conversation held in a list, changed by hand.
class _Feed extends ChangeNotifier implements ChatFeed {
  _Feed(this.items, {this.streaming = false});

  List<ChatItem> items;
  bool streaming;
  bool unprompted = false;

  void update(
    List<ChatItem> next, {
    required bool streaming,
    bool unprompted = false,
  }) {
    items = next;
    this.streaming = streaming;
    this.unprompted = unprompted;
    notifyListeners();
  }

  @override
  int get itemCount => items.length;

  @override
  ChatItem itemAt(int index) => items[index];

  @override
  bool get isStreaming => streaming;

  @override
  bool get isUnprompted => unprompted;

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

/// Turn [n]: its message, [steps] reads each with a word, and (once done)
/// its answer.
List<ChatItem> _turn(int n, {int steps = 30, bool done = true}) => [
  UserMessageItem(
    text: 'Question $n',
    worked: done ? const Duration(seconds: 65) : null,
  ),
  for (var i = 0; i < steps; i++) ...[
    ToolCallItem(kind: ToolKind.read, target: 't${n}_$i.dart'),
    AssistantTextItem('Turn $n step $i.'),
  ],
  if (done) AssistantTextItem('Answer $n.'),
];

Future<void> _pump(WidgetTester tester, ChatFeed feed) async {
  tester.view.physicalSize = const Size(1000, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: ChatHistoryView(feed: feed)),
    ),
  );
  await tester.pump();
}

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

/// Wheels the list up by [by].
Future<void> _wheelUp(WidgetTester tester, double by) async {
  tester.binding.handlePointerEvent(
    PointerScrollEvent(
      position: tester.getCenter(find.byType(ChatHistoryView)),
      scrollDelta: Offset(0, -by),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _text(String text) => find.textContaining(text, findRichText: true);

/// A frame at 60 a second.
const _frame = Duration(microseconds: 16667);

void main() {
  testWidgets('a folded last step keeps the completed turn statistics', (
    tester,
  ) async {
    final feed = _Feed(const [
      UserMessageItem(
        text: 'Inspect the project',
        worked: Duration(seconds: 65),
        usage: TurnUsage(inputTokens: 1200, outputTokens: 300),
      ),
      ToolCallItem(kind: ToolKind.read, target: 'a.dart'),
      ToolCallItem(kind: ToolKind.grep, target: 'callback'),
    ]);
    await _pump(tester, feed);
    expect(find.byType(TurnFooter), findsOneWidget);
    expect(find.textContaining('1.50k'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TurnFooter),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
    );
  });

  testWidgets('an untimed restored answer can be copied without false stats', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final feed = _Feed(const [
      UserMessageItem(text: 'Explain the change'),
      ThinkingItem(
        text: 'Check callbacks',
        tokens: 0,
        summarized: true,
        streaming: false,
      ),
      AssistantTextItem('The first part.'),
      AssistantTextItem('The final part.'),
    ]);
    await _pump(tester, feed);
    final footer = find.byType(TurnFooter);
    expect(footer, findsOneWidget);
    expect(find.textContaining('1s'), findsNothing);
    await tester.tap(
      find.descendant(of: footer, matching: find.byType(GestureDetector)),
    );
    await tester.pump();
    expect(copied, 'The first part.\n\nThe final part.');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mouse wheel moves over frames and accumulates rapid notches', (
    tester,
  ) async {
    await _pump(
      tester,
      _Feed([for (var n = 0; n < 40; n++) ..._turn(n, steps: 0)]),
    );
    await tester.pumpAndSettle();
    final position = _position(tester);
    final start = position.pixels;
    // Track wheel movement separately from the virtual list's corrections
    // as it measures rows above the viewport for the first time.
    final dynamic controller = tester
        .widget<SuperListView>(find.byType(SuperListView))
        .controller;
    final before = controller.scrolled as double;
    double moved() => (controller.scrolled as double) - before;
    void wheel() => tester.binding.handlePointerEvent(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: tester.getCenter(find.byType(ChatHistoryView)),
        scrollDelta: const Offset(0, -60),
      ),
    );
    wheel();
    expect(position.pixels, start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(moved(), lessThan(0));
    expect(moved(), greaterThan(-60));
    wheel();
    await tester.pumpAndSettle();
    expect(moved(), closeTo(-120, 1));

    wheel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    position.jumpTo(start - 400);
    final stopped = moved();
    await tester.pumpAndSettle();
    expect(moved(), stopped);
  });

  testWidgets(
    'scrollbar dragging keeps the message subtree and tracks the pointer',
    (tester) async {
      await _pump(tester, _Feed([for (var n = 0; n < 100; n++) ..._turn(n)]));
      await tester.pumpAndSettle();
      final list = tester.widget<SuperListView>(find.byType(SuperListView));
      final position = _position(tester);
      final start = position.pixels;
      final rect = tester.getRect(find.byType(ChatHistoryView));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      final at = Offset(rect.right - 5, rect.bottom - 20);
      await mouse.addPointer(location: at);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SuperListView>(find.byType(SuperListView)),
        same(list),
      );
      await mouse.down(at);
      for (var step = 1; step <= 8; step++) {
        await mouse.moveTo(at - Offset(0, step * 45));
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.takeException(), isNull);
        expect(
          tester.widget<SuperListView>(find.byType(SuperListView)),
          same(list),
        );
      }
      await mouse.up();
      await tester.pumpAndSettle();
      expect(position.pixels, lessThan(start / 2));
    },
  );

  testWidgets('folded work counts for nothing before it is laid out', (
    tester,
  ) async {
    await _pump(tester, _Feed([for (var n = 0; n < 40; n++) ..._turn(n)]));
    final position = _position(tester);
    final estimated = position.maxScrollExtent;

    // Up to the top, every item laid out on the way.
    while (position.pixels > 0) {
      position.jumpTo(position.pixels - 500 < 0 ? 0 : position.pixels - 500);
      await tester.pump();
    }
    // Each folded step taken at a row's height, the estimate would be some
    // twenty times this.
    expect(estimated, lessThan(position.maxScrollExtent * 2));
  });

  testWidgets('a mouse wheel\'s notch moves the list its own distance over '
      'a few frames, the next adding to what it had left; a trackpad\'s at '
      'once', (tester) async {
    await _pump(tester, _Feed([for (var n = 0; n < 10; n++) ..._turn(n)]));
    final position = _position(tester);
    final bottom = position.pixels;
    expect(bottom, position.maxScrollExtent);

    void wheel(double by, {PointerDeviceKind kind = PointerDeviceKind.mouse}) =>
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: tester.getCenter(find.byType(ChatHistoryView)),
            scrollDelta: Offset(0, by),
            kind: kind,
          ),
        );

    wheel(-100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // As far as the wheel says, as Chrome's.
    const step = 100.0;
    // On its way, not there yet.
    expect(position.pixels, lessThan(bottom));
    expect(position.pixels, greaterThan(bottom - step));
    wheel(-100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(position.pixels, closeTo(bottom - 2 * step, 0.5));

    final before = position.pixels;
    wheel(-100, kind: PointerDeviceKind.trackpad);
    await tester.pump();
    expect(position.pixels, closeTo(before - 100, 0.5));

    // Back down past the end: at the end, anchored again.
    wheel(1000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('a notch is under way in the frame after it, a third of the '
      'way, and there in 120 ms, slowing to rest; one more mid-way goes on '
      'from where the list is, never stopping', (tester) async {
    await _pump(tester, _Feed([for (var n = 0; n < 10; n++) ..._turn(n)]));
    final position = _position(tester);
    final bottom = position.pixels;
    void wheel() => tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ChatHistoryView)),
        scrollDelta: const Offset(0, -100),
      ),
    );

    wheel();
    final moved = <double>[0];
    for (var i = 0; i < 8; i++) {
      await tester.pump(_frame);
      moved.add(bottom - position.pixels);
    }
    expect(moved[1], greaterThan(33));
    // Each frame less than the one before (none eased in).
    for (var i = 2; i < 8; i++) {
      expect(moved[i] - moved[i - 1], lessThan(moved[i - 1] - moved[i - 2]));
    }
    expect(moved[6], lessThan(100));
    expect(moved[8], closeTo(100, 0.5));

    // Mid-way, another: the list keeps moving, and gets 200 further.
    final start = position.pixels;
    wheel();
    await tester.pump(_frame);
    await tester.pump(_frame);
    wheel();
    var last = position.pixels;
    for (var i = 0; i < 6; i++) {
      await tester.pump(_frame);
      expect(position.pixels, lessThan(last));
      last = position.pixels;
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(start - position.pixels, closeTo(200, 0.5));
  });

  testWidgets('on a faster display, its first frame goes as far as a frame '
      'of that display, not one at 60 a second', (tester) async {
    tester.view.display.refreshRate = 144;
    addTearDown(tester.view.display.resetRefreshRate);
    await _pump(tester, _Feed([for (var n = 0; n < 10; n++) ..._turn(n)]));
    final position = _position(tester);
    final bottom = position.pixels;
    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ChatHistoryView)),
        scrollDelta: const Offset(0, -100),
      ),
    );
    const frame = Duration(microseconds: 6944);
    await tester.pump(frame);
    final first = bottom - position.pixels;
    await tester.pump(frame);
    final second = bottom - position.pixels - first;
    // Little more than the next, as the curve slows (not a jump, then a
    // crawl).
    expect(first, greaterThan(second));
    expect(first, lessThan(second * 1.3));
  });

  testWidgets('rows laid out for the first time as the wheel moves the list '
      'up (the whole way, in a conversation just opened) neither move it '
      'back nor further than the wheel says', (tester) async {
    // Answers of their own heights, far from the one they are taken at
    // until laid out.
    await _pump(
      tester,
      _Feed([
        for (var n = 0; n < 30; n++) ...[
          UserMessageItem(text: 'Question $n'),
          AssistantTextItem(
            [
              for (var p = 0; p < 4; p++)
                'A${n}p$p ${'word ' * (20 + (n * 37 + p * 11) % 90)}',
            ].join('\n\n'),
          ),
        ],
      ]),
    );
    final position = _position(tester);
    final extent = position.maxScrollExtent;
    final label = RegExp(r'A\d+p\d+');

    /// Where each paragraph is.
    Map<String, double> tops() {
      final tops = <String, double>{};
      for (final element
          in find.textContaining(label, findRichText: true).evaluate()) {
        if (element.widget case RichText(:final text)) {
          final box = element.renderObject! as RenderBox;
          tops[label.firstMatch(text.toPlainText())!.group(0)!] = box
              .localToGlobal(Offset.zero)
              .dy;
        }
      }
      return tops;
    }

    var shown = 0.0;
    var before = tops();
    // Forty notches, one every three frames.
    for (var frame = 0; frame < 150; frame++) {
      if (frame < 120 && frame % 3 == 0) {
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: tester.getCenter(find.byType(ChatHistoryView)),
            scrollDelta: const Offset(0, -40),
          ),
        );
      }
      await tester.pump(_frame);
      final after = tops();
      // How far what is shown moved: down, the list going up.
      final moves = [
        for (final MapEntry(:key, :value) in before.entries)
          if (after[key] case final top?) top - value,
      ]..sort();
      expect(moves, isNotEmpty);
      final moved = moves[moves.length ~/ 2];
      expect(moved, greaterThanOrEqualTo(-0.01), reason: 'frame $frame');
      shown += moved;
      before = after;
    }
    expect(shown, closeTo(40 * 40, 0.5));
    // The rows on the way were laid out at heights of their own.
    expect((position.maxScrollExtent - extent).abs(), greaterThan(100));
  });

  testWidgets('a notch up from the bottom leaves it, however little it moves '
      'the list in its first frames', (tester) async {
    await _pump(tester, _Feed([for (var n = 0; n < 10; n++) ..._turn(n)]));
    final position = _position(tester);
    final bottom = position.pixels;

    tester.binding.handlePointerEvent(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(ChatHistoryView)),
        scrollDelta: const Offset(0, -2),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(_frame);
    }
    expect(position.pixels, closeTo(bottom - 2, 0.01));
  });

  group('a turn starting while the user reads further up', () {
    final history = [for (var n = 0; n < 3; n++) ..._turn(n)];

    /// History, then turn 3, under way: the user scrolls up into it, and
    /// it ends there.
    Future<_Feed> readTurnThatEnded(WidgetTester tester) async {
      final feed = _Feed([
        ...history,
        ..._turn(3, done: false),
      ], streaming: true);
      await _pump(tester, feed);
      await _wheelUp(tester, 600);
      feed.update([...history, ..._turn(3)], streaming: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return feed;
    }

    testWidgets('one the agent took up leaves them there, the turn open', (
      tester,
    ) async {
      final feed = await readTurnThatEnded(tester);
      final pixels = _position(tester).pixels;
      expect(_text('Turn 3 step '), findsWidgets);

      // A background task's report.
      for (final streaming in [true, true, false]) {
        feed.update(
          [...feed.items, AssistantTextItem('Noted ${feed.items.length}.')],
          streaming: streaming,
          unprompted: streaming,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      expect(_position(tester).pixels, pixels);
      expect(_text('Turn 3 step '), findsWidgets);
    });

    testWidgets('one the user sent brings the bottom into view', (
      tester,
    ) async {
      final feed = await readTurnThatEnded(tester);

      feed.update([
        ...feed.items,
        const UserMessageItem(text: 'Next'),
      ], streaming: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final position = _position(tester);
      expect(position.pixels, position.maxScrollExtent);
    });
  });

  group('as the reply to a message sent comes', () {
    final history = [for (var n = 0; n < 3; n++) ..._turn(n)];
    tearDown(() => ReplyScroll.current.value = ReplyScroll.follow);

    /// Writes [lines] of the reply, one by one.
    Future<void> write(WidgetTester tester, _Feed feed, int lines) async {
      for (var i = 0; i < lines; i++) {
        feed.update([
          ...feed.items,
          AssistantTextItem('Reply line ${feed.items.length}.'),
        ], streaming: true);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    /// Sends a message, then writes [lines] of its reply one by one.
    Future<_Feed> reply(WidgetTester tester, int lines) async {
      final feed = _Feed(history);
      await _pump(tester, feed);
      feed.update([
        ...history,
        const UserMessageItem(text: 'Next'),
      ], streaming: true);
      await tester.pump();
      await write(tester, feed, lines);
      return feed;
    }

    /// The message in the list (not a copy stuck to the top).
    final message = find.descendant(
      of: find.byType(Scrollable).first,
      matching: _text('Next'),
    );

    /// The message's top, below the list's.
    double messageTop(WidgetTester tester) =>
        tester.getTopLeft(message).dy -
        tester.getTopLeft(find.byType(ChatHistoryView)).dy;

    testWidgets('automatic, the list follows it to its end', (tester) async {
      await reply(tester, 40);
      final position = _position(tester);
      expect(position.pixels, position.maxScrollExtent);
      expect(message.hitTestable(), findsNothing);
    });

    testWidgets('at its start, the list stops with the message at the top; '
        'taken to the end, it follows again', (tester) async {
      ReplyScroll.current.value = ReplyScroll.start;
      // Short: followed as it is.
      final feed = await reply(tester, 3);
      final position = _position(tester);
      expect(position.pixels, position.maxScrollExtent);

      await write(tester, feed, 40);
      final stopped = position.pixels;
      expect(stopped, lessThan(position.maxScrollExtent - 500));
      expect(messageTop(tester), inInclusiveRange(0, 40));
      await write(tester, feed, 5);
      expect(position.pixels, stopped);

      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(ChatHistoryView)),
          scrollDelta: const Offset(0, 100000),
        ),
      );
      await tester.pumpAndSettle();
      await write(tester, feed, 5);
      expect(position.pixels, position.maxScrollExtent);
    });
  });

  testWidgets('opened mid-turn, scrolled up, the next output leaves them', (
    tester,
  ) async {
    final history = [for (var n = 0; n < 3; n++) ..._turn(n)];
    final feed = _Feed([
      ...history,
      ..._turn(3, steps: 20, done: false),
    ], streaming: true);
    await _pump(tester, feed);
    await _wheelUp(tester, 600);
    final pixels = _position(tester).pixels;

    feed.update([
      ...history,
      ..._turn(3, steps: 21, done: false),
    ], streaming: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(_position(tester).pixels, pixels);
  });
}
