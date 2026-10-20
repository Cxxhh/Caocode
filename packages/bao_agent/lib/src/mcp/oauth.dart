import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../util/json.dart';

/// Signs in to MCP servers that ask for it (OAuth 2.1 with PKCE, the client
/// registered on the fly), and keeps their tokens.
class McpOAuth {
  McpOAuth({required this.storeFile, this.environment = const {}});

  /// Where tokens are kept, readable by the user alone.
  final String storeFile;
  final Map<String, String> environment;

  Map<String, Object?>? _store;

  Map<String, Object?> get _tokens {
    if (_store case final store?) return store;
    try {
      final file = File(storeFile);
      if (file.existsSync()) {
        return _store = {...asMap(jsonDecode(file.readAsStringSync()))};
      }
    } on Object {
      // Begun afresh.
    }
    return _store = {};
  }

  void _save() {
    final file = File(storeFile);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_tokens));
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['600', storeFile]);
      } on Object {
        // Left as made.
      }
    }
  }

  static String keyOf(String name, Uri url) => '$name|$url';

  bool hasToken(String key) => asMap(_tokens[key])['access_token'] is String;

  /// Forgets [key]'s tokens.
  void forget(String key) {
    _tokens.remove(key);
    _save();
  }

  /// The headers a request to the server [key] signs in with: its token,
  /// refreshed if it has expired.
  Future<Map<String, String>> headers(String key) async {
    var entry = asMap(_tokens[key]);
    final token = asString(entry['access_token']);
    if (token == null) return const {};
    final expires = asInt(entry['expires_at']);
    if (expires != null &&
        DateTime.now().millisecondsSinceEpoch > expires - 60000 &&
        entry['refresh_token'] is String) {
      try {
        entry = await _refresh(key, entry);
      } on Object {
        // Used as it is; the server says if it is no good.
      }
    }
    return {'Authorization': 'Bearer ${entry['access_token']}'};
  }

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..findProxy = (url) =>
        HttpClient.findProxyFromEnvironment(url, environment: environment);

  Future<Map<String, Object?>> _getJson(Uri url) async {
    final client = _client();
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return const {};
      return asMap(jsonDecode(body));
    } on Object {
      return const {};
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _post(
    Uri url,
    Object body, {
    bool form = false,
  }) async {
    final client = _client();
    try {
      final request = await client.postUrl(url);
      request.headers
        ..set(
          HttpHeaders.contentTypeHeader,
          form ? 'application/x-www-form-urlencoded' : 'application/json',
        )
        ..set(HttpHeaders.acceptHeader, 'application/json');
      request.add(
        utf8.encode(
          form
              ? Uri(queryParameters: (body as Map).cast<String, String>()).query
              : jsonEncode(body),
        ),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}: $text', uri: url);
      }
      return asMap(jsonDecode(text));
    } finally {
      client.close(force: true);
    }
  }

  /// Where [server] says it is signed in to, and how.
  Future<Map<String, Object?>> _discover(
    Uri server,
    Uri? resourceMetadata,
  ) async {
    final origin = server.replace(path: '', query: null, fragment: null);
    var resource = <String, Object?>{};
    if (resourceMetadata != null) resource = await _getJson(resourceMetadata);
    if (resource.isEmpty) {
      resource = await _getJson(
        origin.replace(
          path: '/.well-known/oauth-protected-resource${server.path}',
        ),
      );
    }
    if (resource.isEmpty) {
      resource = await _getJson(
        origin.replace(path: '/.well-known/oauth-protected-resource'),
      );
    }
    final issuer = switch (asList(resource['authorization_servers'])
        .firstOrNull) {
      final String url => Uri.parse(url),
      _ => origin,
    };
    final issuerOrigin = issuer.replace(path: '', query: null, fragment: null);
    final issuerPath = issuer.path == '/' ? '' : issuer.path;
    for (final path in [
      '/.well-known/oauth-authorization-server$issuerPath',
      '/.well-known/openid-configuration$issuerPath',
      '$issuerPath/.well-known/openid-configuration',
    ]) {
      final metadata = await _getJson(issuerOrigin.replace(path: path));
      if (metadata['authorization_endpoint'] is String) {
        return {...metadata, 'scopes': resource['scopes_supported']};
      }
    }
    return {
      'authorization_endpoint': issuerOrigin
          .replace(path: '/authorize')
          .toString(),
      'token_endpoint': issuerOrigin.replace(path: '/token').toString(),
      'registration_endpoint': issuerOrigin
          .replace(path: '/register')
          .toString(),
    };
  }

  /// Begins signing in to the server [name] at [server]: the page the user
  /// is to open. [onSignedIn] is called once they have.
  Future<Uri> begin(
    String name,
    Uri server, {
    Uri? resourceMetadata,
    required void Function(Object? error) onSignedIn,
  }) async {
    final key = keyOf(name, server);
    final metadata = await _discover(server, resourceMetadata);
    final callback = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://localhost:${callback.port}/callback';
    var clientId = asString(asMap(_tokens[key])['client_id']);
    String? clientSecret = asString(asMap(_tokens[key])['client_secret']);
    final registration = asString(metadata['registration_endpoint']);
    final registeredFor = asString(asMap(_tokens[key])['redirect_uri']);
    if ((clientId == null || registeredFor != redirect) &&
        registration != null) {
      final registered = await _post(Uri.parse(registration), {
        'client_name': 'Caocode',
        'redirect_uris': [redirect],
        'grant_types': ['authorization_code', 'refresh_token'],
        'response_types': ['code'],
        'token_endpoint_auth_method': 'none',
      });
      clientId = asString(registered['client_id']);
      clientSecret = asString(registered['client_secret']);
    }
    if (clientId == null) {
      await callback.close(force: true);
      throw const HttpException('The server does not let this client register');
    }
    final verifier = _random(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _random(32);
    final scopes = asList(metadata['scopes']).whereType<String>().join(' ');
    final authorize = Uri.parse('${metadata['authorization_endpoint']}');
    final url = authorize.replace(
      queryParameters: {
        ...authorize.queryParameters,
        'response_type': 'code',
        'client_id': clientId,
        'redirect_uri': redirect,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'resource': server.toString(),
        if (scopes.isNotEmpty) 'scope': scopes,
      },
    );
    final tokenEndpoint = '${metadata['token_endpoint']}';
    unawaited(() async {
      Object? failure;
      try {
        await for (final request in callback.timeout(
          const Duration(minutes: 10),
        )) {
          if (request.uri.path != '/callback') {
            request.response.statusCode = 404;
            await request.response.close();
            continue;
          }
          final query = request.uri.queryParameters;
          final ok = query['state'] == state && query['code'] != null;
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            ok
                ? '<html><body style="font-family:sans-serif"><h3>Signed in to $name.</h3>You can close this window and return to Caocode.</body></html>'
                : '<html><body style="font-family:sans-serif"><h3>Sign-in failed.</h3>${const HtmlEscape().convert(query['error_description'] ?? query['error'] ?? 'Unexpected response')}</body></html>',
          );
          await request.response.close();
          if (!ok) {
            failure = query['error'] ?? 'Sign-in failed';
            break;
          }
          final tokens = await _post(Uri.parse(tokenEndpoint), {
            'grant_type': 'authorization_code',
            'code': query['code']!,
            'redirect_uri': redirect,
            'client_id': clientId!,
            'code_verifier': verifier,
            'resource': server.toString(),
            'client_secret': ?clientSecret,
          }, form: true);
          _keep(key, tokens, {
            'client_id': clientId,
            'client_secret': ?clientSecret,
            'token_endpoint': tokenEndpoint,
            'redirect_uri': redirect,
            'resource': server.toString(),
          });
          break;
        }
      } on Object catch (error) {
        failure = error;
      } finally {
        await callback.close(force: true);
      }
      onSignedIn(failure);
    }());
    return url;
  }

  void _keep(
    String key,
    Map<String, Object?> tokens,
    Map<String, Object?> client,
  ) {
    final expiresIn = asInt(tokens['expires_in']);
    _tokens[key] = {
      ...asMap(_tokens[key]),
      ...client,
      'access_token': tokens['access_token'],
      if (tokens['refresh_token'] != null)
        'refresh_token': tokens['refresh_token'],
      if (expiresIn != null)
        'expires_at': DateTime.now().millisecondsSinceEpoch + expiresIn * 1000,
    };
    _save();
  }

  Future<Map<String, Object?>> _refresh(
    String key,
    Map<String, Object?> entry,
  ) async {
    final tokens = await _post(Uri.parse('${entry['token_endpoint']}'), {
      'grant_type': 'refresh_token',
      'refresh_token': '${entry['refresh_token']}',
      'client_id': '${entry['client_id']}',
      if (entry['client_secret'] case final String secret)
        'client_secret': secret,
      if (entry['resource'] case final String resource) 'resource': resource,
    }, form: true);
    _keep(key, tokens, const {});
    return asMap(_tokens[key]);
  }

  static final _secure = math.Random.secure();

  static String _random(int length) {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return [
      for (var i = 0; i < length; i++)
        alphabet[_secure.nextInt(alphabet.length)],
    ].join();
  }
}
