import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where the stash's shortcut was pressed: in Caocode itself or not, and
/// whether its panel was what the keyboard was in.
@immutable
class StashCapture {
  const StashCapture({this.inApp = false, this.panelInFront});

  /// Pressed in Caocode itself: its project, branch and conversation are
  /// kept as the new stash's source.
  final bool inApp;

  /// Whether the panel itself was what the keyboard was in (it then
  /// hides); null where the system does not say.
  final bool? panelInFront;

  static const none = StashCapture();

  static StashCapture fromJson(Object? json) {
    if (json is! Map) return none;
    return StashCapture(
      inApp: json['self'] == true,
      panelInFront: switch (json['panel']) {
        final bool panel => panel,
        _ => null,
      },
    );
  }
}

/// The system's side of the stash: its shortcut, which works from any
/// app, and the text in pictures. Nothing where there is no channel (the web, under test).
class StashHost {
  StashHost({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('caocode/stash') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pressed') {
        onPressed?.call(StashCapture.fromJson(call.arguments));
      }
      return null;
    });
  }

  static StashHost? _instance;
  static StashHost get instance => _instance ??= StashHost();

  @visibleForTesting
  static set instance(StashHost host) => _instance = host;

  final MethodChannel _channel;

  /// The shortcut was pressed.
  void Function(StashCapture capture)? onPressed;

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('stash.$method: $error');
      return null;
    }
  }

  /// Takes [spec] (`ctrl+shift+space`) as the shortcut, none for empty;
  /// whether the system gave it (another app may hold it). Null where
  /// there is no shortcut to take.
  Future<bool?> setHotkey(String spec) => _invoke<bool>('setHotkey', spec);

  /// The text in the picture at [path]; null for none, or where it cannot
  /// be read.
  Future<String?> recognizeText(String path) =>
      _invoke<String>('recognizeText', path);
}
