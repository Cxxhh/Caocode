import 'dart:async';
import 'dart:typed_data';

/// A pipe of whole messages between the two ends, in order: a WebSocket,
/// later a relay's. What goes over it is sealed already (see
/// [SecureChannel]); it only carries it.
abstract class LinkSocket {
  /// What comes in, until the socket closes (an error, if it broke).
  /// Listened to once.
  Stream<Uint8List> get messages;

  void send(Uint8List message);

  Future<void> close();
}

/// Two sockets joined to each other in memory, for tests.
class MemoryLinkSocket implements LinkSocket {
  MemoryLinkSocket._(this._in, this._out);

  static (MemoryLinkSocket, MemoryLinkSocket) pair() {
    final a = StreamController<Uint8List>();
    final b = StreamController<Uint8List>();
    return (MemoryLinkSocket._(a, b), MemoryLinkSocket._(b, a));
  }

  final StreamController<Uint8List> _in;
  final StreamController<Uint8List> _out;

  @override
  Stream<Uint8List> get messages => _in.stream;

  @override
  void send(Uint8List message) {
    if (!_out.isClosed) _out.add(Uint8List.fromList(message));
  }

  @override
  Future<void> close() async {
    if (!_out.isClosed) unawaited(_out.close());
    if (!_in.isClosed) unawaited(_in.close());
  }
}
