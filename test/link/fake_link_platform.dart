import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/link_platform.dart';

/// The machine, in memory: phones' sockets are put in [incoming]; what it
/// advertises is in [advertised].
class FakeLinkPlatform implements LinkPlatform {
  Map<String, Object?> kept = {};
  final incoming = StreamController<LinkSocket>.broadcast();

  /// Advertised now, the latest last.
  final List<LinkAdvert> advertised = [];

  @override
  Future<Map<String, Object?>> read() async => kept;

  @override
  Future<void> write(Map<String, Object?> json) async => kept = json;

  @override
  Future<LinkListener> listen(int port) async => _Listener(port, incoming);

  @override
  Future<List<DirectEndpoint>> endpoints(int port) async => [
    DirectEndpoint('192.168.1.5', port),
  ];

  @override
  Future<LinkAdvertising?> advertise(LinkAdvert advert) async {
    advertised.add(advert);
    return _Advertising(() => advertised.remove(advert));
  }

  @override
  Future<DeviceInfo> device() async =>
      const DeviceInfo(name: 'Test Mac', kind: 'mac', system: 'macOS 26.1');

  @override
  String? branchOf(String folder) => 'main';
}

class _Advertising implements LinkAdvertising {
  _Advertising(this._stop);

  final void Function() _stop;

  @override
  Future<void> stop() async => _stop();
}

class _Listener implements LinkListener {
  _Listener(this.port, this._incoming);

  @override
  final int port;
  final StreamController<LinkSocket> _incoming;

  @override
  Stream<LinkSocket> get sockets => _incoming.stream;

  @override
  Future<void> close() async {}
}
