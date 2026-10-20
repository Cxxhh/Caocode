part of 'browser_tools.dart';

// The agents' Elements and Application panels: an element's styles (the
// rules that set them, where they are, what overrode what), its box, its
// listeners, its accessibility and its component (React, Vue, Angular);
// the page's cookies and storage; and the dialogs it opens.

/// The element [input] names (ref, text with role, near, nth; or a
/// selector), as the protocol holds it, and as an agent reads its name.
Future<({String objectId, String name})> _element(
  BrowserConnection browser,
  int tabId,
  Map<String, Object?> input,
) async {
  final target = _targetOf(input);
  if (target == null) {
    throw const BrowserError(
      'Say which element: ref, text (role, near), or selector.',
    );
  }
  final element = await _find(browser, tabId, target);
  final result = await browser.cdp(tabId, 'Runtime.evaluate', {
    'expression':
        'document.querySelector(\'[data-bao-ref="${element['ref']}"]\')',
  });
  final id = (result['result'] as Map?)?['objectId'] as String?;
  if (id == null) throw BrowserError('${_elementName(element)} went.');
  return (objectId: id, name: _elementName(element));
}

/// The DOM domain's id of the element [objectId] holds.
Future<int> _nodeId(
  BrowserConnection browser,
  int tabId,
  String objectId,
) async {
  await browser.cdp(tabId, 'DOM.enable');
  await browser.cdp(tabId, 'DOM.getDocument', {'depth': 0});
  final node = await browser.cdp(tabId, 'DOM.requestNode', {
    'objectId': objectId,
  });
  final id = (node['nodeId'] as num?)?.toInt() ?? 0;
  if (id == 0) throw const BrowserError('The element is not in the page.');
  return id;
}

/// Runs [function] (`function () {…}`, `this` the object) on [objectId]:
/// its value.
Future<Object?> _callOn(
  BrowserConnection browser,
  int tabId,
  String objectId,
  String function,
) async {
  final result = await browser.cdp(tabId, 'Runtime.callFunctionOn', {
    'objectId': objectId,
    'functionDeclaration': function,
    'returnByValue': true,
    'awaitPromise': true,
  });
  if (result['exceptionDetails'] case final Map details) {
    final exception = details['exception'] as Map?;
    throw BrowserError(
      '${exception?['description'] ?? details['text'] ?? 'It threw.'}',
    );
  }
  return (result['result'] as Map?)?['value'];
}

/// The computed styles told unless others are asked for: what places an
/// element and shows it.
/// What says whether and how an element shows, by its box.
const _computedBrief = [
  'display',
  'position',
  'visibility',
  'opacity',
  'z-index',
  'overflow',
  'pointer-events',
];

const _computedShown = [
  'display',
  'position',
  'top',
  'right',
  'bottom',
  'left',
  'z-index',
  'width',
  'height',
  'min-width',
  'max-width',
  'min-height',
  'max-height',
  'box-sizing',
  'margin',
  'padding',
  'overflow-x',
  'overflow-y',
  'flex-direction',
  'flex-wrap',
  'justify-content',
  'align-items',
  'align-self',
  'flex-grow',
  'flex-shrink',
  'flex-basis',
  'gap',
  'grid-template-columns',
  'grid-template-rows',
  'color',
  'background-color',
  'background-image',
  'opacity',
  'visibility',
  'pointer-events',
  'cursor',
  'font-family',
  'font-size',
  'font-weight',
  'line-height',
  'text-align',
  'white-space',
  'text-overflow',
  'transform',
  'transition',
  'box-shadow',
  'border-radius',
  'border-top-width',
  'border-top-style',
  'border-top-color',
  'outline',
];

/// The properties a child inherits.
const _inherited = {
  'color',
  'cursor',
  'direction',
  'font',
  'font-family',
  'font-size',
  'font-style',
  'font-variant',
  'font-weight',
  'letter-spacing',
  'line-height',
  'list-style',
  'list-style-type',
  'quotes',
  'text-align',
  'text-indent',
  'text-transform',
  'visibility',
  'white-space',
  'word-break',
  'word-spacing',
  'word-wrap',
  'overflow-wrap',
  'pointer-events',
  'user-select',
  '-webkit-font-smoothing',
};

