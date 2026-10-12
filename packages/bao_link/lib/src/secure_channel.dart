import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:pinenacl/digests.dart';
import 'package:pinenacl/tweetnacl.dart';

import 'identity.dart';
import 'socket.dart';

/// The handshake failed: the other end is not who it should be, or spoke
/// something else.
class LinkHandshakeException implements Exception {
  const LinkHandshakeException(this.message);

  final String message;

  @override
  String toString() => 'LinkHandshakeException: $message';
}

/// A [LinkSocket] sealed end to end: what goes over it is read only by the
/// two ends, whatever carries it (a LAN, the internet, a relay).
///
/// The handshake is Noise IK's, in short. The phone (who connects) knows
/// the desktop's lasting key, from its QR code or since pairing; each end
/// brings a key of the moment too:
///
/// 1. phone → desktop: its key of the moment, and its lasting key sealed
///    with DH(its key of the moment, the desktop's lasting key);
/// 2. desktop → phone: its key of the moment.
///
/// Both then derive the keys of the two directions from DH(moment, moment),
/// DH(desktop lasting, phone moment) and DH(desktop moment, phone lasting),
/// and the two messages: only the desktop whose key the phone knows, and
/// the phone whose key it sent, get them. A key of the moment is forgotten
/// with the connection, so what was said cannot be read later, the lasting
/// keys stolen.
///
/// Each message after is sealed with XSalsa20-Poly1305, its nonce counted
/// up, each direction under its own key.
class SecureChannel {
  SecureChannel._(
    this._socket,
    this.peerKey,
    Uint8List sendKey,
    Uint8List receiveKey,
  ) : _sendKey = sendKey,
      _receiveKey = receiveKey;

  static const _version = 1;
  static const _label = 'baocode-link-v1';

  /// How long the other end has to answer the handshake.
  static const handshakeTimeout = Duration(seconds: 10);

  final LinkSocket _socket;

  /// The other end's lasting key.
  final Uint8List peerKey;

  final Uint8List _sendKey;
  final Uint8List _receiveKey;
  int _sent = 0;
  int _received = 0;

  final _messages = StreamController<Uint8List>();
  final _done = Completer<void>();

  /// The phone's end: connects as [identity] to the desktop of [serverKey].
  static Future<SecureChannel> connect(
    LinkSocket socket, {
    required LinkIdentity identity,
    required Uint8List serverKey,
    Duration timeout = handshakeTimeout,
  }) async {
    final incoming = StreamIterator(socket.messages);
    try {
      final moment = LinkIdentity.generate();
      final helloKey = _hash([
        utf8.encode('$_label hello'),
        dh(moment.privateKey, serverKey),
      ]);
      final hello = Uint8List.fromList([
        _version,
        ...moment.publicKey,
        ..._seal(helloKey, 0, identity.publicKey),
      ]);
      socket.send(hello);
      if (!await incoming.moveNext().timeout(timeout)) {
        throw const LinkHandshakeException('Closed during the handshake');
      }
      final reply = incoming.current;
      if (reply.length != 33 || reply[0] != _version) {
        throw const LinkHandshakeException('Not a BaoCode desktop');
      }
      final serverMoment = Uint8List.sublistView(reply, 1);
      final keys = _keys(
        dh(moment.privateKey, serverMoment),
        dh(moment.privateKey, serverKey),
        dh(identity.privateKey, serverMoment),
        hello,
        reply,
      );
      return SecureChannel._(
        socket,
        Uint8List.fromList(serverKey),
        keys.toServer,
        keys.toClient,
      ).._listen(incoming);
    } on TimeoutException {
      await incoming.cancel();
      await socket.close();
      throw const LinkHandshakeException('No answer to the handshake');
    } on FormatException catch (error) {
      await incoming.cancel();
      await socket.close();
      throw LinkHandshakeException(error.message);
    } catch (_) {
      await incoming.cancel();
      await socket.close();
      rethrow;
    }
  }

