part of 'browser_tools.dart';

// The agents' request interception (DevTools' request blocking, local
// overrides, and what a proxy would do): rules on a tab's requests, by URL,
// that block them, answer them in the browser's stead, change them as they
// go, change the server's answer, or hold them a while. Through the Fetch
// domain, on while a rule is.

/// A rule on a tab's requests.
class _Rule {
  _Rule({
    required this.id,
    required this.url,
    required this.action,
    this.method,
    this.resourceType,
    this.status,
    this.headers = const {},
    this.body,
    this.file,
    this.replace = const [],
    this.requestHeaders = const {},
    this.postData,
    this.redirect,
    this.delay = 0,
    this.error,
    this.times,
  });

  final String id;

  /// What the URL has; with `*` (any run) or `?`, a pattern of all of it.
  final String url;

  /// `block`, `mock`, `request`, `response`, `delay`.
  final String action;
  final String? method;
  final String? resourceType;
  final int? status;
  final Map<String, String?> headers;
  final String? body;
  final String? file;
  final List<(String, String)> replace;
  final Map<String, String?> requestHeaders;
  final String? postData;
  final String? redirect;
  final int delay;
  final String? error;
  final int? times;
  int hits = 0;

  bool get atResponse => action == 'response';

  bool get _glob => url.contains('*') || url.contains('?');

  /// The Fetch domain's pattern for it.
  String get pattern {
    if (_glob) return url;
    final escaped = url.replaceAllMapped(RegExp(r'[*?\\]'), (m) => '\\${m[0]}');
    return '*$escaped*';
  }

  late final RegExp _regex = RegExp(
    '^${url.split('').map((c) => switch (c) {
      '*' => '.*',
      '?' => '.',
      _ => RegExp.escape(c),
    }).join()}\$',
  );

  bool matches(Map request, String? type) =>
      (_glob
          ? _regex.hasMatch('${request['url']}')
          : '${request['url']}'.contains(url)) &&
      (method == null || method!.toUpperCase() == request['method']) &&
      (resourceType == null ||
          resourceType!.toLowerCase() == type?.toLowerCase());

  String describe() => [
    id,
    action,
    url,
    ?method,
    ?resourceType,
    switch (action) {
      'block' => error ?? 'BlockedByClient',
      'mock' =>
        '→ ${status ?? 200}${file != null
            ? ' $file'
            : body != null
            ? ' (${body!.length} chars)'
            : ''}',
      'response' => [
        if (status != null) 'status $status',
        if (headers.isNotEmpty) 'headers ${headers.keys.join(', ')}',
        if (file != null) 'body $file',
        if (body != null) 'body (${body!.length} chars)',
        for (final (find, _) in replace) 'replace ${jsonEncode(find)}',
      ].join(', '),
      'request' => [
        if (redirect != null) 'to $redirect',
        if (requestHeaders.isNotEmpty)
          'headers ${requestHeaders.keys.join(', ')}',
        if (postData != null) 'body (${postData!.length} chars)',
      ].join(', '),
      _ => '$delay ms',
    },
    if (times != null) '($hits of $times times)' else '($hits hits)',
  ].where((s) => s.isNotEmpty).join(' ');
}

/// A tab's rules, and the requests they hold.
class _Interception {
  _Interception._(this.tab) {
    _subscription = BrowserBridge.instance.events.listen(_received);
  }

  static final Map<BrowserTab, _Interception> _tabs = {};

  static _Interception of(BrowserTab tab) =>
      _tabs.putIfAbsent(tab, () => _Interception._(tab));

  final BrowserTab tab;
  StreamSubscription<BrowserEvent>? _subscription;
  final List<_Rule> rules = [];
  int _next = 0;

  String nextId() => 'r${++_next}';

  Future<void> apply() async {
    if (rules.isEmpty) {
      await tab.browser.cdp(tab.tabId, 'Fetch.disable');
      return;
    }
    await tab.browser.cdp(tab.tabId, 'Fetch.enable', {
      'patterns': [
        for (final r in rules)
          {
            'urlPattern': r.pattern,
            'requestStage': r.atResponse ? 'Response' : 'Request',
            if (r.resourceType case final type?)
              'resourceType': '${type[0].toUpperCase()}${type.substring(1)}',
          },
      ],
    });
  }

  void _received(BrowserEvent event) {
    if (!identical(event.connection, tab.browser) || event.tabId != tab.tabId) {
      return;
    }
    switch (event.event) {
      case 'closed' || 'unshared':
        _tabs.remove(tab);
        unawaited(_subscription?.cancel());
        return;
      case 'detached':
        // The domain went with the debugger.
        rules.clear();
        return;
      case 'cdp' when event.message['sessionId'] == null:
        if (event.message['method'] == 'Fetch.requestPaused') {
          unawaited(
            _paused((event.message['params'] as Map).cast<String, Object?>()),
          );
        }
    }
  }

