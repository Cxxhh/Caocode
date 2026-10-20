part of 'browser_tools.dart';

// The agents' way to watch the user: browser_watch records what the user
// does in a shared tab (their clicks, what they type, the pages they go to)
// and what the page says meanwhile (errors, failed requests), until they
// say they are done (in the conversation, or with the toolbar button); the
// call waits on them. The page tells its events through a binding
// (Runtime.addBinding), its listeners put in each document it loads.

/// The longest a call waits on the user: then it answers that they are
/// still at it, for the agent to call again (a tool's call may not take
/// forever), the recording going on.
const _watchWait = Duration(minutes: 10);

/// The longest a recording goes on.
const _watchLimit = Duration(minutes: 30);

/// The binding the page's listeners call.
const _watchBinding = '__baoWatchStep';

/// What the user does in a shared tab, recorded as Caocode watches them
/// (an agent's browser_watch): the conversation shows it, and its buttons
/// say they are done or give up.
class BrowserWatching extends ChangeNotifier {
  BrowserWatching._(this.tab, this.task, this.started);

  final BrowserTab tab;

  /// What the agent asked the user to do.
  final String task;
  final DateTime started;

  /// What they did so far.
  List<WatchedStep> get steps => List.unmodifiable(_steps);
  final List<WatchedStep> _steps = [];

  /// The recording now: one at a time.
  static final current = ValueNotifier<BrowserWatching?>(null);

  final _ended = Completer<bool>();
  StreamSubscription<BrowserEvent>? _events;
  String? _script;
  Timer? _limit;
  int _shots = 0;

  bool get ended => _ended.isCompleted;

  /// The user is done: the agent is told what they did.
  void finish() => _end(true);

  /// The user gives up (or the call is): the agent is told so.
  void cancel() => _end(false);

  void _end(bool finished) {
    if (_ended.isCompleted) return;
    _ended.complete(finished);
    _limit?.cancel();
    unawaited(_events?.cancel());
    if (current.value == this) current.value = null;
    unawaited(_unhook());
    notifyListeners();
  }

  /// Starts watching the user in [tab].
  static Future<BrowserWatching> start(BrowserTab tab, String task) async {
    if (current.value case final other? when !other.ended) {
      throw StateError(
        'Already watching the user in tab ${other.tab.tabId}: wait for it '
        '(browser_watch with that tab) first.',
      );
    }
    final watching = BrowserWatching._(tab, task, DateTime.now());
    watching._events = BrowserBridge.instance.events.listen(watching._received);
    final browser = tab.browser;
    await browser.cdp(tab.tabId, 'Runtime.addBinding', {'name': _watchBinding});
    final added = await browser.cdp(
      tab.tabId,
      'Page.addScriptToEvaluateOnNewDocument',
      {'source': _watchScript},
    );
    watching._script = added['identifier'] as String?;
    await browser.cdp(tab.tabId, 'Runtime.evaluate', {
      'expression': _watchScript,
    });
    final page = await BrowserTools._tab(browser, tab.tabId);
    watching._add(
      WatchedStep(
        kind: 'page',
        at: Duration.zero,
        target: page?['title'] as String? ?? '',
        value: page?['url'] as String?,
      ),
    );
    unawaited(_badge(tab, on: true));
    watching._limit = Timer(_watchLimit, watching.finish);
    current.value = watching;
    return watching;
  }

  static Future<void> _badge(BrowserTab tab, {required bool on}) async {
    try {
      await tab.browser.request('watch', {'tabId': on ? tab.tabId : null});
    } on Object {
      // An older extension: no badge.
    }
  }

  Future<void> _unhook() async {
    final browser = tab.browser;
    await _badge(tab, on: false);
    for (final (method, params) in [
      ('Runtime.evaluate', {'expression': 'window.__baoWatch?.stop()'}),
      ('Runtime.removeBinding', {'name': _watchBinding}),
      if (_script case final id?)
        ('Page.removeScriptToEvaluateOnNewDocument', {'identifier': id}),
    ]) {
      try {
        await browser.cdp(tab.tabId, method, params);
      } on Object {
        // The tab is gone: so is all of it.
      }
    }
  }