  /// The desktop's end: takes a phone's handshake as [identity]. Whether
  /// the phone is one it knows is for the caller to decide, by [peerKey].
  static Future<SecureChannel> accept(
    LinkSocket socket, {
    required LinkIdentity identity,
    Duration timeout = handshakeTimeout,
  }) async {
    final incoming = StreamIterator(socket.messages);
    try {
      if (!await incoming.moveNext().timeout(timeout)) {
        throw const LinkHandshakeException('Closed during the handshake');
      }
      final hello = incoming.current;
      if (hello.length != 1 + 32 + 32 + 16 || hello[0] != _version) {
        throw const LinkHandshakeException('Not a BaoCode phone');
      }
      final clientMoment = Uint8List.sublistView(hello, 1, 33);
      final helloKey = _hash([
        utf8.encode('$_label hello'),
        dh(identity.privateKey, clientMoment),
      ]);
      final Uint8List clientKey;
      try {
        clientKey = _open(helloKey, 0, Uint8List.sublistView(hello, 33));
      } on Object {
        throw const LinkHandshakeException('Sealed for another desktop');
      }
      final moment = LinkIdentity.generate();
      final reply = Uint8List.fromList([_version, ...moment.publicKey]);
      final keys = _keys(
        dh(moment.privateKey, clientMoment),
        dh(identity.privateKey, clientMoment),
        dh(moment.privateKey, clientKey),
        hello,
        reply,
      );
      socket.send(reply);
      return SecureChannel._(socket, clientKey, keys.toClient, keys.toServer)
        .._listen(incoming);
    } on TimeoutException {
      await incoming.cancel();
      await socket.close();
      throw const LinkHandshakeException('No handshake');
    } on FormatException catch (error) {
      await incoming.cancel();
      await socket.close();
      throw LinkHandshakeException(error.message);
    } catch (_) {
      await incoming.cancel();
      await socket.close();
      rethrow;
    }
  }

  static ({Uint8List toServer, Uint8List toClient}) _keys(
    Uint8List momentMoment,
    Uint8List serverClientMoment,
    Uint8List serverMomentClient,
    Uint8List hello,
    Uint8List reply,
  ) {
    final transcript = Hash.sha256(Uint8List.fromList([...hello, ...reply]));
    final keys = Hash.sha512(
      Uint8List.fromList([
        ...utf8.encode(_label),
        ...momentMoment,
        ...serverClientMoment,
        ...serverMomentClient,
        ...transcript,
      ]),
    );
    return (
      toServer: Uint8List.sublistView(keys, 0, 32),
      toClient: Uint8List.sublistView(keys, 32, 64),
    );
  }

  static Uint8List _hash(List<List<int>> parts) =>
      Hash.sha256(Uint8List.fromList([for (final part in parts) ...part]));

  static Uint8List _nonce(int counter) {
    final nonce = Uint8List(24);
    ByteData.sublistView(nonce).setUint64(16, counter);
    return nonce;
  }

  /// XSalsa20-Poly1305 of [plain]: its tag, then the text.
  static Uint8List _seal(Uint8List key, int counter, Uint8List plain) {
    final m = Uint8List(32 + plain.length)
      ..setRange(32, 32 + plain.length, plain);
    final c = Uint8List(m.length);
    return TweetNaCl.crypto_secretbox(c, m, m.length, _nonce(counter), key);
  }

  static Uint8List _open(Uint8List key, int counter, Uint8List sealed) {
    if (sealed.length < 16) throw const FormatException('Too short');
    final c = Uint8List(16 + sealed.length)
      ..setRange(16, 16 + sealed.length, sealed);
    final m = Uint8List(c.length);
    return TweetNaCl.crypto_secretbox_open(
      m,
      c,
      c.length,
      _nonce(counter),
      key,
    );
  }

  void _listen(StreamIterator<Uint8List> incoming) {
    // Messages from here are sealed; the iterator has given what it read.
    Future<void> pump() async {
      try {
        while (await incoming.moveNext()) {
          final Uint8List plain;
          try {
            plain = _open(_receiveKey, _received++, incoming.current);
          } on Object {
            throw const LinkHandshakeException('A message did not open');
          }
          _messages.add(plain);
        }
      } catch (error, stack) {
        if (!_messages.isClosed) _messages.addError(error, stack);
      } finally {
        await _finish();
      }
    }

    unawaited(pump());
  }

  bool _closed = false;

  Future<void> _finish() async {
    if (_closed) return;
    _closed = true;
    await _socket.close();
    // Not waited on: it completes only once listened to.
    if (!_messages.isClosed) unawaited(_messages.close());
    if (!_done.isCompleted) _done.complete();
  }

  /// What comes in, opened; done when the connection ends.
  Stream<Uint8List> get messages => _messages.stream;

  /// Completes once the connection has ended, either end having closed it.
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  void send(Uint8List message) {
    if (_closed) return;
    _socket.send(_seal(_sendKey, _sent++, message));
  }

  Future<void> close() => _finish();
}
