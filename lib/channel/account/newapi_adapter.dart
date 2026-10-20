import 'dart:async';

import 'account_api.dart';
import 'login_window.dart';

/// new-api (github.com/QuantumNous/new-api), as of v1.0: its pages sign
/// in to a session whose refresh token is an HttpOnly cookie
/// (`new_api_refresh`), traded at `/api/user/auth/refresh` for a
/// short-lived access token, sent as a bearer. The app keeps the cookie's
/// value, read from the login window's cookies, and trades it as the pages
/// do (the panel's origin as theirs); each trade sets the next.
///
/// Its money is quota, `quota_per_unit` of it a US dollar (`/api/status`).
/// Its keys are listed masked, each revealed on its own.
class NewApiAdapter extends AccountAdapter {
  NewApiAdapter({
    required super.site,
    required super.send,
    required super.credential,
    super.onCredential,
    super.now,
  });

  static const refreshCookie = 'new_api_refresh';

  String? _access;
  DateTime _accessUntil = DateTime.fromMillisecondsSinceEpoch(0);
  double? _quotaPerUnit;

  String get _origin => site.url.origin;

  Uri _url(String path, [Map<String, String>? query]) =>
      site.url.replace(path: path, queryParameters: query);

  @override
  Future<String?> signedIn(LoginWindow window) async {
    final cookies = await window.cookies(site.url);
    return switch (cookies[refreshCookie]) {
      final String value when value.isNotEmpty => value,
      _ => null,
    };
  }

  Map<String, String> _sessionHeaders(String refresh) => {
    'Cookie': '$refreshCookie=$refresh',
    'Origin': _origin,
  };

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
      _url('/api/user/auth/refresh'),
      headers: _sessionHeaders(refresh),
    );
    if (response.status == 401 || response.status == 403) {
      forget();
      throw const AccountSignedOut();
    }
    final data = _data(response);
    if (response.cookies[refreshCookie] case final next? when next.isNotEmpty) {
      renewed(next);
    }
    final token = switch (data) {
      {'access_token': final String token} when token.isNotEmpty => token,
      _ => throw const AccountError('no access token'),
    };
    _access = token;
    _accessUntil = switch (data) {
      {'access_expires_at': final num at} =>
        DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000),
      _ => now().add(const Duration(minutes: 5)),
    };
    return token;
  }

  /// [response]'s `data`, if it succeeded.
  Object? _data(AccountResponse response) {
    final json = response.json;
    if (json is Map && json['success'] == true) return json['data'];
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
    Object? json,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final token = await _token(fresh: attempt > 0);
      final response = await send(
        method,
        _url(path, query),
        headers: {'Authorization': 'Bearer $token'},
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
    final self = await _call('GET', '/api/user/self');
    if (self is! Map) throw const AccountError('no user');
    final perUnit = _quotaPerUnit ??= await _readQuotaPerUnit();
    final quota = self['quota'];
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    final email = text(self['email']);
    return AccountProfile(
      name: email ?? text(self['display_name']) ?? text(self['username']) ?? '',
      email: email,
      balance: quota is num && perUnit != null && perUnit > 0
          ? quota / perUnit
          : null,
    );
  }

  Future<double?> _readQuotaPerUnit() async {
    try {
      final response = await send('GET', _url('/api/status'));
      return switch (_data(response)) {
        {'quota_per_unit': final num perUnit} => perUnit.toDouble(),
        _ => null,
      };
    } on AccountError {
      return null;
    }
  }

  @override
  Future<List<AccountKey>> keys() async {
    final data = await _call(
      'GET',
      '/api/token/',
      query: {'p': '1', 'page_size': '100'},
    );
    final items = switch (data) {
      {'items': final List<Object?> items} => items,
      final List<Object?> items => items,
      _ => const <Object?>[],
    };
    return [
      for (final item in items)
        if (item case {'id': final num id, 'key': final String key})
          AccountKey(
            id: '${id.toInt()}',
            name: switch (item['name']) {
              final String name when name.trim().isNotEmpty => name.trim(),
              _ => '#${id.toInt()}',
            },
            masked: _withPrefix(key),
          ),
    ];
  }

  @override
  Future<String> reveal(AccountKey key) async {
    final data = await _call('POST', '/api/token/${key.id}/key');
    return switch (data) {
      {'key': final String whole} when whole.isNotEmpty => _withPrefix(whole),
      _ => throw const AccountError('no key'),
    };
  }

  /// As new-api's pages show a key: `sk-` before it.
  static String _withPrefix(String key) =>
      key.startsWith('sk-') ? key : 'sk-$key';

  @override
  Future<List<AccountGroup>> groups() async {
    final data = await _call('GET', '/api/user/self/groups');
    if (data is! Map) return const [];
    return [
      for (final MapEntry(:key, :value) in data.entries)
        if (key is String && key.isNotEmpty)
          AccountGroup(
            id: key,
            name: key,
            description: switch (value) {
              {'desc': final String desc} when desc.trim().isNotEmpty =>
                desc.trim(),
              _ => null,
            },
            rate: switch (value) {
              {'ratio': final num ratio} => ratio.toDouble(),
              _ => null,
            },
          ),
    ];
  }

  @override
  Future<AccountKey> create(String name, {AccountGroup? group}) async {
    await _call(
      'POST',
      '/api/token/',
      json: {
        'name': name,
        'remain_quota': 0,
        'expired_time': -1,
        'unlimited_quota': true,
        'model_limits_enabled': false,
        'model_limits': '',
        // None: the user's own group.
        'group': group?.id ?? '',
      },
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

  @override
  Future<void> signOut() async {
    final refresh = credential;
    if (refresh != null) {
      try {
        await send(
          'POST',
          _url('/api/user/auth/logout'),
          headers: {
            ..._sessionHeaders(refresh),
            if (_access case final access?) 'Authorization': 'Bearer $access',
          },
        );
      } on Object {
        // Forgotten here all the same; it ends on the site in time.
      }
    }
    _access = null;
    forget();
  }
}
