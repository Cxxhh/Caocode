import 'dart:async';

import 'browser_bridge.dart';

/// What the shared tabs' pages log and load, kept from the first time
/// Caocode uses each (its console's and network's domains enabled then),
/// for agents to look at afterwards: as DevTools' Console and Network keep
/// them once open. Of the page's frames from other sites and its workers
/// too (their own sessions, attached to as they come), and the dialogs it
/// opens, the files it downloads.
class BrowserRecords {
  BrowserRecords._() {
    BrowserBridge.instance.events.listen(_received);
  }

  static final instance = BrowserRecords._();

  static const _maxConsole = 500;
  static const _maxRequests = 1000;

  /// The responses whose bodies are kept as they finish: what a page asks
  /// its server, and the pages themselves. The browser lets go of a page's
  /// as the tab goes to another; scripts, styles and images can be asked
  /// for again.
  static const _keptTypes = {'Document', 'XHR', 'Fetch'};

  /// Each body kept at most, and a tab's all together: the oldest let go.
  static const _maxBody = 1 << 20;
  static const _maxBodies = 32 << 20;

  /// A WebSocket's (or an EventSource's) messages kept, the last; and of
  /// each, its first bytes.
  static const _maxFrames = 1000;
  static const _maxFrame = 100 << 10;

  /// How the page's frames of other sites and its workers are attached to:
  /// each its session, the tab's own going on meanwhile.
  static const _autoAttach = {
    'autoAttach': true,
    'waitForDebuggerOnStart': false,
    'flatten': true,
  };

  final Map<BrowserTab, _TabRecords> _tabs = {};

  /// What is kept, as it is: a console entry ([ConsoleEntry]), a request
  /// done ([NetworkRequest]: finished or failed, its body kept first), a
  /// dialog, a download. For the history.
  Stream<(BrowserTab, Object)> get added => _added.stream;
  final _added = StreamController<(BrowserTab, Object)>.broadcast(sync: true);

  /// Whether [tab]'s are kept (its domains on).
  bool watching(BrowserTab tab) => _tabs[tab]?.watching != null;

  /// Whether an agent acts in [tab] now (see [acting]).
  bool isActing(BrowserTab tab) => (_tabs[tab]?.acting ?? 0) > 0;

  /// Starts keeping [tab]'s, if not yet: before what an agent does there.
  Future<void> watch(BrowserTab tab) async {
    final records = _tabs.putIfAbsent(tab, _TabRecords.new);
    if (records.watching != null) return records.watching;
    final watching = () async {
      for (final (method, params) in [
        ('Network.enable', {'maxPostDataSize': 65536}),
        ('Runtime.enable', const <String, Object?>{}),
        ('Log.enable', const <String, Object?>{}),
        ('Page.enable', const <String, Object?>{}),
        ('Performance.enable', const <String, Object?>{}),
      ]) {
        await tab.browser.cdp(tab.tabId, method, params);
      }
      records.since ??= DateTime.now();
      if (tab.browser.can('cdp.session')) {
        try {
          await tab.browser.cdp(tab.tabId, 'Target.setAutoAttach', _autoAttach);
        } on Object {
          // The page's own alone.
        }
      }
    }();
    records.watching = watching;
    try {
      await watching;
    } on Object {
      // Asked again next time.
      records.watching = null;
      rethrow;
    }
  }

  /// When Caocode began keeping [tab]'s: what came before is not here.
  DateTime? since(BrowserTab tab) => _tabs[tab]?.since;

  List<ConsoleEntry> console(BrowserTab tab) => [...?_tabs[tab]?.console];

  List<NetworkRequest> requests(BrowserTab tab) => [
    ...?_tabs[tab]?.requests.values,
  ];

  NetworkRequest? request(BrowserTab tab, String id) =>
      _tabs[tab]?.requests[id];

  List<BrowserDialog> dialogs(BrowserTab tab) => [...?_tabs[tab]?.dialogs];

  /// The dialog [tab]'s page waits on now (nothing runs in it till it is
  /// answered), if one.
  BrowserDialog? openDialog(BrowserTab tab) => _tabs[tab]?.openDialog;

  List<BrowserDownload> downloads(BrowserTab tab) => [
    ...?_tabs[tab]?.downloads,
  ];

  /// [tab]'s style sheets, by id, as the CSS domain told them (once on).
  Map<String, Map<String, Object?>> styleSheets(BrowserTab tab) =>
      _tabs[tab]?.styleSheets ?? const {};