  /// Whether the user is done ([finish]: true) or gave up; [wait] at most.
  Future<bool?> wait(Duration wait, Future<void>? cancelled) {
    final done = Completer<bool?>();
    void settle(bool? value) {
      if (!done.isCompleted) done.complete(value);
    }

    unawaited(_ended.future.then(settle));
    final timer = Timer(wait, () => settle(null));
    unawaited(cancelled?.then((_) => cancel()));
    return done.future.whenComplete(timer.cancel);
  }

  void _add(WatchedStep step) {
    // Typing on in a field, scrolling on: one step, its last.
    final last = _steps.lastOrNull;
    if (last != null &&
        (step.kind == 'input' || step.kind == 'scroll') &&
        last.kind == step.kind &&
        last.selector == step.selector) {
      _steps.removeLast();
    }
    _steps.add(step);
    notifyListeners();
  }

  Duration get _now => DateTime.now().difference(started);

  void _received(BrowserEvent event) {
    if (!identical(event.connection, tab.browser)) return;
    if (event.event == 'watchDone') return finish();
    if (event.tabId != tab.tabId) return;
    if (event.event == 'closed' || event.event == 'unshared') {
      _add(WatchedStep(kind: 'closed', at: _now, target: ''));
      return finish();
    }
    // The page's own: not its frames' of other sites.
    if (event.event != 'cdp' || event.message['sessionId'] != null) return;
    final params = (event.message['params'] as Map?) ?? const {};
    switch (event.message['method']) {
      case 'Runtime.bindingCalled' when params['name'] == _watchBinding:
        final Map step;
        try {
          step = jsonDecode(params['payload'] as String) as Map;
        } on Object {
          return;
        }
        // When the page says (the requests it made are told sooner than
        // the step).
        var at = _now;
        if (step['time'] case final num time) {
          final then = DateTime.fromMillisecondsSinceEpoch(time.round())
              .difference(started);
          if (then >= Duration.zero && then < at) at = then;
        }
        final watched = WatchedStep(
          kind: step['type'] as String? ?? 'click',
          at: at,
          target: step['target'] as String? ?? '',
          selector: step['selector'] as String?,
          value: step['value'] as String?,
          role: step['role'] as String?,
          label: step['label'] as String?,
        );
        _add(watched);
        if (watched.kind == 'click' || watched.kind == 'submit') {
          unawaited(_shoot(watched));
        }
      case 'Page.frameNavigated':
        final frame = (params['frame'] as Map?) ?? const {};
        final url = frame['url'] as String? ?? '';
        if (frame['parentId'] != null || url == 'about:blank') return;
        final step = WatchedStep(
          kind: 'navigate',
          at: _now,
          target: '',
          value: url,
        );
        _add(step);
        unawaited(_shoot(step, after: const Duration(milliseconds: 1200)));
    }
  }

  /// What the page shows a moment after [step]: what it led to.
  Future<void> _shoot(
    WatchedStep step, {
    Duration after = const Duration(milliseconds: 600),
  }) async {
    if (_shots >= 40) return;
    _shots++;
    await Future<void>.delayed(after);
    if (ended) return;
    try {
      step.screenshot = await BrowserTools.screenshot(tab.browser, tab.tabId);
    } on Object {
      // Between pages: none.
    }
  }