/// What an element is in a framework's terms: its component and those it
/// is in, their props and state.
const _frameworkScript = r'''
function () {
  const seen = new WeakSet();
  const safe = (v, depth) => {
    if (v === null || v === undefined) return v;
    const t = typeof v;
    if (t === 'string') return v.length > 200 ? v.slice(0, 200) + '…' : v;
    if (t === 'number' || t === 'boolean') return v;
    if (t === 'function') return 'ƒ ' + (v.name || 'anonymous');
    if (t === 'symbol' || t === 'bigint') return String(v);
    if (v instanceof Element) return '<' + v.tagName.toLowerCase() + (v.id ? '#' + v.id : '') + '>';
    if (seen.has(v)) return '(circular)';
    if (depth <= 0) return Array.isArray(v) ? '[' + v.length + ' items]' : '{…}';
    seen.add(v);
    if (Array.isArray(v)) {
      const a = v.slice(0, 10).map((x) => safe(x, depth - 1));
      if (v.length > 10) a.push('… ' + (v.length - 10) + ' more');
      return a;
    }
    if (v.$$typeof) return '(React element)';
    const o = {};
    let n = 0;
    for (const k of Object.keys(v)) {
      if (k.startsWith('_') || k === 'children') continue;
      if (n++ >= 20) { o['…'] = 'more'; break; }
      try { o[k] = safe(v[k], depth - 1); } catch (e) { o[k] = '(unreadable)'; }
    }
    return o;
  };
  const out = {};
  const el = this;
  let fiber = null;
  for (let n = el; n && !fiber; n = n.parentElement) {
    const key = Object.keys(n).find((k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
    if (key) fiber = n[key];
  }
  if (fiber) {
    const components = [];
    let props, state;
    for (let f = fiber; f && components.length < 12; f = f.return) {
      const t = f.type;
      if (!t || typeof t === 'string') continue;
      const name = t.displayName || t.name || (t.render && (t.render.displayName || t.render.name)) || (t.type && (t.type.displayName || t.type.name));
      if (!name) continue;
      components.push(name);
      if (props === undefined) {
        props = safe(f.memoizedProps, 2);
        if (f.stateNode && f.stateNode.state) state = safe(f.stateNode.state, 2);
        else if (f.memoizedState && 'memoizedState' in f.memoizedState) {
          const hooks = [];
          for (let h = f.memoizedState; h && hooks.length < 10; h = h.next) {
            if (h.queue) hooks.push(safe(h.memoizedState, 2));
          }
          if (hooks.length) state = hooks;
        }
      }
    }
    out.react = { components, props, state };
  }
  let vue3 = null;
  for (let n = el; n && !vue3; n = n.parentElement) vue3 = n.__vueParentComponent;
  if (vue3) {
    const components = [];
    for (let c = vue3; c && components.length < 12; c = c.parent) {
      const name = c.type && (c.type.name || c.type.__name || (c.type.__file && c.type.__file.split('/').pop()));
      if (name) components.push(name);
    }
    out.vue = { components, props: safe(vue3.props, 2), state: safe(vue3.setupState, 2) };
  } else {
    let vm = null;
    for (let n = el; n && !vm; n = n.parentElement) vm = n.__vue__;
    if (vm) {
      const components = [];
      for (let c = vm; c && components.length < 12; c = c.$parent) {
        const name = c.$options && (c.$options.name || c.$options._componentTag);
        if (name) components.push(name);
      }
      out.vue = { components, props: safe(vm.$props, 2), state: safe(vm.$data, 2) };
    }
  }
  if (window.ng && typeof window.ng.getComponent === 'function') {
    for (let n = el; n; n = n.parentElement) {
      let c = null;
      try { c = window.ng.getComponent(n); } catch (e) {}
      if (c) { out.angular = { components: [c.constructor.name], state: safe(c, 2) }; break; }
    }
  }
  return out;
}
''';

