import 'dart:convert';
import 'dart:io';

import '../../network/network_proxy_io.dart';
import '../../update/version.dart';
import 'account_api.dart';

const _timeout = Duration(seconds: 15);

/// [AccountSend] over dart:io, through the proxy the app is set to.
Future<AccountResponse> sendToAccountSite(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  Object? json,
}) async {
  final route = await NetworkProxy.instance.resolve();
  final client = HttpClient()
    ..connectionTimeout = _timeout
    ..findProxy = route.findProxy
    ..userAgent = 'Caocode/$currentAppVersion (${Platform.operatingSystem})';
  try {
    final request = await client.openUrl(method, url).timeout(_timeout);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    headers.forEach(request.headers.set);
    if (json != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(json)));
    }
    final response = await request.close().timeout(_timeout);
    final body = await utf8.decodeStream(response).timeout(_timeout);
    Object? decoded;
    try {
      decoded = body.trim().isEmpty ? null : jsonDecode(body);
    } on FormatException {
      decoded = null;
    }
    // A page, not the site's JSON: its firewall's (Cloudflare's "you have
    // been blocked"), which would otherwise read as signed out.
    if (response.statusCode == HttpStatus.forbidden && decoded is! Map) {
      throw AccountBlocked(method, url);
    }
    var cookies = const <String, String>{};
    try {
      cookies = {
        for (final cookie in response.cookies) cookie.name: cookie.value,
      };
    } on Object {
      // One it could not read: as if none were set.
    }
    return AccountResponse(response.statusCode, decoded, cookies: cookies);
  } finally {
    client.close(force: true);
  }
}
