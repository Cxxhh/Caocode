import 'dart:async';

import '../util/cancel.dart';
import '../util/json.dart';

/// An error a JSON-RPC peer answered with, or one in reaching it.
class JsonRpcError implements Exception {
  const JsonRpcError(this.message, {this.code, this.data});

  final String message;
  final int? code;
  final Object? data;

  /// The server wants the user signed in.
  bool get unauthorized => code == 401;

  @override
  String toString() => code == null ? message : '$message (code $code)';
}

/// Answers a request the other side sends: its result, or a
/// [JsonRpcError].
typedef JsonRpcHandler = Future<Object?> Function(
  String method,
  Map<String, Object?> params,
);

/// JSON-RPC 2.0 over whatever carries its messages: requests matched to
/// their responses, notifications passed on, requests from the other side
/// answered by [onRequest].
class JsonRpcPeer {
  JsonRpcPeer(this._send, {this.onRequest, this.onNotification});

  final Future<void> Function(Map<String, Object?> message) _send;
  JsonRpcHandler? onRequest;
  void Function(String method, Map<String, Object?> params)? onNotification;

  int _nextId = 1;
  final Map<Object, Completer<Map<String, Object?>>> _pending = {};
  bool _closed = false;
  Object? _closedWith;

  bool get closed => _closed;

  /// Sends [method] and waits for its result.
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?>? params,
    Duration? timeout,
    CancelToken? cancel,
  ]) async {
    if (_closed) {
      throw JsonRpcError(
        'Connection closed${_closedWith == null ? '' : ': $_closedWith'}',
      );
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    try {
      await _send({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': ?params,
      });
    } on Object {
      _pending.remove(id);
      rethrow;
    }
    var future = completer.future;
    if (timeout != null) {
      future = future.timeout(
        timeout,
        onTimeout: () {
          _pending.remove(id);
          // Told the server, so it can stop.
          unawaited(
            notify('notifications/cancelled', {
              'requestId': id,
              'reason': 'timeout',
            }).catchError((_) {}),
          );
          throw JsonRpcError(
            'Request $method timed out after ${timeout.inSeconds}s',
          );
        },
      );
    }
    if (cancel != null) {
      unawaited(
        cancel.whenCancelled.then((_) {
          if (_pending.remove(id) case final pending?) {
            unawaited(
              notify('notifications/cancelled', {
                'requestId': id,
                'reason': cancel.reason,
              }).catchError((_) {}),
            );
            if (!pending.isCompleted) {
              pending.completeError(Cancelled(cancel.reason));
            }
          }
        }),
      );
    }
    return future;
  }

  Future<void> notify(String method, [Map<String, Object?>? params]) {
    if (_closed) return Future.value();
    return _send({'jsonrpc': '2.0', 'method': method, 'params': ?params});
  }

  /// Takes a message from the other side.
  void receive(Map<String, Object?> message) {
    final id = message['id'];
    final method = message['method'];
    if (method is String) {
      final params = asMap(message['params']);
      if (id == null) {
        onNotification?.call(method, params);
      } else {
        unawaited(_answer(id, method, params));
      }
      return;
    }
    if (id == null) return;
    final key = id is num ? id.toInt() : id;
    final pending = _pending.remove(key);
    if (pending == null || pending.isCompleted) return;
    if (message['error'] case final Map<Object?, Object?> error) {
      pending.completeError(
        JsonRpcError(
          '${error['message'] ?? 'Error'}',
          code: asInt(error['code']),
          data: error['data'],
        ),
      );
    } else {
      pending.complete(asMap(message['result']));
    }
  }

  Future<void> _answer(
    Object id,
    String method,
    Map<String, Object?> params,
  ) async {
    try {
      final handler = onRequest;
      if (handler == null) {
        throw JsonRpcError('Method not found: $method', code: -32601);
      }
      final result = await handler(method, params);
      await _send({'jsonrpc': '2.0', 'id': id, 'result': result ?? {}});
    } on JsonRpcError catch (error) {
      await _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': error.code ?? -32603, 'message': error.message},
      }).catchError((_) {});
    } on Object catch (error) {
      await _send({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32603, 'message': '$error'},
      }).catchError((_) {});
    }
  }

  /// Fails what is waiting: the connection is gone.
  void close([Object? reason]) {
    if (_closed) return;
    _closed = true;
    _closedWith = reason;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          JsonRpcError('Connection closed${reason == null ? '' : ': $reason'}'),
        );
      }
    }
    _pending.clear();
  }
}
