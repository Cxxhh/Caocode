import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// A window of its own, with the system's web view (WKWebView, WebView2,
/// WebKitGTK), where the user signs in to their account site as in a
/// browser: its own cookies and storage, gone when it closes.
abstract interface class LoginWindow {
  /// Opens [url] in it, titled [title]; one at a time.
  Future<void> open(Uri url, {required String title});

  /// What [expression] (JavaScript, synchronous) comes to on the page, as
  /// JSON gives it back; null when the page could not say.
  Future<Object?> evaluate(String expression);

  /// The cookies it has for [url], those scripts cannot read too.
  Future<Map<String, String>> cookies(Uri url);

  /// Closes it.
  Future<void> close();

  /// Once it is closed, by the user or [close].
  Future<void> get closed;
}

/// The runner's (macOS: LoginWindow.swift; Windows: login_window.cpp;
/// Linux: login_window.cc), over `caocode/login_window`.
class ChannelLoginWindow implements LoginWindow {
  ChannelLoginWindow({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('caocode/login_window') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'closed' && !_closed.isCompleted) _closed.complete();
    });
  }

  final MethodChannel _channel;
  final _closed = Completer<void>();

  @override
  Future<void> get closed => _closed.future;

  @override
  Future<void> open(Uri url, {required String title}) =>
      _channel.invokeMethod('open', {'url': '$url', 'title': title});

  @override
  Future<Object?> evaluate(String expression) async {
    // Its value as JSON, whatever the web view makes of a script's value.
    final result = await _channel.invokeMethod<String>('evaluate', {
      'script':
          'JSON.stringify((() => { try { return ($expression); } '
          'catch (e) { return null; } })())',
    });
    if (result == null || result.isEmpty) return null;
    try {
      return jsonDecode(result);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<Map<String, String>> cookies(Uri url) async {
    final cookies = await _channel.invokeMapMethod<String, String>('cookies', {
      'url': '$url',
    });
    return cookies ?? const {};
  }

  @override
  Future<void> close() async {
    await _channel.invokeMethod<void>('close');
    if (!_closed.isCompleted) _closed.complete();
  }
}
