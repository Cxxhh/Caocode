import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'secure_channel.dart';

/// A request the other end turned down, or could not carry out.
class LinkRemoteException implements Exception {
  const LinkRemoteException(this.code, this.message);

  /// What went wrong, for code: `unknown`, `notFound`, `failed`, …
  final String code;
  final String message;

  @override
  String toString() => 'LinkRemoteException($code): $message';
}

/// The connection ended before the answer came.
class LinkClosedException implements Exception {
  const LinkClosedException();

  @override
  String toString() => 'LinkClosedException';
}

/// Something one end tells the other, unasked.
class LinkEvent {
  const LinkEvent(this.name, this.data);

  final String name;
  final Object? data;
}

/// Answers a request: what it returns (as JSON) is the result; a
/// [LinkRemoteException] thrown, the error.
typedef LinkRequestHandler = FutureOr<Object?> Function(
  String method,
  Map<String, Object?> params,
);

/// Requests, answers and events, as JSON, over a [SecureChannel]: the same
/// on both ends.
///
/// - a request: `{"id": 1, "m": "send", "p": {…}}`;
/// - its answer: `{"id": 1, "r": …}`, or `{"id": 1, "e": {"c": …, "m": …}}`;
/// - an event: `{"ev": "session", "p": …}`.
class LinkPeer {
  LinkPeer(this.channel, {LinkRequestHandler? onRequest})
    // ignore: prefer_initializing_formals
    : _onRequest = onRequest {
    channel.messages.listen(_receive, onError: (Object _) {}, onDone: _closed);
  }

  final SecureChannel channel;
  LinkRequestHandler? _onRequest;

  set onRequest(LinkRequestHandler? handler) => _onRequest = handler;

  int _nextId = 1;
  final Map<int, Completer<Object?>> _pending = {};
  final _events = StreamController<LinkEvent>.broadcast();
  final _done = Completer<void>();

  /// The other end's events.
  Stream<LinkEvent> get events => _events.stream;

  /// Completes once the connection has ended.
  Future<void> get done => _done.future;

  bool get isClosed => _done.isCompleted;

  /// Asks the other end [method]; its result.
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) {
    if (isClosed) return Future.error(const LinkClosedException());
    final id = _nextId++;
    final completer = _pending[id] = Completer<Object?>();
    _write({'id': id, 'm': method, 'p': params});
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('$method took too long', timeout);
      },
    );
  }

  /// Tells the other end [name].
  void emit(String name, [Object? data]) {
    if (!isClosed) _write({'ev': name, 'p': data});
  }

  void _write(Map<String, Object?> message) =>
      channel.send(Uint8List.fromList(utf8.encode(jsonEncode(message))));

  void _receive(Uint8List bytes) {
    final Object? message;
    try {
      message = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return;
    }
    switch (message) {
      case {'ev': final String name}:
        _events.add(LinkEvent(name, message['p']));
      case {'id': final int id, 'm': final String method}:
        unawaited(_answer(id, method, message['p']));
      case {
        'id': final int id,
        'e': {'c': final String code, 'm': final String text},
      }:
        _pending.remove(id)?.completeError(LinkRemoteException(code, text));
      case {'id': final int id}:
        _pending.remove(id)?.complete(message['r']);
    }
  }

  Future<void> _answer(int id, String method, Object? params) async {
    final handler = _onRequest;
    try {
      if (handler == null) {
        throw LinkRemoteException('unknown', 'No such request: $method');
      }
      final result = await handler(
        method,
        params is Map<String, Object?> ? params : const {},
      );
      if (!isClosed) _write({'id': id, 'r': result});
    } on LinkRemoteException catch (error) {
      if (!isClosed) {
        _write({
          'id': id,
          'e': {'c': error.code, 'm': error.message},
        });
      }
    } catch (error) {
      if (!isClosed) {
        _write({
          'id': id,
          'e': {'c': 'failed', 'm': '$error'},
        });
      }
    }
  }

  void _closed() {
    for (final completer in _pending.values) {
      completer.completeError(const LinkClosedException());
    }
    _pending.clear();
    if (!_events.isClosed) unawaited(_events.close());
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> close() async {
    await channel.close();
    _closed();
  }
}
