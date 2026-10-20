import 'dart:async';

import 'package:caocode/channel/account/account_api.dart';
import 'package:caocode/channel/account/login_window.dart';

/// A request the fake site was sent.
typedef Sent = ({
  String method,
  Uri url,
  Map<String, String> headers,
  Object? json,
});

/// An account site answering as [routes] say (`METHOD /path` to an
/// answer), recording what it was sent.
class FakeSite {
  FakeSite(this.routes);

  final Map<String, AccountResponse Function(Sent sent)> routes;
  final List<Sent> sent = [];

  Future<AccountResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? json,
  }) async {
    final request = (method: method, url: url, headers: headers, json: json);
    sent.add(request);
    final route = routes['$method ${url.path}'];
    if (route == null) return const AccountResponse(404, null);
    return route(request);
  }

  List<String> get paths => [for (final s in sent) '${s.method} ${s.url.path}'];
}

/// A login window whose page signs in once [signIn] is called.
class FakeLoginWindow implements LoginWindow {
  final _closed = Completer<void>();
  Uri? opened;
  String? title;
  Map<String, String> cookieJar = {};
  Map<String, Object?> storage = {};
  bool shut = false;

  @override
  Future<void> open(Uri url, {required String title}) async {
    opened = url;
    this.title = title;
  }

  @override
  Future<Object?> evaluate(String expression) async {
    final key = RegExp(r"getItem\('([^']+)'\)").firstMatch(expression)?[1];
    return storage[key];
  }

  @override
  Future<Map<String, String>> cookies(Uri url) async => cookieJar;

  @override
  Future<void> close() async {
    shut = true;
    if (!_closed.isCompleted) _closed.complete();
  }

  /// The user closing it.
  void dismiss() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> get closed => _closed.future;
}

AccountResponse ok(Object? data, {Map<String, String> cookies = const {}}) =>
    AccountResponse(200, {
      'success': true,
      'message': '',
      'data': data,
    }, cookies: cookies);

AccountResponse sub(Object? data) =>
    AccountResponse(200, {'code': 0, 'message': 'success', 'data': data});

/// new-api with one user, its session rotating at each refresh.
FakeSite newApiSite({List<Map<String, Object?>>? tokens}) {
  var session = 0;
  final made = [
    ...tokens ??
        [
          {'id': 7, 'name': 'main', 'key': 'abcd**********wxyz', 'status': 1},
        ],
  ];
  return FakeSite({
    'POST /api/user/auth/refresh': (sent) {
      if (sent.headers['Cookie'] == 'new_api_refresh=revoked') {
        return const AccountResponse(401, {'success': false});
      }
      session++;
      return ok(
        {'access_token': 'jwt$session', 'access_expires_at': 4102444800},
        cookies: {'new_api_refresh': 'r$session'},
      );
    },
    'GET /api/user/self': (_) => ok({
      'id': 1,
      'username': 'leo',
      'email': 'leo@example.com',
      'quota': 1250000,
    }),
    'GET /api/status': (_) => ok({'quota_per_unit': 500000}),
    'GET /api/token/': (_) => ok({'items': made, 'total': made.length}),
    'POST /api/token/7/key': (_) => ok({'key': 'abcdWHOLEwxyz'}),
    'POST /api/token/8/key': (_) => ok({'key': 'newWHOLEkey0'}),
    'GET /api/user/self/groups': (_) => ok({
      'default': {'ratio': 1, 'desc': 'Default'},
      'vip': {'ratio': 0.5, 'desc': ''},
      'auto': {'ratio': 'auto', 'desc': 'Picked per call'},
    }),
    'POST /api/token/': (sent) {
      made.insert(0, {
        'id': 8,
        'name': (sent.json! as Map)['name'],
        'key': 'newk**********key0',
      });
      return ok(null);
    },
    'POST /api/user/auth/logout': (_) => ok(null),
  });
}

/// sub2api with one user, its refresh token rotating at each refresh.
FakeSite sub2apiSite() {
  var session = 0;
  return FakeSite({
    'POST /api/v1/auth/refresh': (sent) {
      session++;
      return sub({
        'access_token': 'a$session',
        'refresh_token': 'rt$session',
        'expires_in': 3600,
        'token_type': 'Bearer',
      });
    },
    'GET /api/v1/auth/me': (_) => sub({
      'id': 1,
      'email': 'sub@example.com',
      'username': 'sub',
      'balance': 12.5,
    }),
    'GET /api/v1/keys': (_) => sub({
      'items': [
        {
          'id': 3,
          'name': 'codex',
          'key': 'sk-0123456789abcdef0123',
          'group': {'id': 2, 'platform': 'openai'},
        },
      ],
      'total': 1,
    }),
    'GET /api/v1/keys/3': (_) =>
        sub({'id': 3, 'key': 'sk-0123456789abcdef0123'}),
    'GET /api/v1/groups/available': (_) => sub([
      {'id': 2, 'name': 'Codex', 'platform': 'openai', 'rate_multiplier': 1},
      {
        'id': 5,
        'name': 'Claude',
        'description': 'Claude models',
        'platform': 'anthropic',
        'rate_multiplier': 1.5,
      },
    ]),
    'POST /api/v1/keys': (_) => sub({'id': 4}),
    'POST /api/v1/auth/logout': (_) => sub({'message': 'ok'}),
  });
}