  /// The frames' and workers' sessions of [tab]'s: their type and URL.
  Map<String, ({String type, String url})> sessions(BrowserTab tab) =>
      _tabs[tab]?.sessions ?? const {};

  void clearConsole(BrowserTab tab) => _tabs[tab]?.console.clear();

  void clearRequests(BrowserTab tab) => _tabs[tab]?.clearRequests();

  /// Runs [action], an agent's in [tab]: the dialogs its page opens
  /// meanwhile are answered (see [answerDialogs]), not left for the user.
  Future<T> acting<T>(BrowserTab tab, Future<T> Function() action) async {
    final records = _tabs.putIfAbsent(tab, _TabRecords.new);
    records.acting++;
    try {
      return await action();
    } finally {
      records.acting--;
    }
  }

  /// How [tab]'s next dialog is answered (all of them, if [always]):
  /// accepted (with [text], a prompt's) or dismissed. Without, while an
  /// agent acts: an alert's or a leaving page's accepted, a question's
  /// (confirm, prompt) dismissed.
  void answerDialogs(
    BrowserTab tab, {
    required bool accept,
    String? text,
    bool always = false,
  }) {
    _tabs.putIfAbsent(tab, _TabRecords.new).answer = (
      accept: accept,
      text: text,
      always: always,
    );
  }

  /// Answers the dialog open in [tab].
  Future<BrowserDialog?> answerOpenDialog(
    BrowserTab tab, {
    required bool accept,
    String? text,
  }) async {
    final records = _tabs[tab];
    final dialog = records?.openDialog;
    if (records == null || dialog == null) return null;
    await tab.browser.cdp(tab.tabId, 'Page.handleJavaScriptDialog', {
      'accept': accept,
      'promptText': ?text,
    });
    dialog.answer = accept ? 'accepted' : 'dismissed';
    records.openDialog = null;
    return dialog;
  }

  /// [request]'s response body: kept as it finished, else asked of the
  /// browser; null if it no longer has it.
  Future<({String data, bool base64})?> responseBody(
    BrowserTab tab,
    NetworkRequest request,
  ) async {
    if (request.body case final body?) {
      return (data: body, base64: request.bodyBase64);
    }
    try {
      final result = await tab.browser.cdp(
        tab.tabId,
        'Network.getResponseBody',
        {'requestId': request.id},
        const Duration(seconds: 30),
        request.sessionId,
      );
      return (
        data: result['body'] as String? ?? '',
        base64: result['base64Encoded'] == true,
      );
    } on Object {
      return null;
    }
  }

  /// [request]'s body (a POST's): as it was sent, else asked of the browser
  /// (a large one); null if it had none, or the browser no longer has it.
  Future<String?> requestBody(BrowserTab tab, NetworkRequest request) async {
    if (!request.hasPostData || request.postData != null) {
      return request.postData;
    }
    try {
      final result = await tab.browser.cdp(
        tab.tabId,
        'Network.getRequestPostData',
        {'requestId': request.id},
        const Duration(seconds: 30),
        request.sessionId,
      );
      return result['postData'] as String?;
    } on Object {
      return null;
    }
  }

  Future<void> _keep(
    BrowserTab tab,
    _TabRecords records,
    NetworkRequest request,
    String requestId,
  ) async {
    try {
      final result = await tab.browser.cdp(
        tab.tabId,
        'Network.getResponseBody',
        {'requestId': requestId},
        const Duration(seconds: 30),
        request.sessionId,
      );
      final data = result['body'] as String? ?? '';
      if (data.length > _maxBody) return;
      records.keep(
        request
          ..body = data
          ..bodyBase64 = result['base64Encoded'] == true,
      );
    } on Object {
      // The browser has none (a redirect's, a 204's) or let it go already.
    } finally {
      _added.add((tab, request));
    }
  }

  /// A frame's or a worker's session, attached: what it logs and loads
  /// kept too, and its own frames and workers attached to.
  Future<void> _attached(BrowserTab tab, String session, String type) async {
    final browser = tab.browser;
    for (final (method, params) in [
      ('Network.enable', {'maxPostDataSize': 65536}),
      ('Runtime.enable', const <String, Object?>{}),
      if (type == 'iframe') ('Log.enable', const <String, Object?>{}),
      if (type == 'iframe') ('Target.setAutoAttach', _autoAttach),
      ('Runtime.runIfWaitingForDebugger', const <String, Object?>{}),
    ]) {
      try {
        await browser.cdp(
          tab.tabId,
          method,
          params,
          const Duration(seconds: 10),
          session,
        );
      } on Object {
        // Gone already, or a kind without it.
      }
    }
  }

