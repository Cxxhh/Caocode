import 'package:caocode/chat/steadiness.dart';
import 'package:flutter_test/flutter_test.dart';

// Under testWidgets for its fake time, which runs the timers.
void main() {
  late int changes;
  late Steadiness steady;

  setUp(() {
    changes = 0;
    steady = Steadiness(onChange: () => changes++);
  });
  tearDown(() => steady.dispose());

  testWidgets('what is done in a blink never shows', (tester) async {
    expect(steady.shows('a', wanted: true), isFalse);
    await tester.pump(const Duration(milliseconds: 100));
    expect(steady.shows('a', wanted: false), isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(steady.shows('a', wanted: false), isFalse);
    expect(changes, 0);
  });

  testWidgets('what lasts shows after the delay, and stays for the hold', (
    tester,
  ) async {
    expect(steady.shows('a', wanted: true), isFalse);
    await tester.pump(const Duration(milliseconds: 301));
    expect(changes, 1);
    expect(steady.shows('a', wanted: true), isTrue);
    // Done just after: kept.
    await tester.pump(const Duration(milliseconds: 100));
    expect(steady.shows('a', wanted: false), isTrue);
    await tester.pump(const Duration(milliseconds: 601));
    expect(changes, 2);
    expect(steady.shows('a', wanted: false), isFalse);
  });

  testWidgets('long shown, it goes at once', (tester) async {
    steady.shows('a', wanted: true);
    await tester.pump(const Duration(milliseconds: 301));
    expect(steady.shows('a', wanted: true), isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(steady.shows('a', wanted: false), isFalse);
  });

  testWidgets('shown at once, not delayed, and held all the same', (
    tester,
  ) async {
    expect(steady.shows('a', wanted: true, delayed: false), isTrue);
    await tester.pump(const Duration(milliseconds: 100));
    expect(steady.shows('a', wanted: false), isTrue);
    await tester.pump(const Duration(milliseconds: 601));
    expect(steady.shows('a', wanted: false), isFalse);
  });

  testWidgets('cleared, it forgets, its timers stopped', (tester) async {
    steady.shows('a', wanted: true);
    steady.shows('b', wanted: true, delayed: false);
    steady.clear();
    await tester.pump(const Duration(seconds: 1));
    expect(changes, 0);
    expect(steady.shows('b', wanted: false), isFalse);
  });
}
