import 'dart:convert';
import 'dart:typed_data';

import 'identity.dart';

/// Where a desktop can be reached.
sealed class LinkEndpoint {
  const LinkEndpoint();
}

/// The desktop itself, at a host and port: an address on the LAN, or one
/// on the internet (a public IPv6 address, a forwarded port, a domain).
class DirectEndpoint extends LinkEndpoint {
  const DirectEndpoint(this.host, this.port);

  /// `192.168.1.5:47100`, `[2408:8207::1]:47100`, `home.example.com:47100`.
  factory DirectEndpoint.parse(String text) {
    final value = text.trim();
    final String host;
    final String rest;
    if (value.startsWith('[')) {
      final end = value.indexOf(']');
      if (end < 0) throw FormatException('Bad address', text);
      host = value.substring(1, end);
      rest = value.substring(end + 1);
    } else {
      final colon = value.lastIndexOf(':');
      // A bare IPv6 address has colons and no port.
      if (colon < 0 || value.indexOf(':') != colon) {
        host = value;
        rest = '';
      } else {
        host = value.substring(0, colon);
        rest = value.substring(colon);
      }
    }
    if (host.isEmpty) throw FormatException('Bad address', text);
    if (rest.isEmpty) return DirectEndpoint(host, defaultLinkPort);
    if (!rest.startsWith(':')) throw FormatException('Bad address', text);
    final port = int.tryParse(rest.substring(1));
    if (port == null || port <= 0 || port > 65535) {
      throw FormatException('Bad port', text);
    }
    return DirectEndpoint(host, port);
  }

  final String host;
  final int port;

  bool get isIPv6 => host.contains(':');

  @override
  String toString() => isIPv6 ? '[$host]:$port' : '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is DirectEndpoint && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// A relay both ends reach out to, which passes along what they seal for
/// each other: for a desktop no address of which can be reached.
///
/// Reserved: no relay runs yet, and [LinkConnector] says so when a desktop
/// can only be reached through one.
class RelayEndpoint extends LinkEndpoint {
  const RelayEndpoint(this.url, this.room);

  final Uri url;

  /// Where the two ends meet on it: the desktop's id, so that it can be
  /// found again.
  final String room;

  Map<String, Object?> toJson() => {'u': '$url', 'r': room};

  static RelayEndpoint? fromJson(Object? json) => switch (json) {
    {'u': final String url, 'r': final String room} => RelayEndpoint(
      Uri.parse(url),
      room,
    ),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is RelayEndpoint && other.url == url && other.room == room;

  @override
  int get hashCode => Object.hash(url, room);
}

/// The port a desktop listens on unless set otherwise.
const defaultLinkPort = 47100;

/// What a desktop's QR code holds, for a phone to pair with it: its public
/// key, a one-time secret that only who saw the code knows, and where it can
/// be reached.
class PairingOffer {
  const PairingOffer({
    required this.name,
    required this.key,
    required this.token,
    required this.expires,
    this.endpoints = const [],
    this.relay,
  });

  /// As [uri] wrote it, or as the code's text is pasted.
  factory PairingOffer.parse(String text) {
    final Uri uri;
    try {
      uri = Uri.parse(text.trim());
    } on FormatException {
      throw FormatException('Not a pairing code', text);
    }
    final data = uri.queryParameters['d'];
    if (uri.scheme != scheme || uri.host != 'pair' || data == null) {
      throw FormatException('Not a pairing code', text);
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(decodeKey(data)));
    } on FormatException {
      throw FormatException('Not a pairing code', text);
    }
    if (json case {
      'v': final int version,
      'n': final String name,
      'k': final String key,
      't': final String token,
      'x': final int expires,
    }) {
      if (version != PairingOffer.version) {
        throw FormatException('Pairing code of another version', text);
      }
      final addresses = json['a'];
      return PairingOffer(
        name: name,
        key: decodeKey(key),
        token: decodeKey(token),
        expires: DateTime.fromMillisecondsSinceEpoch(expires * 1000),
        endpoints: [
          if (addresses is List)
            for (final address in addresses.whereType<String>())
              DirectEndpoint.parse(address),
        ],
        relay: RelayEndpoint.fromJson(json['r']),
      );
    }
    throw FormatException('Not a pairing code', text);
  }

  static const scheme = 'baocode';
  static const version = 1;

  /// The desktop's name, shown while pairing.
  final String name;

  /// The desktop's public key.
  final Uint8List key;

  /// The one-time secret the phone proves it saw the code with.
  final Uint8List token;

  /// When [token] stops being taken.
  final DateTime expires;

  /// Its addresses: on the LAN first, then on the internet.
  final List<DirectEndpoint> endpoints;

  /// Reserved (see [RelayEndpoint]).
  final RelayEndpoint? relay;

  bool expiredAt(DateTime now) => !now.isBefore(expires);

  /// `baocode://pair?d=…`: what the QR code holds.
  String get uri {
    final json = {
      'v': version,
      'n': name,
      'k': encodeKey(key),
      't': encodeKey(token),
      'x': expires.millisecondsSinceEpoch ~/ 1000,
      'a': [for (final endpoint in endpoints) '$endpoint'],
      if (relay case final relay?) 'r': relay.toJson(),
    };
    return '$scheme://pair?d=${encodeKey(utf8.encode(jsonEncode(json)))}';
  }
}