  void _received(BrowserEvent event) {
    final tabId = event.tabId;
    if (tabId == null) return;
    final tab = BrowserTab(event.connection, tabId);
    switch (event.event) {
      case 'closed' || 'unshared':
        _tabs.remove(tab);
        return;
      case 'detached':
        // Enabled again as it is used again.
        _tabs[tab]
          ?..watching = null
          ..sessions.clear()
          ..openDialog = null;
        return;
      case 'cdp':
        break;
      default:
        return;
    }
    final records = _tabs[tab];
    if (records == null) return;
    final session = event.message['sessionId'] as String?;
    final params =
        (event.message['params'] as Map?)?.cast<String, Object?>() ?? {};
    switch (event.message['method']) {
      case 'Target.attachedToTarget':
        final id = params['sessionId'] as String?;
        final info = (params['targetInfo'] as Map?) ?? const {};
        final type = info['type'] as String? ?? '';
        if (id == null) return;
        records.sessions[id] = (type: type, url: info['url'] as String? ?? '');
        unawaited(_attached(tab, id, type));
      case 'Target.detachedFromTarget':
        records.sessions.remove(params['sessionId']);
      case 'Runtime.consoleAPICalled':
        _log(
          tab,
          records,
          ConsoleEntry.fromConsole(params, records.where(session)),
        );
      case 'Runtime.exceptionThrown':
        _log(
          tab,
          records,
          ConsoleEntry.fromException(params, records.where(session)),
        );
      case 'Log.entryAdded':
        _log(
          tab,
          records,
          ConsoleEntry.fromLog(params, records.where(session)),
        );
      case 'Network.requestWillBeSent':
        final id = params['requestId'] as String;
        final redirected = records.requests[id];
        if (redirected != null && params['redirectResponse'] is Map) {
          // A redirect: the one before keeps its id's own, apart.
          redirected.respond(
            (params['redirectResponse'] as Map).cast<String, Object?>(),
          );
          redirected
            ..finished = true
            ..end = (params['timestamp'] as num?)?.toDouble();
          records.requests.remove(id);
          records.add(redirected..id = '$id.r${records.redirects++}');
          _added.add((tab, redirected));
        }
        final request = NetworkRequest.fromSent(params, session);
        if (records.extraRequest.remove(id) case final headers?) {
          request.wireRequestHeaders = headers;
        }
        if (records.extraResponse.remove(id) case final headers?) {
          request.wireResponseHeaders = headers;
        }
        records.add(request);
      case 'Network.requestWillBeSentExtraInfo':
        final id = params['requestId'] as String;
        final headers = (params['headers'] as Map? ?? const {})
            .cast<String, Object?>();
        if (records.requests[id] case final request?) {
          request.wireRequestHeaders = headers;
        } else {
          records.early(records.extraRequest, id, headers);
        }
      case 'Network.responseReceivedExtraInfo':
        final id = params['requestId'] as String;
        final headers = (params['headers'] as Map? ?? const {})
            .cast<String, Object?>();
        if (records.requests[id] case final request?) {
          request.wireResponseHeaders = headers;
        } else {
          records.early(records.extraResponse, id, headers);
        }
      case 'Network.responseReceived':
        final request = records.requests[params['requestId']];
        request?.type = params['type'] as String? ?? request.type;
        request?.respond((params['response'] as Map).cast<String, Object?>());
      case 'Network.loadingFinished':
        final id = params['requestId'] as String;
        final request = records.requests[id];
        if (request == null) return;
        request
          ..finished = true
          ..end = (params['timestamp'] as num?)?.toDouble()
          ..size = (params['encodedDataLength'] as num?)?.toInt();
        if (_keptTypes.contains(request.type) &&
            (request.size ?? 0) <= _maxBody) {
          unawaited(_keep(tab, records, request, id));
        } else {
          _added.add((tab, request));
        }
      case 'Network.loadingFailed':
        final request = records.requests[params['requestId']];
        if (request == null) return;
        request
          ..finished = true
          ..end = (params['timestamp'] as num?)?.toDouble()
          ..failure = params['canceled'] == true
              ? 'canceled'
              : params['blockedReason'] is String
              ? 'blocked (${params['blockedReason']})'
              : params['corsErrorStatus'] is Map
              ? 'CORS (${(params['corsErrorStatus'] as Map)['corsError']})'
              : params['errorText'] as String? ?? 'failed';
        _added.add((tab, request));
      case 'Network.webSocketCreated':
        records.add(
          NetworkRequest.socket(
            params['requestId'] as String,
            params['url'] as String? ?? '',
            (params['initiator'] as Map?)?.cast<String, Object?>(),
            session,
          ),
        );
      case 'Network.webSocketWillSendHandshakeRequest':
        final request = records.requests[params['requestId']];
        if (request == null) return;
        request
          ..start = (params['timestamp'] as num?)?.toDouble() ?? request.start
          ..wall = (params['wallTime'] as num?)?.toDouble() ?? request.wall;
        final headers = ((params['request'] as Map?)?['headers'] as Map?)
            ?.cast<String, Object?>();
        if (headers != null) request.wireRequestHeaders = headers;
      case 'Network.webSocketHandshakeResponseReceived':
        records.requests[params['requestId']]?.respond(
          (params['response'] as Map).cast<String, Object?>(),
        );
      case 'Network.webSocketFrameSent' || 'Network.webSocketFrameReceived':
        final request = records.requests[params['requestId']];
        final response = (params['response'] as Map?) ?? const {};
        request?.addFrame(
          NetworkFrame(
            sent: event.message['method'] == 'Network.webSocketFrameSent',
            timestamp: (params['timestamp'] as num?)?.toDouble() ?? 0,
            opcode: (response['opcode'] as num?)?.toInt() ?? 1,
            payload: response['payloadData'] as String? ?? '',
          ),
        );
      case 'Network.webSocketFrameError':
        records.requests[params['requestId']]?.addFrame(
          NetworkFrame(
            sent: false,
            timestamp: (params['timestamp'] as num?)?.toDouble() ?? 0,
            opcode: -1,
            payload: '',
            error: params['errorMessage'] as String? ?? 'error',
          ),
        );
      case 'Network.webSocketClosed':
        final socket = records.requests[params['requestId']];
        if (socket == null) return;
        socket
          ..finished = true
          ..end = (params['timestamp'] as num?)?.toDouble();
        _added.add((tab, socket));
      case 'Network.eventSourceMessageReceived':
        records.requests[params['requestId']]?.addFrame(
          NetworkFrame(
            sent: false,
            timestamp: (params['timestamp'] as num?)?.toDouble() ?? 0,
            opcode: 1,
            payload: params['data'] as String? ?? '',
            event: params['eventName'] as String?,
          ),
        );
      case 'Page.javascriptDialogOpening' when session == null:
        _dialogOpened(tab, records, params);
      case 'Page.javascriptDialogClosed' when session == null:
        records.openDialog
          ?..answer = params['result'] == true ? 'accepted' : 'dismissed'
          ..by = 'the user';
        records.openDialog = null;
      case 'Page.downloadWillBegin':
        records.downloads.add(
          BrowserDownload(
            params['guid'] as String? ?? '',
            params['url'] as String? ?? '',
            params['suggestedFilename'] as String? ?? '',
          ),
        );
        if (records.downloads.length > 50) records.downloads.removeAt(0);
        _added.add((tab, records.downloads.last));
      case 'Page.downloadProgress':
        for (final download in records.downloads) {
          if (download.guid != params['guid']) continue;
          download
            ..state = params['state'] as String? ?? download.state
            ..total = (params['totalBytes'] as num?)?.toInt() ?? download.total
            ..received =
                (params['receivedBytes'] as num?)?.toInt() ?? download.received;
        }
      case 'CSS.styleSheetAdded' when session == null:
        final header = (params['header'] as Map).cast<String, Object?>();
        records.styleSheets[header['styleSheetId'] as String] = header;
      case 'CSS.styleSheetRemoved' when session == null:
        records.styleSheets.remove(params['styleSheetId']);
    }
  }

