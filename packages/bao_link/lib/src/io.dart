import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'pairing.dart';
import 'socket.dart';

/// A WebSocket, as a [LinkSocket]: binary messages only.
class WebSocketLinkSocket implements LinkSocket {
  WebSocketLinkSocket(this._socket) {
    _socket.pingInterval = const Duration(seconds: 15);
  }

  final WebSocket _socket;

  @override
  late final Stream<Uint8List> messages = _socket
      .where((message) => message is List<int>)
      .map(
        (message) => message is Uint8List
            ? message
            : Uint8List.fromList(message as List<int>),
      );

  @override
  void send(Uint8List message) {
    if (_socket.readyState == WebSocket.open) _socket.add(message);
  }

  @override
  Future<void> close() => _socket.close().catchError((Object _) => null);
}

/// The path a desktop takes phones' WebSockets at.
const linkPath = '/baocode-link';

/// A desktop's listening end: takes phones' WebSockets on [port], on all of
/// its addresses (IPv4 and IPv6).
class LinkServer {
  LinkServer._(this._server);

  /// Listens on [port]; 0 for any free one.
  static Future<LinkServer> bind(int port) async {
    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.anyIPv6,
        port,
        v6Only: false,
      );
    } on SocketException {
      // No IPv6 here.
      server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    }
    return LinkServer._(server);
  }

  final HttpServer _server;

  int get port => _server.port;

  /// Each phone's socket, as it connects.
  Stream<LinkSocket> get sockets async* {
    await for (final request in _server) {
      if (request.uri.path != linkPath ||
          !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('BaoCode');
        unawaited(request.response.close());
        continue;
      }
      try {
        final socket = await WebSocketTransformer.upgrade(request);
        yield WebSocketLinkSocket(socket);
      } on Object {
        // Gone before it was upgraded.
      }
    }
  }

  Future<void> close() => _server.close(force: true);
}

/// The desktop could only be reached through a relay, and there is none
/// yet (see [RelayEndpoint]).
class LinkRelayUnavailableException implements Exception {
  const LinkRelayUnavailableException();

  @override
  String toString() => 'LinkRelayUnavailableException';
}

/// None of the desktop's addresses answered.
class LinkUnreachableException implements Exception {
  const LinkUnreachableException(this.tried);

  final List<LinkEndpoint> tried;

  @override
  String toString() => 'LinkUnreachableException(${tried.join(', ')})';
}

/// Reaches a desktop: all its addresses at once, the first to answer kept;
/// through its relay, when none does (not yet: see [RelayEndpoint]).
abstract final class LinkConnector {
  static Future<(LinkSocket, LinkEndpoint)> connect(
    List<DirectEndpoint> endpoints, {
    RelayEndpoint? relay,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (endpoints.isNotEmpty) {
      final won = await _race(endpoints, timeout);
      if (won != null) return won;
    }
    if (relay != null) throw const LinkRelayUnavailableException();
    throw LinkUnreachableException(endpoints);
  }

  static Future<(LinkSocket, LinkEndpoint)?> _race(
    List<DirectEndpoint> endpoints,
    Duration timeout,
  ) {
    final result = Completer<(LinkSocket, LinkEndpoint)?>();
    var left = endpoints.length;
    for (final endpoint in endpoints) {
      final host = endpoint.isIPv6 ? '[${endpoint.host}]' : endpoint.host;
      WebSocket.connect('ws://$host:${endpoint.port}$linkPath')
          .timeout(timeout)
          .then(
            (socket) {
              if (result.isCompleted) {
                unawaited(socket.close());
              } else {
                result.complete((WebSocketLinkSocket(socket), endpoint));
              }
            },
            onError: (Object _) {
              if (--left == 0 && !result.isCompleted) result.complete(null);
            },
          );
    }
    return result.future;
  }
}

/// This machine's addresses others may reach it at, on [port]: those on
/// the LAN (private IPv4, IPv6 of the site), then public IPv6 ones (often
/// reachable from the internet as they are). Not loopback, nor link-local.
Future<List<DirectEndpoint>> localEndpoints(int port) async {
  final List<NetworkInterface> interfaces;
  try {
    interfaces = await NetworkInterface.list(
      includeLinkLocal: false,
      type: InternetAddressType.any,
    );
  } on Object {
    return const [];
  }
  final v4 = <DirectEndpoint>[];
  final v6 = <DirectEndpoint>[];
  for (final interface in interfaces) {
    // Virtual machines' and VPNs' bridges, as macOS and Docker name them.
    final name = interface.name.toLowerCase();
    if (name.startsWith('utun') ||
        name.startsWith('docker') ||
        name.startsWith('veth') ||
        name.startsWith('bridge') ||
        name.startsWith('vmnet') ||
        name.startsWith('llw') ||
        name.startsWith('awdl')) {
      continue;
    }
    for (final address in interface.addresses) {
      if (address.isLoopback || address.isLinkLocal) continue;
      final host = address.address.split('%').first;
      if (address.type == InternetAddressType.IPv4) {
        v4.add(DirectEndpoint(host, port));
      } else if (address.type == InternetAddressType.IPv6 &&
          !_siteLocal(host)) {
        v6.add(DirectEndpoint(host, port));
      }
    }
  }
  int rank(DirectEndpoint endpoint) => _isPrivateIPv4(endpoint.host) ? 0 : 1;
  v4.sort((a, b) => rank(a).compareTo(rank(b)));
  return [...v4, ...v6];
}

bool _isPrivateIPv4(String host) {
  final parts = [for (final part in host.split('.')) int.tryParse(part) ?? -1];
  if (parts.length != 4) return false;
  return parts[0] == 10 ||
      (parts[0] == 172 && parts[1] >= 16 && parts[1] < 32) ||
      (parts[0] == 192 && parts[1] == 168);
}

/// The deprecated site-local IPv6 addresses (fec0::/10): left out.
bool _siteLocal(String host) => host.toLowerCase().startsWith('fec');
