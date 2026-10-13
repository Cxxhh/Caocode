import 'dart:async';

import 'codex_transport.dart';

class CodexRpcException implements Exception {
  const CodexRpcException(this.message, {this.code});
  final String message;
  final int? code;

  @override
  String toString() => message;
}

/// Match RPC replies while keeping notifications and server requests ordered.
class CodexRpcClient {
  CodexRpcClient(this.transport) {
    _subscription = transport.messages.listen(
      _receive,
      onError: _failed,
      onDone: () => _failed(const CodexRpcException('Codex CLI 连接已关闭')),
    );
  }

  final CodexTransport transport;
  late final StreamSubscription<Map<String, Object?>> _subscription;
  final _messages = StreamController<Map<String, Object?>>.broadcast(
    sync: true,
  );
  final Map<Object, Completer<Map<String, Object?>>> _pending = {};
  int _nextId = 0;
  bool _closed = false;
  Object? _failure;
  Future<void>? _initializing;

  Stream<Map<String, Object?>> get messages => _messages.stream;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    await request('initialize', {
      'clientInfo': {'name': 'caocode', 'title': 'Caocode', 'version': '0.1.0'},
      // Required by thread/settings/update on current CLI versions.
      'capabilities': {'experimentalApi': true},
    });
    transport.write({'method': 'initialized'});
  }

  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_closed || _failure != null) {
      throw _failure ?? const CodexRpcException('Codex CLI 连接已关闭');
    }
    final id = ++_nextId;
    final response = Completer<Map<String, Object?>>();
    _pending[id] = response;
    try {
      transport.write({'id': id, 'method': method, 'params': params});
      return await response.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  void _receive(Map<String, Object?> message) {
    if (message['method'] != null) {
      _messages.add(message);
      return;
    }
    final response = _pending.remove(message['id']);
    if (response == null) return;
    if (message['error'] case final Map error) {
      response.completeError(
        CodexRpcException(
          error['message'] as String? ?? 'Codex CLI 请求失败',
          code: error['code'] as int?,
        ),
      );
    } else {
      response.complete(
        (message['result'] as Map?)?.cast<String, Object?>() ?? {},
      );
    }
  }

  void _failed(Object error, [StackTrace? stack]) {
    if (_closed || _failure != null) return;
    _failure = error;
    for (final pending in _pending.values) {
      pending.completeError(error, stack);
    }
    _pending.clear();
    _messages.addError(error, stack);
  }

  Future<void> get stopped => switch (transport) {
    final CodexTransportLifecycle lifecycle => lifecycle.stopped,
    _ => Future.value(),
  };

  void close() {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.completeError(const CodexRpcException('Codex CLI 连接已关闭'));
    }
    _pending.clear();
    unawaited(_subscription.cancel());
    transport.close();
    unawaited(_messages.close());
  }
}