  void _log(BrowserTab tab, _TabRecords records, ConsoleEntry entry) {
    records.log(entry);
    _added.add((tab, entry));
  }

  void _dialogOpened(
    BrowserTab tab,
    _TabRecords records,
    Map<String, Object?> params,
  ) {
    final dialog = BrowserDialog(
      type: params['type'] as String? ?? 'alert',
      message: params['message'] as String? ?? '',
      url: params['url'] as String? ?? '',
      defaultPrompt: params['defaultPrompt'] as String?,
    );
    records.dialogs.add(dialog);
    if (records.dialogs.length > 50) records.dialogs.removeAt(0);
    _added.add((tab, dialog));
    final asked = records.answer;
    if (asked != null && !asked.always) records.answer = null;
    // Asked how, else while an agent acts; else the user's to answer.
    final accept =
        asked?.accept ??
        (records.acting > 0
            ? dialog.type == 'alert' || dialog.type == 'beforeunload'
            : null);
    if (accept == null) {
      records.openDialog = dialog;
      return;
    }
    dialog
      ..answer = accept ? 'accepted' : 'dismissed'
      ..by = asked == null ? 'Caocode' : 'browser_dialog';
    unawaited(
      tab.browser
          .cdp(tab.tabId, 'Page.handleJavaScriptDialog', {
            'accept': accept,
            if (accept && dialog.type == 'prompt')
              'promptText': asked?.text ?? dialog.defaultPrompt ?? '',
          })
          .then<void>(
            (_) {},
            onError: (Object _) {
              dialog.answer = null;
              records.openDialog = dialog;
            },
          ),
    );
  }
}

