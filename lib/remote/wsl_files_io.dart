import 'dart:async';

import 'package:bao_remote/client.dart';

import 'remote_binaries.dart';

/// One persistent stdio server per distribution, shared by the IDE's file
/// tree, editors, search and previews. No process is started per file.
class WslFileHosts {
  static final _connections = <String, Future<WslConnection>>{};

  static Future<WslConnection> _connection(String distribution) =>
      _connections.putIfAbsent(distribution.toLowerCase(), () async {
        final binaries = bundledServerBinaries();
        if (binaries == null) {
          throw StateError('应用缺少 WSL 文件服务，请使用 build.sh 或 dev.sh 重新构建。');
        }
        return WslConnection.start(distribution, binaries);
      });

  static Future<T> run<T>(
    String distribution,
    Future<T> Function(RemoteClient client) operation,
  ) async {
    final key = distribution.toLowerCase();
    final pending = _connection(distribution);
    WslConnection? connection;
    try {
      connection = await pending;
      if (connection.client.peer.isClosed) throw const RpcClosed();
      return await operation(connection.client)
          .timeout(const Duration(seconds: 15));
    } catch (error) {
      if (connection == null ||
          error is RpcClosed ||
          error is TimeoutException) {
        if (identical(_connections[key], pending)) _connections.remove(key);
        connection?.abort();
      }
      // Writes are never replayed automatically. A fresh read is required
      // after reconnection, so the server still protects external changes.
      rethrow;
    }
  }

  static Future<void> closeAll() async {
    final pending = _connections.values.toList();
    _connections.clear();
    await Future.wait([
      for (final connection in pending)
        connection.then((value) => value.close()).catchError((Object _) {}),
    ]);
  }
}