final _inspectTools = [
  ClaudeSdkTool(
    name: 'browser_inspect',
    description:
        "An element of a shared tab, as DevTools' Elements panel shows it: "
        'its HTML; the CSS rules that style it, highest first, each with '
        'its file and line, what they set and what is overridden (struck: '
        '~~); inherited ones; its box (size, padding, border, margin; '
        'display, position, visibility, opacity); its computed styles '
        '(asked: parts "computed", or properties); its event listeners and where their code is '
        '(mapped to the sources), its ancestors\' too; its accessibility '
        '(role, name); and its component (React, Vue, Angular) with props '
        'and state. Change styles or the DOM with browser_evaluate.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        ..._targetProperties,
        'parts': {
          'type': 'array',
          'items': {
            'type': 'string',
            'enum': [
              'html',
              'rules',
              'computed',
              'box',
              'listeners',
              'a11y',
              'component',
            ],
          },
          'description': 'Which (all but computed by default).',
        },
        'properties': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'The computed styles to tell (by default, those of layout and '
              'looks).',
        },
        'userAgent': {
          'type': 'boolean',
          'description': "The browser's own rules too.",
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final browser = BrowserTools._browser();
      final tabId = input['tabId'] as int;
      final tab = BrowserTab(browser, tabId);
      final element = await _element(browser, tabId, input);
      final parts = {
        for (final part in (input['parts'] as List?) ?? const []) '$part',
      };
      // All but the computed styles by default: of those, the few that
      // say whether and how it shows.
      bool wants(String part) =>
          parts.isEmpty ? part != 'computed' : parts.contains(part);
      final computedAsked =
          parts.contains('computed') || input['properties'] is List;
      final out = <String>['Element: ${element.name}'];
      if (wants('html')) {
        final html = await _callOn(
          browser,
          tabId,
          element.objectId,
          'function () { return this.outerHTML; }',
        );
        out
          ..add('')
          ..add('HTML:')
          ..add(_clip('$html', parts.contains('html') ? 20000 : 1500));
      }
      final node = await _nodeId(browser, tabId, element.objectId);
      if (wants('rules') || wants('computed') || computedAsked) {
        await browser.cdp(tabId, 'CSS.enable');
      }
      Map<String, String> computed = const {};
      if (computedAsked || wants('box')) {
        final result = await browser.cdp(tabId, 'CSS.getComputedStyleForNode', {
          'nodeId': node,
        });
        computed = {
          for (final p
              in (result['computedStyle'] as List? ?? const []).cast<Map>())
            p['name'] as String: p['value'] as String,
        };
      }
      if (wants('box')) {
        out.addAll([
          '',
          ...await _box(browser, tabId, node),
          '  ${[for (final name in _computedBrief)
            if (computed[name] case final v?) '$name: $v'].join('; ')}',
        ]);
      }
      if (wants('rules')) {
        out.addAll([
          '',
          ...await _rules(tab, node, userAgent: input['userAgent'] == true),
        ]);
      }
      if (computedAsked) {
        final asked = [
          for (final p in (input['properties'] as List?) ?? const []) '$p',
        ];
        out
          ..add('')
          ..add('Computed:');
        for (final name in asked.isEmpty ? _computedShown : asked) {
          final value = name == 'margin' || name == 'padding'
              ? [
                  for (final side in ['top', 'right', 'bottom', 'left'])
                    computed['$name-$side'] ?? '?',
                ].join(' ')
              : computed[name];
          if (value == null) continue;
          out.add('  $name: $value');
        }
      }
      if (wants('listeners')) {
        out.addAll(['', ...await _listeners(tab, element.objectId)]);
      }
      if (wants('a11y')) {
        try {
          final tree = await browser.cdp(
            tabId,
            'Accessibility.getPartialAXTree',
            {'nodeId': node, 'fetchRelatives': false},
          );
          final ax = (tree['nodes'] as List? ?? const []).cast<Map>();
          if (ax.isNotEmpty) {
            final n = ax.first;
            String value(Object? v) => '${(v as Map?)?['value'] ?? ''}';
            out
              ..add('')
              ..add(
                'Accessibility: ${n['ignored'] == true ? 'ignored' : 'role ${value(n['role'])}'}'
                '${value(n['name']).isEmpty ? ', no name' : ', name ${jsonEncode(value(n['name']))}'}'
                '${[for (final p in (n['properties'] as List? ?? const []).cast<Map>())
                  if ((p['value'] as Map?)?['value'] case final v? when v != false) '${p['name']}${v == true ? '' : '=$v'}'].map((p) => ', $p').join()}',
              );
          }
        } on Object {
          // Not told.
        }
      }
      if (wants('component')) {
        final value = await _callOn(
          browser,
          tabId,
          element.objectId,
          _frameworkScript,
        );
        if (value is Map && value.isNotEmpty) {
          for (final MapEntry(:key, :value) in value.entries) {
            final c = value as Map;
            final components = [
              ...(c['components'] as List? ?? const []).cast<String>(),
            ];
            // React's nearest: by its name as written, and where.
            var where = '';
            if (key == 'react' && components.isNotEmpty) {
              try {
                final type = await browser.cdp(
                  tabId,
                  'Runtime.callFunctionOn',
                  {
                    'objectId': element.objectId,
                    'functionDeclaration': _reactComponentScript,
                  },
                );
                final call = await _functionPlace(
                  tab,
                  await _debugging(tab),
                  (type['result'] as Map?) ?? const {},
                );
                if (call != null) {
                  if (call.name.isNotEmpty) components[0] = call.name;
                  where = ' (${call.at})';
                }
              } on Object {
                // As named.
              }
            }
            out
              ..add('')
              ..add(
                '${'$key'[0].toUpperCase()}${'$key'.substring(1)}: '
                '${components.isEmpty ? '(no named component)' : components.map((n) => '<$n>').join(' in ')}$where',
              );
            if (c['props'] != null) {
              out.add('  props: ${_clip(jsonEncode(c['props']), 3000)}');
            }
            if (c['state'] != null) {
              out.add('  state: ${_clip(jsonEncode(c['state']), 3000)}');
            }
          }
        }
      }
      return _clip(out.join('\n'), 40000);
    },
  ),
  ClaudeSdkTool(
    name: 'browser_storage',
    description:
        "A shared tab's site data, as DevTools' Application panel shows "
        'it: kind "cookies" (all of them, HttpOnly too), "localStorage", '
        '"sessionStorage", "indexedDB" (databases, stores, records), '
        '"cache" (Cache Storage), "serviceWorkers"; or "all" to clear the '
        "site's data. action: list (default), get (a key's whole value), "
        'set, delete, clear.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'kind': {
          'type': 'string',
          'enum': [
            'cookies',
            'localStorage',
            'sessionStorage',
            'indexedDB',
            'cache',
            'serviceWorkers',
            'all',
          ],
        },
        'action': {
          'type': 'string',
          'enum': ['list', 'get', 'set', 'delete', 'clear'],
        },
        'name': {
          'type': 'string',
          'description':
              'A cookie\'s or a key\'s name; an IndexedDB database\'s; a '
              "cache's.",
        },
        'value': {'type': 'string'},
        'store': {'type': 'string', 'description': 'An IndexedDB store.'},
        'limit': {
          'type': 'integer',
          'description': 'IndexedDB records read. Default 20.',
        },
        'domain': {'type': 'string', 'description': 'A cookie\'s.'},
        'path': {'type': 'string', 'description': 'A cookie\'s.'},
        'httpOnly': {'type': 'boolean'},
        'secure': {'type': 'boolean'},
        'expires': {
          'type': 'number',
          'description': 'A cookie\'s: seconds since the epoch.',
        },
      },
      'required': ['tabId', 'kind'],
    },
    run: (input, call) async {
      final browser = BrowserTools._browser();
      final tabId = input['tabId'] as int;
      final action = input['action'] as String? ?? 'list';
      final name = input['name'] as String?;
      final href = await BrowserTools._evaluate(
        browser,
        tabId,
        'location.href',
      ) as String;
      switch (input['kind']) {
        case 'cookies':
          return _cookies(browser, tabId, href, action, input);
        case 'localStorage' || 'sessionStorage':
          final store = input['kind'] as String;
          final value = await BrowserTools._evaluate(
            browser,
            tabId,
            _webStorageScript(store, action, name, input['value'] as String?),
          );
          return '$value';
        case 'indexedDB':
          final value = await BrowserTools._evaluate(
            browser,
            tabId,
            _indexedDbScript(
              action,
              name,
              input['store'] as String?,
              (input['limit'] as int?) ?? 20,
            ),
          );
          return value is String
              ? value
              : const JsonEncoder.withIndent(' ').convert(value);
        case 'cache':
          final value = await BrowserTools._evaluate(
            browser,
            tabId,
            _cacheScript(action, name),
          );
          return value is String
              ? value
              : const JsonEncoder.withIndent(' ').convert(value);
        case 'serviceWorkers':
          final value = await BrowserTools._evaluate(
            browser,
            tabId,
            action == 'delete' || action == 'clear'
                ? 'navigator.serviceWorker.getRegistrations().then(async (rs) => { for (const r of rs) await r.unregister(); return "Unregistered " + rs.length + "."; })'
                : 'navigator.serviceWorker.getRegistrations().then((rs) => rs.length ? rs.map((r) => ({scope: r.scope, script: (r.active || r.waiting || r.installing || {}).scriptURL, state: (r.active || r.waiting || r.installing || {}).state})) : "None.")',
          );
          return value is String
              ? value
              : const JsonEncoder.withIndent(' ').convert(value);
        case 'all':
          if (action != 'clear') {
            throw const BrowserError('kind all is for action clear.');
          }
          final origin = Uri.parse(href).origin;
          try {
            await browser.cdp(tabId, 'Storage.clearDataForOrigin', {
              'origin': origin,
              'storageTypes': 'all',
            });
          } on Object {
            await _cookies(browser, tabId, href, 'clear', input);
            await BrowserTools._evaluate(
              browser,
              tabId,
              'Promise.all([localStorage.clear(), sessionStorage.clear(), '
              'caches.keys().then((ks) => Promise.all(ks.map((k) => caches.delete(k)))), '
              'indexedDB.databases().then((ds) => Promise.all(ds.map((d) => indexedDB.deleteDatabase(d.name)))), '
              'navigator.serviceWorker.getRegistrations().then((rs) => Promise.all(rs.map((r) => r.unregister()))),]).then(() => true)',
            );
          }
          return 'Cleared all of $origin\'s data: cookies, storage, IndexedDB, '
              'caches, service workers.';
      }
      throw const BrowserError('Say which kind.');
    },
  ),
  ClaudeSdkTool(
    name: 'browser_dialog',
    description:
        "Answers a shared tab's dialog (alert, confirm, prompt, the page "
        'asking before it is left): the one open now, else the next (all '
        'the next, with always). While you act, an alert is accepted and a '
        "question (confirm, prompt) dismissed unless you say; the action's "
        'answer tells what a dialog said.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'accept': {'type': 'boolean'},
        'text': {'type': 'string', 'description': "A prompt's answer."},
        'always': {'type': 'boolean'},
      },
      'required': ['tabId', 'accept'],
    },
    run: (input, call) async {
      final tab = BrowserTab(BrowserTools._browser(), input['tabId'] as int);
      final records = BrowserRecords.instance;
      final accept = input['accept'] == true;
      final text = input['text'] as String?;
      if (await records.answerOpenDialog(tab, accept: accept, text: text)
          case final dialog?) {
        return 'Answered: ${dialog.describe()}';
      }
      records.answerDialogs(
        tab,
        accept: accept,
        text: text,
        always: input['always'] == true,
      );
      return 'No dialog is open: the ${input['always'] == true ? 'next ones' : 'next one'} '
          'will be ${accept ? 'accepted' : 'dismissed'}.';
    },
  ),
];