class _TabRecords {
  Future<void>? watching;
  DateTime? since;
  final List<ConsoleEntry> console = [];
  final Map<String, NetworkRequest> requests = {};
  int redirects = 0;

  /// What the wire said of a request before the request itself was told.
  final Map<String, Map<String, Object?>> extraRequest = {};
  final Map<String, Map<String, Object?>> extraResponse = {};

  final Map<String, ({String type, String url})> sessions = {};
  final Map<String, Map<String, Object?>> styleSheets = {};
  final List<BrowserDialog> dialogs = [];
  BrowserDialog? openDialog;
  ({bool accept, String? text, bool always})? answer;
  int acting = 0;
  final List<BrowserDownload> downloads = [];

  /// The requests whose response bodies are kept, oldest first, and their
  /// size all together.
  final List<NetworkRequest> bodies = [];
  int kept = 0;

  /// Where a session's events come from, for its console's lines: a frame
  /// of another site's, a worker's; null for the page's own.
  String? where(String? session) {
    if (session == null) return null;
    final s = sessions[session];
    if (s == null) return 'frame';
    return '${s.type == 'iframe' ? 'frame' : s.type} ${s.url}';
  }

  void early(
    Map<String, Map<String, Object?>> map,
    String id,
    Map<String, Object?> headers,
  ) {
    map[id] = headers;
    if (map.length > 200) map.remove(map.keys.first);
  }

  void keep(NetworkRequest request) {
    bodies.add(request);
    kept += request.body!.length;
    while (kept > BrowserRecords._maxBodies) {
      final old = bodies.removeAt(0);
      kept -= old.body?.length ?? 0;
      old.body = null;
    }
  }

  void clearRequests() {
    requests.clear();
    for (final request in bodies) {
      request.body = null;
    }
    bodies.clear();
    kept = 0;
  }

  void log(ConsoleEntry entry) {
    console.add(entry);
    if (console.length > BrowserRecords._maxConsole) console.removeAt(0);
  }

  void add(NetworkRequest request) {
    requests[request.id] = request;
    if (requests.length > BrowserRecords._maxRequests) {
      requests.remove(requests.keys.first);
    }
  }
}

/// A place in a script, as the protocol says it (line and column from 0).
class ScriptFrame {
  const ScriptFrame(
    this.function,
    this.url,
    this.line,
    this.column, [
    this.scriptId,
  ]);

  final String function;
  final String url;
  final int line;
  final int column;
  final String? scriptId;

  static List<ScriptFrame> stackOf(Object? stackTrace, {int max = 10}) {
    final frames = <ScriptFrame>[];
    var trace = stackTrace as Map?;
    while (trace != null && frames.length < max) {
      for (final f in (trace['callFrames'] as List? ?? const []).cast<Map>()) {
        if (frames.length >= max) break;
        frames.add(
          ScriptFrame(
            f['functionName'] as String? ?? '',
            f['url'] as String? ?? '',
            (f['lineNumber'] as num?)?.toInt() ?? 0,
            (f['columnNumber'] as num?)?.toInt() ?? 0,
            f['scriptId'] as String?,
          ),
        );
      }
      // An async one's: what scheduled it (a timer, a promise).
      trace = trace['parent'] as Map?;
    }
    return frames;
  }

