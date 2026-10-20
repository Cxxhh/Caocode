import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/channel/account/account_api.dart';
import 'package:caocode/channel/account/account_send_io.dart';

void main() {
  late HttpServer server;
  late Uri base;

  // Real requests, to a server of the test's own.
  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) {
      final response = request.response..statusCode = HttpStatus.forbidden;
      if (request.uri.path == '/firewall') {
        // As Cloudflare's "Sorry, you have been blocked".
        response.headers.contentType = ContentType.html;
        response.write('<title>Attention Required! | Cloudflare</title>');
      } else {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'code': 403, 'message': 'token revoked'}));
      }
      response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('a firewall\'s page in place of the site is not a sign-out', () async {
    await expectLater(
      sendToAccountSite('POST', base.replace(path: '/firewall')),
      throwsA(isA<AccountBlocked>().having((e) => e.host, 'host', '127.0.0.1')),
    );
  });

  test('the site\'s own 403 comes back, for the adapter to read', () async {
    final response = await sendToAccountSite(
      'POST',
      base.replace(path: '/api/v1/auth/refresh'),
    );
    expect(response.status, 403);
    expect(response.json, {'code': 403, 'message': 'token revoked'});
  });
}