  /// What the agent is told: the steps, what went wrong after each, and
  /// pictures of what some led to.
  Future<List<Object?>> report({required bool finished}) async {
    final records = BrowserRecords.instance;
    final start = started;
    const calls = {'XHR', 'Fetch', 'WebSocket', 'EventSource', 'Document'};
    final requests = [
      for (final r in records.requests(tab))
        if (r.wall * 1000 >= start.millisecondsSinceEpoch &&
            calls.contains(r.type))
          r,
    ];
    final errors = [
      for (final entry in records.console(tab))
        if (!entry.time.isBefore(start) &&
            (entry.level == 'error' || entry.level == 'warning'))
          (
            time: entry.time,
            text:
                '${entry.level}: ${_clip(entry.text, 300)}'
                '${entry.url == null || entry.url!.isEmpty ? '' : ' (${entry.url}${entry.line == null ? '' : ':${entry.line}'})'}',
          ),
      for (final request in records.requests(tab))
        if (request.wall * 1000 >= start.millisecondsSinceEpoch &&
            !calls.contains(request.type) &&
            (request.failure != null || (request.status ?? 0) >= 400))
          (
            time: DateTime.fromMillisecondsSinceEpoch(
              (request.wall * 1000).round(),
            ),
            text:
                'request ${request.method} ${request.status ?? request.failure} '
                '${_clip(request.url, 200)} (${request.id})',
          ),
    ]..sort((a, b) => a.time.compareTo(b.time));
    // Each after the step it followed.
    int stepAt(DateTime time) {
      final at = time.difference(start);
      var index = 0;
      for (var i = 0; i < _steps.length; i++) {
        if (_steps[i].at <= at) index = i;
      }
      return index;
    }

    final after = <int, List<String>>{};
    for (final error in errors) {
      (after[stepAt(error.time)] ??= []).add(error.text);
    }
    // The requests to the server each step made: what it did.
    final made = <int, List<NetworkRequest>>{};
    for (final r in requests) {
      final time = DateTime.fromMillisecondsSinceEpoch((r.wall * 1000).round());
      (made[stepAt(time)] ??= []).add(r);
    }
    String seconds(Duration d) =>
        '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    final lines = [
      finished
          ? 'The user is done (${seconds(_now)}).'
          : 'The user gave up (${seconds(_now)}): what they did so far.',
      'Steps (time since watching began):',
      for (final (i, step) in _steps.indexed) ...[
        '${i + 1}. [${seconds(step.at)}] ${step.describe()}',
        for (final r in (made[i] ?? const <NetworkRequest>[]).take(8))
          '   ${r.failure != null || (r.status ?? 0) >= 400 ? '!' : '→'} '
              '${r.method} ${_clip(r.url, 160)} ${r.status ?? r.failure ?? 'pending'} '
              '(${r.type}, ${r.id})',
        if ((made[i]?.length ?? 0) > 8)
          '   … ${made[i]!.length - 8} more (browser_network)',
        for (final error in after[i] ?? const <String>[]) '   ! $error',
      ],
    ];
    if (requests.isNotEmpty) {
      lines.add(
        'Read a request with browser_request (its id); all of them: '
        'browser_network save.',
      );
    }
    // As something to do again: browser_act's steps.
    final act = _actSteps();
    if (act.length > 1) {
      lines
        ..add('')
        ..add(
          'To do it again: browser_act with steps ${_clip(jsonEncode(act), 6000)}',
        );
    }
    // Pictures: of what went wrong first, then of the last; four at most.
    final shot = [
      for (final (i, step) in _steps.indexed)
        if (step.screenshot != null && after.containsKey(i)) i,
    ];
    for (var i = _steps.length - 1; i >= 0 && shot.length < 3; i--) {
      if (_steps[i].screenshot != null && !shot.contains(i)) shot.add(i);
    }
    shot.sort();
    final blocks = <Object?>[claudeSdkText(lines.join('\n'))];
    for (final i in shot.take(3)) {
      blocks
        ..add(claudeSdkText('After step ${i + 1}:'))
        ..add(_steps[i].screenshot!);
    }
    try {
      final now = await BrowserTools.screenshot(tab.browser, tab.tabId);
      blocks
        ..add(claudeSdkText('The page now:'))
        ..add(now);
    } on Object {
      // Closed: no page now.
    }
    return blocks;
  }

  /// Whether [i]'s navigation followed from the step before it (a click, a
  /// key): not one to do again.
  bool _followed(int i) {
    if (i == 0) return false;
    final before = _steps[i - 1];
    return const {'click', 'key', 'submit', 'input'}.contains(before.kind) &&
        _steps[i].at - before.at < const Duration(seconds: 4);
  }

  /// The steps as browser_act's, to do again.
  List<Map<String, Object?>> _actSteps() {
    Map<String, Object?> aim(WatchedStep s, {String key = 'text'}) =>
        s.label != null && s.label!.isNotEmpty && s.role != null
        ? {key: s.label, 'role': s.role}
        : {'selector': s.selector};
    return [
      for (final (i, s) in _steps.indexed)
        ?switch (s.kind) {
          'page' => {'action': 'navigate', 'url': s.value},
          'navigate' when !_followed(i) => {
            'action': 'navigate',
            'url': s.value,
          },
          'click' => {'action': 'click', ...aim(s)},
          'input' when s.role == 'textbox' || s.role == 'searchbox' => {
            'action': 'type',
            'text': s.value == '(hidden)' ? '<the password>' : s.value,
            ...aim(s, key: 'into'),
          },
          'input' => {'action': 'click', ...aim(s)},
          'key' => {'action': 'press', 'key': s.value},
          _ => null,
        },
    ];
  }

  /// The page's listeners: what the user does, told through the binding.
  /// Their own doings alone (trusted events), a password never.
  static const _watchScript = r'''
(() => {
  if (window.__baoWatch || typeof window.__baoWatchStep !== 'function') return;
  const send = (step) => { try { window.__baoWatchStep(JSON.stringify({ ...step, time: Date.now() })); } catch (e) {} };
  const clip = (t, n) => { t = (t || '').replace(/\s+/g, ' ').trim(); return t.length > n ? t.slice(0, n) + '…' : t; };
  const field = (e) => ['INPUT', 'TEXTAREA', 'SELECT'].includes(e.tagName);
  const labelOf = (e) => clip(e.getAttribute('aria-label') ||
      (field(e) ? (e.labels && e.labels[0] && e.labels[0].innerText) || e.getAttribute('placeholder') || e.getAttribute('name') : e.innerText) ||
      e.getAttribute('title') || e.getAttribute('alt') || '', 60);
  const name = (e) => {
    const kind = e.getAttribute('role') || (e.tagName === 'INPUT' ? `input[${e.type}]` : e.tagName.toLowerCase());
    const label = labelOf(e);
    return label ? `${kind} ${JSON.stringify(label)}` : kind;
  };
  // Its ARIA role, as a test finds it.
  const roleOf = (e) => {
    const r = e.getAttribute('role');
    if (r) return r;
    const tag = e.tagName.toLowerCase();
    if (tag === 'input') {
      if (['checkbox', 'radio', 'file'].includes(e.type)) return e.type;
      if (['button', 'submit', 'reset', 'image'].includes(e.type)) return 'button';
      return e.type === 'search' ? 'searchbox' : 'textbox';
    }
    if (tag === 'textarea' || e.isContentEditable) return 'textbox';
    if (tag === 'select') return 'combobox';
    if (tag === 'a') return 'link';
    if (tag === 'button' || tag === 'summary') return 'button';
    return tag;
  };
  const selector = (e) => {
    if (e.id) return '#' + CSS.escape(e.id);
    for (const a of ['data-testid', 'data-test', 'name', 'aria-label']) {
      const v = e.getAttribute(a);
      if (v) return `${e.tagName.toLowerCase()}[${a}=${JSON.stringify(v)}]`;
    }
    // Up to an id or the body, four at most; a place among its kind only
    // where there are more.
    const path = [];
    for (let n = e; n && n.nodeType === 1 && path.length < 4; n = n.parentElement) {
      if (n.id) { path.unshift('#' + CSS.escape(n.id)); break; }
      const tag = n.tagName.toLowerCase();
      if (tag === 'body' || tag === 'html') { path.unshift('body'); break; }
      const kin = n.parentElement ? Array.from(n.parentElement.children).filter((s) => s.tagName === n.tagName) : [n];
      path.unshift(kin.length > 1 ? `${tag}:nth-of-type(${kin.indexOf(n) + 1})` : tag);
    }
    return path.join(' > ');
  };
  const actionable = 'a, button, input, select, textarea, label, summary, [role], [onclick], [contenteditable=""], [contenteditable=true]';
  const target = (e) => (e && e.closest && e.closest(actionable)) || e;
  const about = (e) => ({ target: name(e), selector: selector(e), role: roleOf(e), label: labelOf(e) });
  // What is typed, told once the typing stops (or something else is done).
  const typed = (e) => field(e) && !['checkbox', 'radio', 'file'].includes(e.type) && e.tagName !== 'SELECT';
  const editable = (e) => { while (e.parentElement && e.parentElement.isContentEditable) e = e.parentElement; return e; };
  const pending = new Map();
  const valueOf = (e) => e.isContentEditable ? clip(e.innerText, 300) : e.type === 'password' ? '(hidden)' : clip(e.value, 300);
  const flush = (e) => {
    if (!pending.has(e)) return;
    clearTimeout(pending.get(e));
    pending.delete(e);
    send({ type: 'input', ...about(e), value: valueOf(e) });
  };
  const flushAll = () => { for (const e of Array.from(pending.keys())) flush(e); };
  const scrolls = new Map();
  const listeners = {
    input: (ev) => {
      if (!ev.isTrusted || !(ev.target instanceof Element)) return;
      let e = ev.target;
      if (e.isContentEditable) e = editable(e);
      else if (!typed(e)) return;
      clearTimeout(pending.get(e));
      pending.set(e, setTimeout(() => flush(e), 800));
    },
    click: (ev) => {
      if (!ev.isTrusted || !(ev.target instanceof Element)) return;
      flushAll();
      const e = target(ev.target);
      // A field's own click: what is typed in it says more.
      if (field(e) && !['checkbox', 'radio', 'submit', 'button', 'file'].includes(e.type)) return;
      if (e.isContentEditable) return;
      send({ type: 'click', ...about(e) });
    },
    change: (ev) => {
      const e = ev.target;
      if (!ev.isTrusted || !(e instanceof Element) || !field(e)) return;
      if (typed(e)) return flush(e);
      const value = e.type === 'checkbox' || e.type === 'radio' ? (e.checked ? 'checked' : 'unchecked')
        : e.tagName === 'SELECT' ? (e.selectedOptions[0] ? e.selectedOptions[0].text : '')
        : e.type === 'file' ? Array.from(e.files || []).map((f) => f.name).join(', ')
        : clip(e.value, 300);
      send({ type: 'input', ...about(e), value });
    },
    scroll: (ev) => {
      if (!ev.isTrusted) return;
      const e = ev.target instanceof Element && ev.target !== document.scrollingElement ? ev.target : null;
      const key = e || document;
      clearTimeout(scrolls.get(key));
      scrolls.set(key, setTimeout(() => {
        scrolls.delete(key);
        send(e ? { type: 'scroll', target: name(e), selector: selector(e), value: String(Math.round(e.scrollTop)) }
          : { type: 'scroll', target: 'page', selector: 'page', value: String(Math.round(scrollY)) });
      }, 600));
    },
    drop: (ev) => {
      if (!ev.isTrusted || !(ev.target instanceof Element)) return;
      const files = ev.dataTransfer && ev.dataTransfer.files ? Array.from(ev.dataTransfer.files).map((f) => f.name).join(', ') : '';
      send({ type: 'drop', ...about(target(ev.target)), value: files });
    },
    pagehide: () => flushAll(),
    keydown: (ev) => {
      if (!ev.isTrusted || ev.repeat) return;
      const special = ['Enter', 'Escape', 'Tab'].includes(ev.key);
      const command = (ev.metaKey || ev.ctrlKey) && ev.key.length === 1;
      if (!special && !command) return;
      flushAll();
      const key = [ev.ctrlKey && 'Control', ev.altKey && 'Alt', ev.metaKey && 'Meta', ev.shiftKey && 'Shift', ev.key.length === 1 ? ev.key.toUpperCase() : ev.key].filter(Boolean).join('+');
      send({ type: 'key', value: key, target: ev.target instanceof Element ? name(ev.target) : '' });
    },
    submit: (ev) => {
      if (!ev.isTrusted || !(ev.target instanceof Element)) return;
      flushAll();
      send({ type: 'submit', ...about(ev.target) });
    },
  };
  for (const [type, listener] of Object.entries(listeners)) window.addEventListener(type, listener, true);
  window.__baoWatch = {
    stop() {
      flushAll();
      for (const [type, listener] of Object.entries(listeners)) window.removeEventListener(type, listener, true);
      delete window.__baoWatch;
    },
  };
})()
''';
}

