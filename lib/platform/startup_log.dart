import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Startup results for the development terminal, through Flutter's stdout.
class StartupLog {
  StartupLog({Future<void> Function()? waitUntilFirstFrameRasterized})
    : _waitUntilFirstFrameRasterized =
          waitUntilFirstFrameRasterized ?? _waitForNativeFrame;

  final Future<void> Function() _waitUntilFirstFrameRasterized;
  String stage = '初始化应用';
  final _elapsed = Stopwatch();
  bool _failed = false;

  Future<void> run(Future<void> Function() initialize) async {
    if (!kDebugMode) {
      await initialize();
      return;
    }

    _elapsed.start();
    _write('开始启动');
    final previousFlutterError = FlutterError.onError;
    final dispatcher = PlatformDispatcher.instance;
    final previousPlatformError = dispatcher.onError;
    void reportFlutterError(FlutterErrorDetails details) {
      _failure(details.exception);
      previousFlutterError?.call(details);
    }

    bool reportPlatformError(Object error, StackTrace stack) {
      _failure(error);
      return previousPlatformError?.call(error, stack) ?? false;
    }

    FlutterError.onError = reportFlutterError;
    dispatcher.onError = reportPlatformError;
    try {
      await initialize();
      stage = '绘制主窗口首帧';
      await WidgetsBinding.instance.endOfFrame;
      await _waitUntilFirstFrameRasterized();
      if (!_failed) {
        _write('启动成功（主窗口首帧已绘制，耗时 ${_elapsed.elapsedMilliseconds} ms）');
      }
    } catch (error) {
      _failure(error);
      rethrow;
    } finally {
      _elapsed.stop();
      if (identical(FlutterError.onError, reportFlutterError)) {
        FlutterError.onError = previousFlutterError;
      }
      if (identical(dispatcher.onError, reportPlatformError)) {
        dispatcher.onError = previousPlatformError;
      }
    }
  }

  void _failure(Object error) {
    if (_failed) return;
    _failed = true;
    _write('启动失败（阶段：$stage，耗时 ${_elapsed.elapsedMilliseconds} ms）：$error');
  }

  void _write(String message) => debugPrint(
    '[${DateTime.now().toUtc().toIso8601String()}] [Caocode][启动] $message',
  );

  static Future<void> _waitForNativeFrame() =>
      WidgetsBinding.instance.waitUntilFirstFrameRasterized;
}