/// The box model of [node]: its size, and each edge's.
Future<List<String>> _box(
  BrowserConnection browser,
  int tabId,
  int node,
) async {
  try {
    final result = await browser.cdp(tabId, 'DOM.getBoxModel', {
      'nodeId': node,
    });
    final model = result['model'] as Map;
    List<num> quad(String name) => (model[name] as List).cast<num>();
    final content = quad('content');
    final padding = quad('padding');
    final border = quad('border');
    final margin = quad('margin');
    String edges(List<num> outer, List<num> inner) {
      final top = inner[1] - outer[1];
      final right = outer[2] - inner[2];
      final bottom = outer[5] - inner[5];
      final left = inner[0] - outer[0];
      String n(num v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
      return '${n(top)} ${n(right)} ${n(bottom)} ${n(left)}';
    }

    String n(num v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
    return [
      'Box: ${n(border[2] - border[0])}×${n(border[5] - border[1])} at '
          '(${n(border[0])}, ${n(border[1])}) of the page',
      '  content ${n(content[2] - content[0])}×${n(content[5] - content[1])}; '
          'padding ${edges(padding, content)}; border ${edges(border, padding)}; '
          'margin ${edges(margin, border)} (top right bottom left)',
    ];
  } on Object {
    return ['Box: none (not rendered: display none, or not in the page).'];
  }
}

/// What [tab]'s style sheet [id] is called: its file's URL; a <style> a
/// dev server put in by the file it holds (Vite's `data-vite-dev-id`);
/// else a <style> of the page's.
Future<String> _sheetName(BrowserTab tab, String id) async {
  final sheet = BrowserRecords.instance.styleSheets(tab)[id];
  if (sheet == null) return '<style> in the page';
  if (sheet['caocodeName'] case final String name) return name;
  final url = sheet['sourceURL'] as String? ?? '';
  var name = url.isNotEmpty && sheet['isInline'] != true
      ? url
      : '<style> in the page';
  if (name.startsWith('<') && sheet['ownerNode'] is int) {
    try {
      final described = await tab.browser.cdp(tab.tabId, 'DOM.describeNode', {
        'backendNodeId': sheet['ownerNode'],
      });
      final attributes =
          ((described['node'] as Map?)?['attributes'] as List? ?? const [])
              .cast<String>();
      for (var i = 0; i + 1 < attributes.length; i += 2) {
        if (attributes[i] == 'data-vite-dev-id' && attributes[i + 1] != '') {
          name = attributes[i + 1];
        }
      }
    } on Object {
      // Gone: as it is.
    }
  }
  sheet['caocodeName'] = name;
  return name;
}

/// The CSS rules that style [node], highest first; what each sets, and
/// which of it is overridden.
Future<List<String>> _rules(
  BrowserTab tab,
  int node, {
  required bool userAgent,
}) async {
  final browser = tab.browser;
  final matched = await browser.cdp(tab.tabId, 'CSS.getMatchedStylesForNode', {
    'nodeId': node,
  });
  final sheets = BrowserRecords.instance.styleSheets(tab);
  final names = <String, String>{};
  for (final match in [
    ...(matched['matchedCSSRules'] as List? ?? const []).cast<Map>(),
    for (final entry in (matched['inherited'] as List? ?? const []).cast<Map>())
      ...(entry['matchedCSSRules'] as List? ?? const []).cast<Map>(),
  ]) {
    final id = (match['rule'] as Map)['styleSheetId'] as String?;
    if (id != null && !names.containsKey(id)) {
      names[id] = await _sheetName(tab, id);
    }
  }
  String source(Map rule) {
    final style = rule['style'] as Map? ?? const {};
    final range = style['range'] as Map?;
    final sheet = sheets[rule['styleSheetId']];
    // A <style> of the document: lines of the document's.
    final line = range == null
        ? null
        : (range['startLine'] as num).toInt() +
              ((sheet?['startLine'] as num?)?.toInt() ?? 0) +
              1;
    if (rule['origin'] == 'user-agent') return 'the browser\'s';
    final name = names[rule['styleSheetId']] ?? '<style> in the page';
    if (name.startsWith('<')) {
      return '$name${line == null ? '' : ', line $line'}';
    }
    return '$name${line == null ? '' : ':$line'}';
  }

  // Each declaration: (rule, name, value, important); the rules highest
  // first.
  final blocks = <({String head, String? where, List<Map> properties})>[];
  if (matched['inlineStyle'] case final Map inline) {
    final properties = (inline['cssProperties'] as List? ?? const [])
        .cast<Map>()
        .where((p) => p['range'] != null)
        .toList();
    if (properties.isNotEmpty) {
      blocks.add((head: 'element.style', where: null, properties: properties));
    }
  }
  var hiddenUserAgent = 0;
  final rules = (matched['matchedCSSRules'] as List? ?? const []).cast<Map>();
  for (final match in rules.reversed) {
    final rule = match['rule'] as Map;
    if (rule['origin'] == 'user-agent' && !userAgent) {
      hiddenUserAgent++;
      continue;
    }
    final media = [
      for (final m in (rule['media'] as List? ?? const []).cast<Map>())
        '@media ${m['text']}',
    ];
    final properties =
        ((rule['style'] as Map)['cssProperties'] as List? ?? const [])
            .cast<Map>()
            .where((p) => p['range'] != null || rule['origin'] == 'user-agent')
            .where((p) => p['implicit'] != true)
            .toList();
    blocks.add((
      head:
          '${media.isEmpty ? '' : '${media.join(' ')} '}'
          '${(rule['selectorList'] as Map?)?['text'] ?? '?'}',
      where: source(rule),
      properties: properties,
    ));
  }
  // The winner of each property: an important one first, else the
  // highest.
  final winner = <String, Map>{};
  for (final important in [true, false]) {
    for (final block in blocks) {
      for (final p in block.properties) {
        final name = p['name'] as String;
        if (p['disabled'] == true || p['parsedOk'] == false) continue;
        if ((p['important'] == true) != important) continue;
        winner.putIfAbsent(name, () => p);
      }
    }
  }
  String declaration(Map p) {
    final text =
        '${p['name']}: ${p['value']}${p['important'] == true ? ' !important' : ''}';
    if (p['parsedOk'] == false) return '$text (invalid)';
    if (p['disabled'] == true) return '$text (disabled)';
    return identical(winner[p['name']], p) ? text : '~~$text~~';
  }

  final out = <String>['Styles (highest first; ~~overridden~~):'];
  for (final block in blocks) {
    out.add(
      '  ${block.head} {${block.properties.isEmpty ? '' : ' ${block.properties.map(declaration).join('; ')}'} }'
      '${block.where == null ? '' : ' — ${block.where}'}',
    );
  }
  if (hiddenUserAgent > 0) {
    out.add('  ($hiddenUserAgent of the browser\'s own: userAgent shows them)');
  }
  final inherited = (matched['inherited'] as List? ?? const []).cast<Map>();
  for (final (depth, entry) in inherited.indexed) {
    final lines = <String>[];
    final own = [
      if (entry['inlineStyle'] case final Map inline)
        (head: 'style attribute', where: null, rule: null, style: inline),
      for (final match
          in (entry['matchedCSSRules'] as List? ?? const [])
              .cast<Map>()
              .reversed)
        (
          head: '${((match['rule'] as Map)['selectorList'] as Map?)?['text']}',
          where: source(match['rule'] as Map),
          rule: match['rule'] as Map,
          style: (match['rule'] as Map)['style'] as Map,
        ),
    ];
    for (final block in own) {
      if (block.rule?['origin'] == 'user-agent') continue;
      final properties = [
        for (final p
            in (block.style['cssProperties'] as List? ?? const []).cast<Map>())
          if (p['range'] != null && _inherited.contains(p['name'])) p,
      ];
      if (properties.isEmpty) continue;
      lines.add(
        '    ${block.head} { ${properties.map((p) => '${p['name']}: ${p['value']}').join('; ')} }'
        '${block.where == null ? '' : ' — ${block.where}'}',
      );
    }
    if (lines.isNotEmpty) {
      out
        ..add(
          '  Inherited from ${depth == 0 ? 'its parent' : 'ancestor ${depth + 1} up'}:',
        )
        ..addAll(lines);
    }
  }
  final pseudo = (matched['pseudoElements'] as List? ?? const []).cast<Map>();
  for (final p in pseudo) {
    final matches = (p['matches'] as List? ?? const []).cast<Map>();
    for (final match in matches.reversed) {
      final rule = match['rule'] as Map;
      if (rule['origin'] == 'user-agent') continue;
      final properties =
          ((rule['style'] as Map)['cssProperties'] as List? ?? const [])
              .cast<Map>()
              .where((p) => p['range'] != null);
      out.add(
        '  ${(rule['selectorList'] as Map?)?['text']} { ${properties.map((p) => '${p['name']}: ${p['value']}').join('; ')} }'
        ' — ${source(rule)}',
      );
    }
  }
  return out;
}

/// [objectId]'s event listeners, where their code is; and its ancestors'
/// (a framework's, delegated), by type.
/// Where the function [value] (a RemoteObject) is, and its name as
/// written.
Future<({String name, String at})?> _functionPlace(
  BrowserTab tab,
  _Debugging debugging,
  Map value,
) async {
  final id = value['objectId'] as String?;
  if (id == null) return null;
  final inside = await tab.browser.cdp(tab.tabId, 'Runtime.getProperties', {
    'objectId': id,
    'ownProperties': true,
  });
  final location =
      ((inside['internalProperties'] as List? ?? const [])
                  .cast<Map>()
                  .where((i) => i['name'] == '[[FunctionLocation]]')
                  .firstOrNull?['value']
              as Map?)?['value']
          as Map?;
  if (location == null) return null;
  final head = '${value['description'] ?? ''}'.split('\n').first;
  final name =
      RegExp(r'^(?:async\s+)?(?:function\s*\*?\s*|class\s+)([\w$]+)')
          .firstMatch(head)?[1] ??
      '';
  return _locatedCall(
    tab,
    name,
    debugging.scripts[location['scriptId']]?.url ?? '',
    (location['lineNumber'] as num?)?.toInt() ?? 0,
    (location['columnNumber'] as num?)?.toInt() ?? 0,
    definition: true,
  );
}

/// The function of the React component nearest an element.
const _reactComponentScript = r'''
function () {
  for (let n = this; n; n = n.parentElement) {
    const key = Object.keys(n).find((k) => k.startsWith('__reactFiber$'));
    if (!key) continue;
    for (let f = n[key]; f; f = f.return) {
      let t = f.type;
      if (t && typeof t === 'object') t = t.render || t.type;
      if (typeof t === 'function') return t;
    }
    return null;
  }
  return null;
}''';

/// An element's handlers a framework calls: React's props (onClick…),
/// Vue's (@click), by name.
const _handlersScript = r'''
function () {
  const out = {};
  for (const key of Object.keys(this)) {
    if (!key.startsWith('__reactProps$')) continue;
    const props = this[key] || {};
    for (const k of Object.keys(props)) {
      if (/^on[A-Z]/.test(k) && typeof props[k] === 'function') out[k + ' (React)'] = props[k];
    }
  }
  const vei = this._vei;
  if (vei) {
    for (const k of Object.keys(vei)) {
      const v = vei[k] && vei[k].value;
      (Array.isArray(v) ? v : [v]).forEach((f, i) => {
        if (typeof f === 'function') out[k + (i ? ' #' + (i + 1) : '') + ' (Vue)'] = f;
      });
    }
  }
  return out;
}''';

Future<List<String>> _listeners(BrowserTab tab, String objectId) async {
  final browser = tab.browser;
  final debugging = await _debugging(tab);
  Future<List<Map>> of(String id) async {
    final result = await browser.cdp(
      tab.tabId,
      'DOMDebugger.getEventListeners',
      {'objectId': id},
    );
    return (result['listeners'] as List? ?? const []).cast<Map>();
  }

  final out = <String>['Listeners:'];
  final own = await of(objectId);
  if (own.isEmpty) out.add('  (none on it)');
  for (final l in own.take(30)) {
    final script = debugging.scripts[l['scriptId']];
    final flags = [
      if (l['useCapture'] == true) 'capture',
      if (l['passive'] == true) 'passive',
      if (l['once'] == true) 'once',
    ];
    out.add(
      '  ${l['type']}${flags.isEmpty ? '' : ' (${flags.join(', ')})'} → '
      '${await debugging.where(script?.url ?? '', (l['lineNumber'] as num?)?.toInt() ?? 0, (l['columnNumber'] as num?)?.toInt() ?? 0)}',
    );
  }
  // A framework's handlers (React's onClick, Vue's @click): the listener
  // above is the framework's own, these the app's.
  try {
    final result = await browser.cdp(tab.tabId, 'Runtime.callFunctionOn', {
      'objectId': objectId,
      'functionDeclaration': _handlersScript,
    });
    final handlers = (result['result'] as Map?)?['objectId'] as String?;
    if (handlers != null) {
      final properties = await browser.cdp(tab.tabId, 'Runtime.getProperties', {
        'objectId': handlers,
        'ownProperties': true,
      });
      for (final p in (properties['result'] as List? ?? const []).cast<Map>()) {
        final value = p['value'] as Map?;
        final id = value?['objectId'] as String?;
        if (id == null || value?['type'] != 'function') continue;
        final call = await _functionPlace(tab, debugging, value!);
        if (call == null) continue;
        out.add(
          '  ${p['name']} → ${call.name.isEmpty ? '' : '${call.name} at '}${call.at}',
        );
      }
    }
  } on Object {
    // None told.
  }
  // Its ancestors', the document's and the window's: where frameworks
  // listen for all.
  try {
    final result = await browser.cdp(tab.tabId, 'Runtime.callFunctionOn', {
      'objectId': objectId,
      'functionDeclaration': 'function () { const a = []; for (let n = this.parentElement; n; n = n.parentElement) a.push(n); a.push(document, window); return a; }',
    });
    final array = (result['result'] as Map?)?['objectId'] as String?;
    if (array != null) {
      final properties = await browser.cdp(tab.tabId, 'Runtime.getProperties', {
        'objectId': array,
        'ownProperties': true,
      });
      final lines = <String>[];
      for (final p in (properties['result'] as List? ?? const []).cast<Map>()) {
        if (int.tryParse('${p['name']}') == null) continue;
        final value = p['value'] as Map?;
        final id = value?['objectId'] as String?;
        if (id == null) continue;
        final listeners = await of(id);
        if (listeners.isEmpty) continue;
        final types = <String>{for (final l in listeners) '${l['type']}'};
        lines.add(
          '  ${value?['description'] ?? '?'}: ${types.take(20).join(', ')}'
          '${types.length > 20 ? '…' : ''}',
        );
        if (lines.length >= 12) break;
      }
      if (lines.isNotEmpty) {
        out
          ..add('Listeners of its ancestors (events reach them too):')
          ..addAll(lines);
      }
    }
  } on Object {
    // Its own alone.
  }
  return out;
}

Future<String> _cookies(
  BrowserConnection browser,
  int tabId,
  String href,
  String action,
  Map<String, Object?> input,
) async {
  final name = input['name'] as String?;
  final result = await browser.cdp(tabId, 'Network.getCookies', {
    'urls': [href],
  });
  final cookies = (result['cookies'] as List? ?? const []).cast<Map>();
  switch (action) {
    case 'set':
      if (name == null) throw const BrowserError('Say the cookie: name.');
      final set = await browser.cdp(tabId, 'Network.setCookie', {
        'name': name,
        'value': input['value'] as String? ?? '',
        'url': href,
        'domain': ?input['domain'],
        'path': ?input['path'],
        'httpOnly': ?input['httpOnly'],
        'secure': ?input['secure'],
        'expires': ?input['expires'],
      });
      return set['success'] == false ? 'The browser refused it.' : 'Set $name.';
    case 'delete':
      if (name == null) throw const BrowserError('Say the cookie: name.');
      await browser.cdp(tabId, 'Network.deleteCookies', {
        'name': name,
        'url': href,
        'domain': ?input['domain'],
        'path': ?input['path'],
      });
      return 'Deleted $name.';
    case 'clear':
      for (final c in cookies) {
        await browser.cdp(tabId, 'Network.deleteCookies', {
          'name': c['name'],
          'domain': c['domain'],
          'path': c['path'],
        });
      }
      return 'Deleted ${cookies.length} cookies.';
  }
  final shown = [
    for (final c in cookies)
      if (name == null || c['name'] == name) c,
  ];
  if (shown.isEmpty) return 'No cookie${name == null ? '' : ' $name'}.';
  return [
    for (final c in shown)
      [
        '${c['name']}=${action == 'get' ? c['value'] : _clip('${c['value']}', 200)}',
        'domain ${c['domain']}',
        'path ${c['path']}',
        if ((c['expires'] as num? ?? -1) > 0)
          'expires ${DateTime.fromMillisecondsSinceEpoch(((c['expires'] as num) * 1000).round()).toIso8601String()}'
        else
          'session',
        if (c['httpOnly'] == true) 'HttpOnly',
        if (c['secure'] == true) 'Secure',
        if (c['sameSite'] case final String s) 'SameSite=$s',
        '${c['size']} B',
      ].join('; '),
  ].join('\n');
}

String _webStorageScript(
  String store,
  String action,
  String? name,
  String? value,
) {
  final key = jsonEncode(name);
  return switch (action) {
    'get' =>
      '(() => { const v = $store.getItem($key); return v === null ? "No $name." : v; })()',
    'set' => '($store.setItem($key, ${jsonEncode(value ?? '')}), "Set $name.")',
    'delete' => '($store.removeItem($key), "Deleted $name.")',
    'clear' =>
      '(() => { const n = $store.length; $store.clear(); return "Cleared " + n + " keys."; })()',
    _ =>
      '(() => { const out = []; let size = 0; for (let i = 0; i < $store.length; i++) { const k = $store.key(i); const v = $store.getItem(k) || ""; size += k.length + v.length; out.push(k + " = " + (v.length > 300 ? v.slice(0, 300) + "… (" + v.length + " chars)" : v)); } return out.length ? out.join("\\n") + "\\n(" + out.length + " keys, " + size + " chars)" : "Empty."; })()',
  };
}

String _indexedDbScript(
  String action,
  String? database,
  String? store,
  int limit,
) {
  final db = jsonEncode(database);
  final st = jsonEncode(store);
  const open =
      'const open = (name) => new Promise((ok, no) => { const r = indexedDB.open(name); r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); r.onupgradeneeded = () => { r.transaction.abort(); no(new Error("No database " + name)); }; });';
  const safe =
      'const safe = (v, d) => { if (v === null || v === undefined) return v; if (typeof v === "string") return v.length > 500 ? v.slice(0, 500) + "…" : v; if (typeof v !== "object") return v; if (v instanceof Date) return v.toISOString(); if (v instanceof Blob) return "(Blob " + v.size + " B)"; if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) return "(binary " + v.byteLength + " B)"; if (d <= 0) return "{…}"; if (Array.isArray(v)) return v.slice(0, 20).map((x) => safe(x, d - 1)); const o = {}; for (const k of Object.keys(v).slice(0, 40)) o[k] = safe(v[k], d - 1); return o; };';
  return switch (action) {
    'delete' =>
      '(() => new Promise((ok, no) => { const r = indexedDB.deleteDatabase($db); r.onsuccess = () => ok("Deleted " + $db + "."); r.onerror = () => no(r.error); r.onblocked = () => ok("Deleting " + $db + ": blocked till its connections close."); }))()',
    'clear' =>
      '(async () => { $open const d = await open($db); const t = d.transaction($st, "readwrite"); t.objectStore($st).clear(); await new Promise((ok, no) => { t.oncomplete = ok; t.onerror = () => no(t.error); }); d.close(); return "Cleared " + $st + "."; })()',
    _ when database != null && store != null =>
      '(async () => { $open $safe const d = await open($db); const s = d.transaction($st).objectStore($st); const req = (r) => new Promise((ok, no) => { r.onsuccess = () => ok(r.result); r.onerror = () => no(r.error); }); const [count, keys, values] = await Promise.all([req(s.count()), req(s.getAllKeys(null, $limit)), req(s.getAll(null, $limit))]); d.close(); return { store: $st, count, keyPath: s.keyPath, records: keys.map((k, i) => ({ key: safe(k, 2), value: safe(values[i], 4) })) }; })()',
    _ =>
      '(async () => { $open const all = await indexedDB.databases(); const want = $db; const out = []; for (const info of all) { if (want && info.name !== want) continue; try { const d = await open(info.name); const stores = []; for (const name of d.objectStoreNames) { const s = d.transaction(name).objectStore(name); const count = await new Promise((ok) => { const r = s.count(); r.onsuccess = () => ok(r.result); r.onerror = () => ok("?"); }); stores.push({ name, keyPath: s.keyPath, autoIncrement: s.autoIncrement, indexes: Array.from(s.indexNames), count }); } d.close(); out.push({ name: info.name, version: info.version, stores }); } catch (e) { out.push({ name: info.name, error: String(e) }); } } return out.length ? out : "No database."; })()',
  };
}

String _cacheScript(String action, String? name) {
  final cache = jsonEncode(name);
  return switch (action) {
    'delete' || 'clear' when name != null =>
      'caches.delete($cache).then((done) => done ? "Deleted " + $cache + "." : "No cache " + $cache + ".")',
    'delete' || 'clear' => 'caches.keys().then((ks) => Promise.all(ks.map((k) => caches.delete(k))).then(() => "Deleted " + ks.length + " caches."))',
    _ when name != null =>
      'caches.open($cache).then((c) => c.keys()).then((rs) => ({ cache: $cache, count: rs.length, requests: rs.slice(0, 100).map((r) => r.method + " " + r.url) }))',
    _ => 'caches.keys().then((ks) => Promise.all(ks.map((k) => caches.open(k).then((c) => c.keys()).then((rs) => ({ cache: k, count: rs.length }))))).then((l) => l.length ? l : "No cache.")',
  };
}