  /// The calls of an error's stack (V8's text: `    at fn (url:12:5)`).
  static List<ScriptFrame> parse(String stack, {int max = 10}) {
    final frames = <ScriptFrame>[];
    final call = RegExp(r'^\s+at (?:(.+?) \()?(.+?):(\d+):(\d+)\)?$');
    for (final line in stack.split('\n')) {
      final m = call.firstMatch(line);
      if (m == null) continue;
      frames.add(
        ScriptFrame(
          (m[1] ?? '').replaceFirst('async ', ''),
          m[2]!,
          int.parse(m[3]!) - 1,
          int.parse(m[4]!) - 1,
        ),
      );
      if (frames.length >= max) break;
    }
    return frames;
  }

  /// `fetchData (https://site/app.js:12:5)`, lines from 1.
  @override
  String toString() =>
      '${function.isEmpty ? '(anonymous)' : function} '
      '(${url.isEmpty ? '(no url)' : url}:${line + 1}:${column + 1})';
}

/// A line of a page's console: a `console.…` call's, an exception's, the
/// browser's own (a blocked request, a violation).
class ConsoleEntry {
  ConsoleEntry({
    required this.level,
    required this.text,
    this.url,
    this.line,
    required this.time,
    this.stack = const [],
    this.thrown = const [],
    this.from,
  });

  /// `log`, `info`, `warning`, `error`, `debug`.
  final String level;
  final String text;
  final String? url;
  final int? line;
  final DateTime time;

  /// Where it was logged from (an error's, a warning's): the calls.
  final List<ScriptFrame> stack;

  /// Where an error it logged was thrown (`console.error(e)`): its calls.
  final List<ScriptFrame> thrown;

  /// A frame of another site's or a worker's (`worker https://…`); null
  /// for the page's own.
  final String? from;

  /// One-based, as the console shows it (the protocol's are zero-based).
  static int? _line(Object? line) => line is int ? line + 1 : null;

  static DateTime _time(Object? millis) => millis is num
      ? DateTime.fromMillisecondsSinceEpoch(millis.round())
      : DateTime.now();

  factory ConsoleEntry.fromConsole(Map<String, Object?> params, String? from) {
    final args = (params['args'] as List? ?? const []).cast<Map>();
    final frames = ((params['stackTrace'] as Map?)?['callFrames'] as List?)
        ?.cast<Map>();
    final type = params['type'] as String? ?? 'log';
    final level = switch (type) {
      'warning' => 'warning',
      'error' || 'assert' => 'error',
      'debug' => 'debug',
      'info' => 'info',
      _ => 'log',
    };
    final error = args.where((a) => a['subtype'] == 'error').firstOrNull;
    return ConsoleEntry(
      level: level,
      text: args.map(_remote).join(' '),
      thrown: error == null
          ? const []
          : ScriptFrame.parse('${error['description'] ?? ''}'),
      url: frames?.firstOrNull?['url'] as String?,
      line: _line(frames?.firstOrNull?['lineNumber']),
      time: _time(params['timestamp']),
      stack: level == 'error' || level == 'warning' || type == 'trace'
          ? ScriptFrame.stackOf(params['stackTrace'])
          : const [],
      from: from,
    );
  }

  factory ConsoleEntry.fromException(
    Map<String, Object?> params,
    String? from,
  ) {
    final details = (params['exceptionDetails'] as Map).cast<String, Object?>();
    final exception = details['exception'] as Map?;
    final stack = ScriptFrame.stackOf(details['stackTrace']);
    var text =
        '${exception?['description'] ?? details['text'] ?? 'Uncaught exception'}';
    // Its stack told apart: mapped to the sources when shown.
    if (stack.isNotEmpty) {
      final at = text.indexOf(RegExp(r'\n\s+at '));
      if (at > 0) text = text.substring(0, at);
    }
    return ConsoleEntry(
      level: 'error',
      text: text,
      url: details['url'] as String?,
      line: _line(details['lineNumber']),
      time: _time(params['timestamp']),
      stack: stack,
      from: from,
    );
  }

