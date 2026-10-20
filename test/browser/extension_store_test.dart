import 'dart:convert';
import 'dart:io';

import 'package:caocode/browser/extension_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory cache;
  late HttpServer site;
  late Object? answer;

  setUp(() async {
    // flutter test answers every request 400; the site here is real.
    HttpOverrides.global = null;
    cache = await Directory.systemTemp.createTemp('extension_store');
    answer = null;
    site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    site.listen((request) {
      final response = request.response;
      if (answer == null) {
        response.statusCode = HttpStatus.notFound;
      } else {
        response.write(jsonEncode(answer));
      }
      response.close();
    });
    ExtensionStore.reset();
  });

  tearDown(() async {
    ExtensionStore.reset();
    await site.close(force: true);
    await cache.delete(recursive: true);
  });

  Future<Uri> fetch() {
    ExtensionStore.reset();
    return ExtensionStore.fetch(
      from: Uri.http('127.0.0.1:${site.port}', '/latest.json'),
      cacheDir: cache.path,
    );
  }

  test("the store's page is the site's, kept for when it does not answer, "
      'and by the id before it ever did', () async {
    expect(await fetch(), ExtensionStore.fallback);
    expect(
      '${ExtensionStore.fallback}',
      'https://chromewebstore.google.com/detail/'
          'jfjagocghaaheooicmdnhcholmgdkngk',
    );

    const listed =
        'https://chromewebstore.google.com/detail/caocode/'
        'jfjagocghaaheooicmdnhcholmgdkngk';
    answer = {'version': '0.1.0', 'store': listed};
    expect('${await fetch()}', listed);
    expect('${ExtensionStore.page}', listed);

    // The site down: the page kept.
    answer = null;
    expect('${await fetch()}', listed);

    // Not the store's: not taken.
    answer = {'store': 'https://example.com/extension'};
    expect('${await fetch()}', listed);
    answer = {'store': null};
    expect('${await fetch()}', listed);
  });
}
