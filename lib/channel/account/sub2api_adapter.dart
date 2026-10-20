import 'dart:async';
import 'dart:math';

import 'account_api.dart';
import 'login_window.dart';

/// sub2api (github.com/Wei-Shaw/sub2api): its pages keep the session in
/// local storage, a refresh token (`refresh_token`) with a short-lived
/// access token, traded at `/api/v1/auth/refresh` for a new pair. The app
/// keeps the refresh token, read from the login window's page, and trades
/// it as the pages do; each trade gives the next.
///
/// Balances are in US dollars; keys are listed whole, each with its group
/// (whose platform says what models it is for).
class Sub2ApiAdapter extends AccountAdapter {
  Sub2ApiAdapter({
    required super.site,
    required super.send,
    required super.credential,
    super.onCredential,
    super.now,
    Random? random,
  }) : _random = random ?? Random.secure();

  final Random _random;
  String? _access;
  DateTime _accessUntil = DateTime.fromMillisecondsSinceEpoch(0);

  Uri _url(String path, [Map<String, String>? query]) =>
      site.url.replace(path: '/api/v1$path', queryParameters: query);

  @override
  Future<String?> signedIn(LoginWindow window) async {
    final token = await window.evaluate(
      "localStorage.getItem('refresh_token')",
    );
    return token is String && token.isNotEmpty ? token : null;
  }

  /// An access token good for a minute more, traded for if need be.
  Future<String> _token({bool fresh = false}) async {
    if (!fresh && _access != null) {
      if (_accessUntil.isAfter(now().add(const Duration(minutes: 1)))) {
        return _access!;
      }
    }
    final refresh = credential;
    if (refresh == null) throw const AccountSignedOut();
    final response = await send(
      'POST',
      _url('/auth/refresh'),
      json: {'refresh_token': refresh},
    );
    if (response.status == 401 || response.status == 403) {
      forget();
      throw const AccountSignedOut();
    }
    final data = _data(response);
    final token = switch (data) {
      {'access_token': final String token} when token.isNotEmpty => token,
      _ => throw const AccountError('no access token'),
    };
    if (data case {'refresh_token': final String next} when next.isNotEmpty) {
      renewed(next);
    }
    _access = token;
    _accessUntil = now().add(switch (data) {
      {'expires_in': final num seconds} => Duration(seconds: seconds.toInt()),
      _ => const Duration(minutes: 5),
    });
    return token;
  }

  /// [response]'s `data`, if it succeeded.
  Object? _data(AccountResponse response) {
    final json = response.json;
    if (response.ok && json is Map && json['code'] == 0) return json['data'];
    final message = json is Map ? json['message'] : null;
    throw AccountError(
      message is String && message.isNotEmpty
          ? message
          : 'HTTP ${response.status}',
    );
  }

  /// [method] [path] with the access token; once again with a fresh one
  /// should it have ended meanwhile.
  Future<Object?> _call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, String> headers = const {},
    Object? json,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final token = await _token(fresh: attempt > 0);
      final response = await send(
        method,
        _url(path, query),
        headers: {...headers, 'Authorization': 'Bearer $token'},
        json: json,
      );
      if (response.status == 401 && attempt == 0) continue;
      if (response.status == 401) {
        forget();
        throw const AccountSignedOut();
      }
      return _data(response);
    }
  }

  @override
  Future<AccountProfile> profile() async {
    final me = await _call('GET', '/auth/me');
    if (me is! Map) throw const AccountError('no user');
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    final email = text(me['email']);
    final balance = me['balance'];
    return AccountProfile(
      name: email ?? text(me['username']) ?? '',
      email: email,
      balance: balance is num ? balance.toDouble() : null,
    );
  }

  @override
  Future<List<AccountKey>> keys() async {
    final data = await _call(
      'GET',
      '/keys',
      query: {'page': '1', 'page_size': '100'},
    );
    return [
      for (final item in _items(data))
        if (item case {'id': final num id, 'key': final String key})
          AccountKey(
            id: '${id.toInt()}',
            name: switch (item['name']) {
              final String name when name.trim().isNotEmpty => name.trim(),
              _ => '#${id.toInt()}',
            },
            masked: AccountKey.mask(key),
            platform: switch (item['group']) {
              {'platform': final String platform} when platform.isNotEmpty =>
                platform,
              _ => null,
            },
          ),
    ];
  }

  static List<Object?> _items(Object? data) => switch (data) {
    {'items': final List<Object?> items} => items,
    final List<Object?> items => items,
    _ => const [],
  };

  @override
  Future<String> reveal(AccountKey key) async {
    final data = await _call('GET', '/keys/${key.id}');
    return switch (data) {
      {'key': final String whole} when whole.isNotEmpty => whole,
      _ => throw const AccountError('no key'),
    };
  }

  @override
  Future<List<AccountGroup>> groups() async {
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    return [
      for (final group in _items(await _call('GET', '/groups/available')))
        if (group case {'id': final num id})
          AccountGroup(
            id: '${id.toInt()}',
            name: text(group['name']) ?? '#${id.toInt()}',
            description: text(group['description']),
            rate: switch (group['rate_multiplier']) {
              final num rate => rate.toDouble(),
              _ => null,
            },
            platform: text(group['platform']),
          ),
    ];
  }

  @override
  Future<AccountKey> create(String name, {AccountGroup? group}) async {
    // A key without a group reaches no models: without one picked, the
    // first group the user may use, Anthropic's first (Caocode speaks it
    // best).
    if (group == null) {
      final groups = await this.groups();
      group =
          groups.where((g) => g.platform == 'anthropic').firstOrNull ??
          groups.firstOrNull;
    }
    await _call(
      'POST',
      '/keys',
      // Its pages send one with each write; the site wants it.
      headers: {'Idempotency-Key': _idempotencyKey()},
      json: {'name': name, 'group_id': ?int.tryParse(group?.id ?? '')},
    );
    final made = await keys();
    // Listed newest first.
    return made.firstWhere(
      (key) => key.name == name,
      orElse: () => made.isEmpty
          ? throw const AccountError('the key was not made')
          : made.first,
    );
  }

  String _idempotencyKey() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  @override
  Future<void> signOut() async {
    final refresh = credential;
    if (refresh != null) {
      try {
        await send(
          'POST',
          _url('/auth/logout'),
          headers: {
            if (_access case final access?) 'Authorization': 'Bearer $access',
          },
          json: {'refresh_token': refresh},
        );
      } on Object {
        // Forgotten here all the same; it ends on the site in time.
      }
    }
    _access = null;
    forget();
  }
}