  factory ConsoleEntry.fromLog(Map<String, Object?> params, String? from) {
    final entry = (params['entry'] as Map).cast<String, Object?>();
    return ConsoleEntry(
      level: switch (entry['level']) {
        'warning' => 'warning',
        'error' => 'error',
        'verbose' => 'debug',
        _ => 'info',
      },
      text: '${entry['text'] ?? ''}',
      url: entry['url'] as String?,
      line: _line(entry['lineNumber']),
      time: _time(entry['timestamp']),
      stack: ScriptFrame.stackOf(entry['stackTrace']),
      from: from,
    );
  }

  /// A logged value, as the console writes it in a line.
  static String _remote(Map arg) {
    // An error as it says itself, its calls apart (see [thrown]).
    if (arg['subtype'] == 'error' && arg['description'] is String) {
      final text = arg['description'] as String;
      final at = text.indexOf(RegExp(r'\n\s+at '));
      return at > 0 ? text.substring(0, at) : text;
    }
    if (arg.containsKey('value')) {
      final value = arg['value'];
      return value is String ? value : '$value';
    }
    if (arg['unserializableValue'] case final String value) return value;
    if (arg['preview'] case final Map preview) return previewText(preview);
    return '${arg['description'] ?? arg['className'] ?? arg['type']}';
  }

  /// An object's preview, as the console shows it folded: `{n: 1, s: 'a'}`,
  /// `[1, 2]`.
  static String previewText(Map preview) {
    final properties = (preview['properties'] as List? ?? const []).cast<Map>();
    final array = preview['subtype'] == 'array';
    final items = [
      for (final p in properties)
        array
            ? '${p['value'] ?? p['type']}'
            : '${p['name']}: ${p['type'] == 'string' ? "'${p['value']}'" : p['value'] ?? p['type']}',
      if (preview['overflow'] == true) '…',
    ].join(', ');
    return array ? '[$items]' : '{$items}';
  }
}

/// A message of a WebSocket's (sent or received), or an EventSource's.
class NetworkFrame {
  NetworkFrame({
    required this.sent,
    required this.timestamp,
    required this.opcode,
    required String payload,
    this.event,
    this.error,
  }) : length = payload.length,
       payload = payload.length > BrowserRecords._maxFrame
           ? payload.substring(0, BrowserRecords._maxFrame)
           : payload;

  final bool sent;

  /// The browser's clock, seconds.
  final double timestamp;

  /// 1 text, 2 binary (base64), 8 close, 9 ping, 10 pong; -1 an error.
  final int opcode;
  final String payload;

  /// The payload's whole length (it is kept up to a size).
  final int length;

  /// An EventSource message's event name.
  final String? event;
  final String? error;
}

/// A request a page made, and what came back.
class NetworkRequest {
  NetworkRequest._({
    required this.id,
    required this.method,
    required this.url,
    required this.type,
    required this.start,
    required this.wall,
    required this.requestHeaders,
    required this.hasPostData,
    this.postData,
    this.initiator,
    this.sessionId,
  });

  factory NetworkRequest.fromSent(
    Map<String, Object?> params, [
    String? sessionId,
  ]) {
    final request = (params['request'] as Map).cast<String, Object?>();
    return NetworkRequest._(
      id: params['requestId'] as String,
      method: request['method'] as String? ?? 'GET',
      url: request['url'] as String? ?? '',
      type: params['type'] as String? ?? 'Other',
      start: (params['timestamp'] as num?)?.toDouble() ?? 0,
      wall:
          (params['wallTime'] as num?)?.toDouble() ??
          DateTime.now().millisecondsSinceEpoch / 1000,
      requestHeaders: (request['headers'] as Map? ?? const {})
          .cast<String, Object?>(),
      hasPostData: request['hasPostData'] == true,
      postData: request['postData'] as String?,
      initiator: (params['initiator'] as Map?)?.cast<String, Object?>(),
      sessionId: sessionId,
    );
  }

  factory NetworkRequest.socket(
    String id,
    String url,
    Map<String, Object?>? initiator,
    String? sessionId,
  ) => NetworkRequest._(
    id: id,
    method: 'GET',
    url: url,
    type: 'WebSocket',
    start: 0,
    wall: DateTime.now().millisecondsSinceEpoch / 1000,
    requestHeaders: const {},
    hasPostData: false,
    initiator: initiator,
    sessionId: sessionId,
  );

  /// The browser's, as DevTools has it (a redirect's with a suffix).
  String id;
  final String method;
  final String url;