/// One thing the user did while watched (or that happened: a page loaded,
/// the tab closed).
class WatchedStep {
  WatchedStep({
    required this.kind,
    required this.at,
    required this.target,
    this.selector,
    this.value,
    this.role,
    this.label,
  });

  /// `page` (where it began), `click`, `input`, `key`, `submit`, `scroll`,
  /// `drop`, `navigate`, `closed`.
  final String kind;

  /// When, since watching began.
  final Duration at;

  /// The element, as a snapshot names it: `button "Sign in"`.
  final String target;

  /// How to find the element again, CSS.
  final String? selector;

  /// What was typed or picked, the key pressed, the URL gone to, how far
  /// it was scrolled.
  final String? value;

  /// The element's ARIA role and its words: how a test finds it again.
  final String? role;
  final String? label;

  /// What the page showed after it (an MCP image), if taken.
  Map<String, Object?>? screenshot;

  /// The step as the agent reads it.
  String describe() {
    final where = selector == null ? '' : ' ($selector)';
    return switch (kind) {
      'page' => 'on ${value ?? ''}${target.isEmpty ? '' : ' — $target'}',
      'click' => 'clicked $target$where',
      'input' => 'set $target$where to ${jsonEncode(value ?? '')}',
      'key' => 'pressed ${value ?? ''}${target.isEmpty ? '' : ' in $target'}',
      'submit' => 'submitted $target$where',
      'scroll' =>
        'scrolled ${target == 'page' ? 'the page' : '$target$where'} to ${value ?? '?'}',
      'drop' =>
        'dropped ${value == null || value!.isEmpty ? 'something' : value} onto $target$where',
      'navigate' => 'went to ${value ?? ''}',
      'closed' => 'closed the tab',
      _ => '$kind $target$where',
    };
  }
}

