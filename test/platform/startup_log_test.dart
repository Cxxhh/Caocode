import 'dart:async';

import 'package:caocode/platform/startup_log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

(List<String>, VoidCallback) captureStartupOutput() {
  final lines = <String>[];
  final previous = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    if (message?.contains('[Caocode][启动]') == true) {
      lines.add(message!);
    } else {
      previous(message, wrapWidth: wrapWidth);
    }
  };
  return (lines, () => debugPrint = previous);
}

void main() {
  testWidgets('startup succeeds only after the first window frame', (
    tester,
  ) async {
    final (lines, restore) = captureStartupOutput();
    try {
      final previousFlutter = FlutterError.onError;
      final previousPlatform = PlatformDispatcher.instance.onError;
      final nativeFrame = Completer<void>();
      final startup = StartupLog(
        waitUntilFirstFrameRasterized: () => nativeFrame.future,
      );
      final finished = startup.run(() async {
        runApp(const SizedBox.shrink());
      });
      await tester.idle();
      expect(lines.any((line) => line.contains('启动成功')), isFalse);
      await tester.pump();
      expect(lines.any((line) => line.contains('启动成功')), isFalse);
      nativeFrame.complete();
      await finished;
      expect(lines.where((line) => line.contains('启动成功')), hasLength(1));
      expect(lines.last, contains('主窗口首帧已绘制'));
      expect(FlutterError.onError, same(previousFlutter));
      expect(PlatformDispatcher.instance.onError, same(previousPlatform));
    } finally {
      restore();
    }
  });

  testWidgets('initialization failure reports the stage and preserves errors', (
    tester,
  ) async {
    final (lines, restore) = captureStartupOutput();
    try {
      final previousFlutter = FlutterError.onError;
      final previousPlatform = PlatformDispatcher.instance.onError;
      final startup = StartupLog()..stage = '加载用户设置';
      final failure = StateError('设置文件无法读取');
      await expectLater(
        startup.run(() async => throw failure),
        throwsA(same(failure)),
      );
      expect(lines.where((line) => line.contains('启动失败')), hasLength(1));
      expect(lines.last, contains('加载用户设置'));
      expect(lines.last, contains('设置文件无法读取'));
      expect(lines.any((line) => line.contains('启动成功')), isFalse);
      expect(FlutterError.onError, same(previousFlutter));
      expect(PlatformDispatcher.instance.onError, same(previousPlatform));
    } finally {
      restore();
    }
  });

  testWidgets('a first frame error is reported instead of startup success', (
    tester,
  ) async {
    final (lines, restore) = captureStartupOutput();
    try {
      final previousFlutter = FlutterError.onError;
      final previousPlatform = PlatformDispatcher.instance.onError;
      final failure = StateError('主窗口布局失败');
      final startup = StartupLog(waitUntilFirstFrameRasterized: () async {});
      final finished = startup.run(() async {
        startup.stage = '绘制主窗口首帧';
        runApp(Builder(builder: (_) => throw failure));
      });
      await tester.idle();
      await tester.pump();
      expect(tester.takeException(), same(failure));
      await finished;
      expect(lines.where((line) => line.contains('启动失败')), hasLength(1));
      expect(lines.last, contains('绘制主窗口首帧'));
      expect(lines.last, contains('主窗口布局失败'));
      expect(lines.any((line) => line.contains('启动成功')), isFalse);
      expect(FlutterError.onError, same(previousFlutter));
      expect(PlatformDispatcher.instance.onError, same(previousPlatform));
    } finally {
      restore();
    }
  });
}