  Future<void> _send(String method, Map<String, Object?> params) =>
      tab.browser.cdp(tab.tabId, method, params);

  Future<void> _paused(Map<String, Object?> params) async {
    final id = params['requestId'] as String;
    final request = (params['request'] as Map?) ?? const {};
    final atResponse =
        params.containsKey('responseStatusCode') ||
        params.containsKey('responseErrorReason');
    final type = params['resourceType'] as String?;
    try {
      final rule = rules
          .where((r) => r.atResponse == atResponse && r.matches(request, type))
          .firstOrNull;
      if (rule == null) {
        await _send('Fetch.continueRequest', {'requestId': id});
        return;
      }
      rule.hits++;
      if (rule.times case final times? when rule.hits >= times) {
        rules.remove(rule);
        unawaited(apply().catchError((Object _) {}));
      }
      switch (rule.action) {
        case 'block':
          await _send('Fetch.failRequest', {
            'requestId': id,
            'errorReason': rule.error ?? 'BlockedByClient',
          });
        case 'mock':
          final body = await _body(rule) ?? '';
          final headers = <String, String?>{
            'content-type': _mimeOf(rule.file, body),
            ...rule.headers,
          };
          // A page of another origin may read it.
          final origin = _header(request['headers'] as Map?, 'origin');
          if (origin != null &&
              !headers.keys.any(
                (k) => k.toLowerCase() == 'access-control-allow-origin',
              )) {
            headers['access-control-allow-origin'] = origin;
            headers['access-control-allow-credentials'] = 'true';
          }
          await _send('Fetch.fulfillRequest', {
            'requestId': id,
            'responseCode': rule.status ?? 200,
            'responseHeaders': _headerList(headers),
            'body': base64Encode(utf8.encode(body)),
          });
        case 'request':
          final headers = <String, String?>{
            for (final MapEntry(:key, :value)
                in ((request['headers'] as Map?) ?? const {}).entries)
              '$key': '$value',
          };
          for (final MapEntry(:key, :value) in rule.requestHeaders.entries) {
            headers.removeWhere((k, _) => k.toLowerCase() == key.toLowerCase());
            headers[key] = value;
          }
          await _send('Fetch.continueRequest', {
            'requestId': id,
            'url': ?rule.redirect,
            if (rule.postData case final data?)
              'postData': base64Encode(utf8.encode(data)),
            'headers': _headerList(headers),
          });
        case 'response':
          if (params.containsKey('responseErrorReason')) {
            await _send('Fetch.continueRequest', {'requestId': id});
            return;
          }
          final headers = <String, String?>{
            for (final h
                in (params['responseHeaders'] as List? ?? const []).cast<Map>())
              '${h['name']}': '${h['value']}',
          };
          String? body = await _body(rule);
          var base64 = false;
          if (body == null) {
            final got = await tab.browser.cdp(
              tab.tabId,
              'Fetch.getResponseBody',
              {'requestId': id},
            );
            body = got['body'] as String? ?? '';
            base64 = got['base64Encoded'] == true;
            if (rule.replace.isNotEmpty && base64) {
              try {
                body = utf8.decode(base64Decode(body));
                base64 = false;
              } on FormatException {
                // Not text: left as it is.
              }
            }
            if (!base64) {
              for (final (find, by) in rule.replace) {
                body = body!.replaceAll(find, by);
              }
            }
          }
          // The body given whole, as it is now.
          headers.removeWhere(
            (k, _) =>
                k.toLowerCase() == 'content-length' ||
                k.toLowerCase() == 'content-encoding',
          );
          for (final MapEntry(:key, :value) in rule.headers.entries) {
            headers.removeWhere((k, _) => k.toLowerCase() == key.toLowerCase());
            headers[key] = value;
          }
          await _send('Fetch.fulfillRequest', {
            'requestId': id,
            'responseCode':
                rule.status ??
                (params['responseStatusCode'] as num?)?.toInt() ??
                200,
            'responseHeaders': _headerList(headers),
            'body': base64 ? body : base64Encode(utf8.encode(body!)),
          });
        default:
          await Future<void>.delayed(Duration(milliseconds: rule.delay));
          await _send('Fetch.continueRequest', {'requestId': id});
      }
    } on Object {
      // Never left hanging.
      try {
        await _send('Fetch.continueRequest', {'requestId': id});
      } on Object {
        // Gone.
      }
    }
  }

  static Future<String?> _body(_Rule rule) async {
    if (rule.file case final path?) return File(path).readAsString();
    return rule.body;
  }

  static List<Map<String, String>> _headerList(Map<String, String?> headers) =>
      [
        for (final MapEntry(:key, :value) in headers.entries)
          if (value != null) {'name': key, 'value': value},
      ];

  static String? _header(Map? headers, String name) {
    for (final MapEntry(:key, :value) in (headers ?? const {}).entries) {
      if ('$key'.toLowerCase() == name) return '$value';
    }
    return null;
  }

