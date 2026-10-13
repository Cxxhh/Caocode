// The upstreams Settings → Models lists, got from caocode.dev: kept with
// their logos, and what was kept when it does not answer.

import 'dart:convert';
import 'dart:io';

import 'package:caocode/models/featured_upstreams_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The test binding's clients answer 400 to all: a real one, for the
/// server here.
class _RealHttp extends HttpOverrides {}

void main() {
  late Directory cache;
  late HttpServer server;
  late Uri feed;
  var list = '';

  setUp(() async {
    HttpOverrides.global = _RealHttp();
    cache = await Directory.systemTemp.createTemp('featured');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    feed = Uri.parse('http://127.0.0.1:${server.port}/featured/upstreams.json');
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/featured/upstreams.json':
          response.write(list);
        case '/featured/a.png':
          response.add([1, 2, 3]);
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
  });

  tearDown(() async {
    HttpOverrides.global = null;
    await server.close(force: true);
    await cache.delete(recursive: true);
  });

  test('a site listed shows at once, its logo downloaded beside the list; '
      'kept for when caocode.dev does not answer', () async {
    list = jsonEncode({
      'upstreams': [
        {'id': 'a', 'name': 'A', 'url': 'https://a.dev', 'logo': 'a.png'},
        {'id': 'b', 'name': 'B', 'url': 'https://b.dev', 'logo': 'b.png'},
      ],
    });
    final got = await fetchFeaturedUpstreams(feed: feed, cacheDir: cache.path);
    expect(got.map((u) => u.id), ['a', 'b']);
    expect(File(p.join(cache.path, 'a.png')).readAsBytesSync(), [1, 2, 3]);
    // One that could not be downloaded: the card shows a letter.
    expect(File(p.join(cache.path, 'b.png')).existsSync(), isFalse);

    await server.close(force: true);
    final kept = await fetchFeaturedUpstreams(feed: feed, cacheDir: cache.path);
    expect(kept.map((u) => u.id), ['a', 'b']);
    expect(kept.first.logo, p.join(cache.path, 'a.png').replaceAll(r'\', '/'));
  });

  test('none before the first answer', () async {
    await server.close(force: true);
    expect(
      await fetchFeaturedUpstreams(feed: feed, cacheDir: cache.path),
      isEmpty,
    );
  });
}
