import 'package:bao_link/bao_link.dart';

import 'link_platform_stub.dart'
    if (dart.library.io) 'link_platform_io.dart'
    as platform;

/// A server the phones connect to, listening.
abstract interface class LinkListener {
  /// The port it listens on (the one asked for, or one picked for 0).
  int get port;

  /// Each phone's socket, as it connects.
  Stream<LinkSocket> get sockets;

  Future<void> close();
}

/// This desktop made known on the LAN, until stopped.
abstract interface class LinkAdvertising {
  Future<void> stop();
}

/// What the link needs of the machine: a server to listen with, its
/// addresses, a way to be found on the LAN, a file to keep its key and the
/// phones paired in, and what it is. None on the web.
abstract interface class LinkPlatform {
  /// This machine's; null on the web.
  static LinkPlatform? current() => platform.currentLinkPlatform();

  /// `state/mobile.json` as kept; empty the first time.
  Future<Map<String, Object?>> read();

  /// Kept readable only by the user: it holds the desktop's private key.
  Future<void> write(Map<String, Object?> json);

  Future<LinkListener> listen(int port);

  /// This machine's addresses on the LAN, and public IPv6 ones.
  Future<List<DirectEndpoint>> endpoints(int port);

  /// Makes this desktop known on the LAN as [advert] (DNS-SD, see
  /// [LinkDiscovery]); null where it cannot be.
  Future<LinkAdvertising?> advertise(LinkAdvert advert);

  /// This machine, as phones list it ([DeviceInfo.endpoints] left empty).
  Future<DeviceInfo> device();

  /// The Git branch checked out in [folder], if it is a repository.
  String? branchOf(String folder);
}