  static String _mimeOf(String? file, String body) {
    final extension = file == null ? '' : p.extension(file).toLowerCase();
    return switch (extension) {
      '.js' || '.mjs' => 'application/javascript; charset=utf-8',
      '.css' => 'text/css; charset=utf-8',
      '.html' || '.htm' => 'text/html; charset=utf-8',
      '.json' => 'application/json; charset=utf-8',
      '.svg' => 'image/svg+xml',
      '.txt' => 'text/plain; charset=utf-8',
      _ =>
        RegExp(r'^\s*[\[{]').hasMatch(body)
            ? 'application/json; charset=utf-8'
            : 'text/plain; charset=utf-8',
    };
  }
}

final _interceptTool = ClaudeSdkTool(
  name: 'browser_intercept',
  description:
      "Rules on a shared tab's requests (by URL: what it has, or a pattern "
      'with *), as DevTools\' request blocking and local overrides, or a '
      'proxy: "block" them (error); "mock": answer in the server\'s stead '
      '(status, headers, body or file); "request": change them as they go '
      '(requestHeaders, postData, redirect to another URL); "response": '
      'change the server\'s answer (status, headers, body or file, or '
      'replace: [[find, with]…] in its text); "delay" them (ms). Kept '
      'over reloads; times: only so many. list, remove (id), clear.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'tabId': BrowserTools._tabId,
      'action': {
        'type': 'string',
        'enum': [
          'block',
          'mock',
          'request',
          'response',
          'delay',
          'list',
          'remove',
          'clear',
        ],
      },
      'url': {'type': 'string'},
      'method': {'type': 'string'},
      'resourceType': {
        'type': 'string',
        'description': 'Document, XHR, Fetch, Script, Stylesheet, Image…',
      },
      'status': {'type': 'integer'},
      'headers': {
        'type': 'object',
        'description': "The response's (null takes one out).",
      },
      'body': {'type': 'string'},
      'file': {
        'type': 'string',
        'description': 'A local file as the body (a build of a script).',
      },
      'replace': {
        'type': 'array',
        'items': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'requestHeaders': {
        'type': 'object',
        'description': "The request's (null takes one out).",
      },
      'postData': {'type': 'string'},
      'redirect': {'type': 'string'},
      'ms': {'type': 'integer'},
      'error': {
        'type': 'string',
        'description':
            'block: Failed, Aborted, TimedOut, AccessDenied, '
            'ConnectionRefused, NameNotResolved, InternetDisconnected; '
            'default BlockedByClient.',
      },
      'times': {'type': 'integer'},
      'id': {'type': 'string'},
    },
    'required': ['tabId', 'action'],
  },
  run: (input, call) async {
    final tab = BrowserTab(BrowserTools._browser(), input['tabId'] as int);
    final interception = _Interception.of(tab);
    final action = input['action'] as String;
    switch (action) {
      case 'list':
        return interception.rules.isEmpty
            ? 'No rule.'
            : interception.rules.map((r) => r.describe()).join('\n');
      case 'clear':
        interception.rules.clear();
        await interception.apply();
        return 'All rules taken out.';
      case 'remove':
        final id = input['id'] as String?;
        final before = interception.rules.length;
        interception.rules.removeWhere((r) => r.id == id);
        if (interception.rules.length == before) {
          throw BrowserError('No rule $id.');
        }
        await interception.apply();
        return 'Took out $id.';
    }
    final url = input['url'] as String? ?? '';
    if (url.isEmpty) throw const BrowserError('Say which requests: url.');
    Map<String, String?> headers(Object? map) => {
      for (final MapEntry(:key, :value) in ((map as Map?) ?? const {}).entries)
        '$key': value?.toString(),
    };
    final file = switch (input['file']) {
      final String path when path.isNotEmpty => _path(path, call.cwd),
      _ => null,
    };
    if (file != null && !File(file).existsSync()) {
      throw BrowserError('No file $file.');
    }
    final rule = _Rule(
      id: interception.nextId(),
      url: url,
      action: action,
      method: input['method'] as String?,
      resourceType: input['resourceType'] as String?,
      status: input['status'] as int?,
      headers: headers(input['headers']),
      body: input['body'] as String?,
      file: file,
      replace: [
        for (final pair in (input['replace'] as List? ?? const []).cast<List>())
          if (pair.length == 2) ('${pair[0]}', '${pair[1]}'),
      ],
      requestHeaders: headers(input['requestHeaders']),
      postData: input['postData'] as String?,
      redirect: input['redirect'] as String?,
      delay: ((input['ms'] as int?) ?? 2000).clamp(0, 120000),
      error: input['error'] as String?,
      times: input['times'] as int?,
    );
    interception.rules.add(rule);
    try {
      await interception.apply();
    } on Object {
      interception.rules.remove(rule);
      rethrow;
    }
    return 'Set ${rule.describe()}. It applies to requests from now on '
        '(reload for the page\'s own).';
  },
);
