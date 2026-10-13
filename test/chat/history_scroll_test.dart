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
    expect(find.textContaining('1.5k'), findsOneWidget);
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
    expect(position.pixels, lessThan(start));
    expect(position.pixels, greaterThan(start - 132));
    wheel();
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(start - 264, 1));

    wheel();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    position.jumpTo(start - 400);
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(start - 400, 1));
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
