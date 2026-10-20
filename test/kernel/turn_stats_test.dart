import 'dart:io';

import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/kernel/claude_code/turn_stats.dart';
import 'package:caocode/kernel/claude_code/turn_stats_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('caocode-turns-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('kept and read back, by session and turn', () async {
    final stats = TurnStatsFiles(dir.path);
    stats.write('s1', 'u1', (
      worked: const Duration(seconds: 58),
      usage: const TurnUsage(
        inputTokens: 395000,
        outputTokens: 1200,
        tokensPerSecond: 203.05,
        costUsd: 0.41,
      ),
    ));
    stats.write('s1', 'u2', (worked: const Duration(seconds: 3), usage: null));
    stats.write('s2', 'u9', (worked: const Duration(seconds: 1), usage: null));
    final read = await stats.read('s1');
    expect(read.keys, ['u1', 'u2']);
    expect(read['u1']!.worked, const Duration(seconds: 58));
    expect(read['u1']!.usage!.totalTokens, 396200);
    expect(read['u1']!.usage!.tokensPerSecond, 203.05);
    expect(read['u1']!.usage!.costUsd, 0.41);
    expect(read['u2']!.usage, isNull);
    expect(await stats.read('none'), isEmpty);
  });

  test('a line cut off is passed over; a turn kept again, the last stands', () {
    final records = TurnStats.decode([
      TurnStats.encode('u1', (worked: const Duration(seconds: 1), usage: null)),
      '{"turn":"u2","workedMs":',
      TurnStats.encode('u1', (worked: const Duration(seconds: 2), usage: null)),
      '',
    ]);
    expect(records.keys, ['u1']);
    expect(records['u1']!.worked, const Duration(seconds: 2));
  });

  test('a session id that is no file name is not kept', () async {
    final stats = TurnStatsFiles(dir.path);
    stats.write('../s', 'u1', (
      worked: const Duration(seconds: 1),
      usage: null,
    ));
    expect(dir.listSync(recursive: true), isEmpty);
    expect(await stats.read('../s'), isEmpty);
  });

  test('written by many at once, no line lost or broken', () async {
    // Every session writes from the one isolate: a line each, in one go.
    final writers = [for (var i = 0; i < 4; i++) TurnStatsFiles(dir.path)];
    await Future.wait([
      for (final (w, stats) in writers.indexed)
        () async {
          for (var i = 0; i < 100; i++) {
            stats.write('s', 'w$w-$i', (
              worked: Duration(milliseconds: i),
              usage: TurnUsage(inputTokens: i, outputTokens: w),
            ));
            await Future<void>.delayed(Duration.zero);
          }
        }(),
    ]);
    final lines = File(p.join(dir.path, 's.jsonl')).readAsLinesSync();
    expect(lines, hasLength(400));
    final read = await TurnStatsFiles(dir.path).read('s');
    expect(read, hasLength(400));
    expect(read['w3-99']!.usage!.inputTokens, 99);
  });
}