final _watchTool = ClaudeSdkTool(
  name: 'browser_watch',
  description:
      'Watches the user do something in a shared tab, to see it done '
      '(reproducing a bug, showing a flow), as DevTools\' Recorder: '
      'records their clicks, what they type (never passwords), keys, '
      'scrolls, the pages they go to; under each step, the requests it '
      'made (ids for browser_request) and the errors; pictures of what '
      'some steps led to; and browser_act\'s steps to do it again, in '
      'their own browser. To keep it as a script, write those steps to a '
      '.json file in the project (an array; edit it as wanted), done again '
      'with browser_act\'s file. Waits until they say they are done; they see '
      'your task. Open '
      'or pick the tab first (browser_open, browser_tabs). If the call '
      'answers that the user is still at it, call it again with the same '
      'tab to keep waiting.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'tabId': BrowserTools._tabId,
      'task': {
        'type': 'string',
        'description':
            'What to do, for the user, in their language: e.g. "Sign in '
            'and submit an order, as when the button did nothing".',
      },
    },
    'required': ['tabId', 'task'],
  },
  run: (input, call) async {
    final browser = BrowserTools._browser();
    final tab = BrowserTab(browser, input['tabId'] as int);
    var watching = BrowserWatching.current.value;
    if (watching == null || watching.ended || watching.tab != tab) {
      watching = await BrowserWatching.start(
        tab,
        (input['task'] as String? ?? '').trim(),
      );
    }
    final done = await watching.wait(_watchWait, call.cancelled);
    if (done == null) {
      return 'The user is still at it (${watching.steps.length} steps so far): '
          'call browser_watch again with tab ${tab.tabId} to keep waiting.';
    }
    return watching.report(finished: done);
  },
);