  /// DevTools' resource type: `Document`, `XHR`, `Fetch`, `Script`…
  String type;

  /// The browser's clock, seconds.
  double start;

  /// When it was sent: seconds since the epoch.
  double wall;
  double? end;
  final Map<String, Object?> requestHeaders;
  final bool hasPostData;
  final String? postData;

  /// What made it: `{type: parser | script | preload | other, url,
  /// lineNumber, stack}`.
  final Map<String, Object?>? initiator;

  /// A frame's or a worker's session it went through; null for the page's.
  final String? sessionId;

  /// The headers as they went and came on the wire (cookies, Set-Cookie):
  /// over [requestHeaders] and [responseHeaders] where told.
  Map<String, Object?>? wireRequestHeaders;
  Map<String, Object?>? wireResponseHeaders;

  Map<String, Object?> get sentHeaders => wireRequestHeaders ?? requestHeaders;
  Map<String, Object?>? get receivedHeaders =>
      wireResponseHeaders ?? responseHeaders;

  int? status;
  String? statusText;
  String? mimeType;
  Map<String, Object?>? responseHeaders;
  bool fromCache = false;
  bool fromServiceWorker = false;

  /// `h2`, `http/1.1`…, and the server's address.
  String? protocol;
  String? remoteAddress;

  /// Its phases (the protocol's ResourceTiming: ms after `requestTime`).
  Map<String, Object?>? timing;

  /// Bytes over the network, once finished.
  int? size;
  bool finished = false;

  /// Why it failed, if it did.
  String? failure;

  /// Its response's body, kept as it finished (see BrowserRecords): base64
  /// if [bodyBase64].
  String? body;
  bool bodyBase64 = false;

  /// A WebSocket's or an EventSource's messages, the last of them, and
  /// how many came before those.
  final List<NetworkFrame> frames = [];
  int framesDropped = 0;

  void respond(Map<String, Object?> response) {
    status = (response['status'] as num?)?.toInt();
    statusText = response['statusText'] as String?;
    mimeType = response['mimeType'] as String?;
    responseHeaders = (response['headers'] as Map? ?? const {})
        .cast<String, Object?>();
    fromServiceWorker = response['fromServiceWorker'] == true;
    fromCache =
        response['fromDiskCache'] == true ||
        response['fromPrefetchCache'] == true ||
        fromServiceWorker;
    protocol = response['protocol'] as String?;
    if (response['remoteIPAddress'] case final String ip when ip.isNotEmpty) {
      remoteAddress = '$ip:${response['remotePort'] ?? ''}';
    }
    timing = (response['timing'] as Map?)?.cast<String, Object?>();
  }

  void addFrame(NetworkFrame frame) {
    frames.add(frame);
    size = (size ?? 0) + frame.length;
    if (frames.length > BrowserRecords._maxFrames) {
      frames.removeAt(0);
      framesDropped++;
    }
  }

  /// When [frame] came: seconds since the epoch.
  double wallOf(NetworkFrame frame) =>
      start > 0 ? wall + frame.timestamp - start : wall;

  /// How long it took, in milliseconds, once finished.
  int? get duration => end == null || start <= 0
      ? null
      : ((end! - start) * 1000).round().clamp(0, 1 << 31);
}

/// A dialog a page opened (`alert`, `confirm`, `prompt`, `beforeunload`),
/// and how it was answered.
class BrowserDialog {
  BrowserDialog({
    required this.type,
    required this.message,
    required this.url,
    this.defaultPrompt,
  }) : time = DateTime.now();

  final String type;
  final String message;
  final String url;
  final String? defaultPrompt;
  final DateTime time;

  /// `accepted`, `dismissed`; null while it is open.
  String? answer;

  /// Who answered: `Caocode` (while an agent acted), `browser_dialog`,
  /// `the user`.
  String? by;

  String describe() =>
      'A $type dialog said "${message.length > 200 ? '${message.substring(0, 200)}…' : message}"'
      '${answer == null ? ': it is open, the page waits on it' : ': $answer${by == null ? '' : ' by $by'}'}.';
}

/// A file a page downloaded (to the browser's download folder).
class BrowserDownload {
  BrowserDownload(this.guid, this.url, this.name) : time = DateTime.now();

  final String guid;
  final String url;
  final String name;
  final DateTime time;

  /// `inProgress`, `completed`, `canceled`.
  String state = 'inProgress';
  int total = 0;
  int received = 0;
}
