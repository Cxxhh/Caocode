part of 'browser_tools.dart';

// The agents' DevTools: a shared tab's console, network and performance,
// and the conditions it runs in. What the console and network kept comes
// from the first time Caocode used the tab (see browser_records.dart).

final _debugTools = [
  ClaudeSdkTool(
    name: 'browser_console',
    description:
        "A shared tab's console since Caocode first used it: console calls, "
        'uncaught exceptions, and the browser\'s own messages (blocked '
        'requests, CORS, CSP), oldest first; of its frames and workers '
        'too. Errors and warnings with where they came from, mapped to '
        'the sources (source maps).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'level': {
          'type': 'string',
          'enum': ['all', 'warning', 'error'],
          'description': 'warning: warnings and errors. Default all.',
        },
        'limit': {'type': 'integer', 'description': 'The last n. Default 100.'},
        'clear': {
          'type': 'boolean',
          'description': 'Forget them after reading.',
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final tab = BrowserTab(BrowserTools._browser(), input['tabId'] as int);
      final records = BrowserRecords.instance;
      final level = input['level'] as String? ?? 'all';
      final entries = records
          .console(tab)
          .where(
            (e) => switch (level) {
              'error' => e.level == 'error',
              'warning' => e.level == 'error' || e.level == 'warning',
              _ => true,
            },
          )
          .toList();
      if (input['clear'] == true) records.clearConsole(tab);
      if (entries.isEmpty) return 'Nothing logged.';
      final limit = input['limit'] as int? ?? 100;
      final shown = entries.length > limit
          ? entries.sublist(entries.length - limit)
          : entries;
      String time(DateTime t) =>
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}.'
          '${t.millisecond.toString().padLeft(3, '0')}';
      // The calls of the last errors and warnings, mapped; the rest with
      // where they were logged.
      final stacked = shown
          .where((e) => e.stack.isNotEmpty || e.thrown.isNotEmpty)
          .toList();
      final withStacks = stacked
          .sublist(stacked.length > 15 ? stacked.length - 15 : 0)
          .toSet();
      final lines = <String>[
        if (shown.length < entries.length)
          'The last ${shown.length} of ${entries.length}:',
      ];
      for (final e in shown) {
        final stack = withStacks.contains(e);
        lines.add(
          '[${time(e.time)}] ${e.level}${e.from == null ? '' : ' (${_clip(e.from!, 120)})'}: '
          '${_clip(e.text, 2000)}'
          '${stack || e.url == null || e.url!.isEmpty ? '' : ' (${e.url}${e.line == null ? '' : ':${e.line}'})'}',
        );
        if (stack && e.thrown.isNotEmpty) {
          // Where the error was thrown; where it was logged after.
          lines
            ..addAll(await _stackLines(tab, e.thrown, max: 5))
            ..addAll(
              await _stackLines(
                tab,
                e.stack,
                max: 1,
                indent: '  logged ',
                libraries: false,
              ),
            );
        } else if (stack) {
          lines.addAll(await _stackLines(tab, e.stack, max: 5));
        }
      }
      return lines.join('\n');
    },
  ),
  ClaudeSdkTool(
    name: 'browser_network',
    description:
        "Lists the requests of a shared tab's page since Caocode first used "
        'it, oldest first: id, method, status, type, size, time, URL. Read '
        'them with browser_request, or save them all, with their headers '
        'and bodies, as a HAR file (save) to go through with jq or a '
        'script. The bodies of Document, XHR and Fetch responses are kept '
        'as they finish; the others only while the browser still has them.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'url': {'type': 'string', 'description': 'Those whose URL has it.'},
        'type': {
          'type': 'string',
          'description':
              'Document, XHR, Fetch, Script, Stylesheet, Image, Font, Media, '
              'WebSocket, Other.',
        },
        'failed': {
          'type': 'boolean',
          'description': 'Those that failed or got a status of 400 or more.',
        },
        'limit': {'type': 'integer', 'description': 'The last n. Default 50.'},
        'save': {
          'type': 'string',
          'description':
              'A path (.har) to save those found to, all of them (limit is '
              'not applied), instead of listing them.',
        },
        'clear': {
          'type': 'boolean',
          'description': 'Forget them after reading.',
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final tab = BrowserTab(BrowserTools._browser(), input['tabId'] as int);
      final records = BrowserRecords.instance;
      final url = input['url'] as String?;
      final type = (input['type'] as String?)?.toLowerCase();
      final failed = input['failed'] == true;
      final requests = records
          .requests(tab)
          .where(
            (r) =>
                (url == null || r.url.contains(url)) &&
                (type == null || r.type.toLowerCase() == type) &&
                (!failed || r.failure != null || (r.status ?? 0) >= 400),
          )
          .toList();
      if (requests.isEmpty) {
        if (input['clear'] == true) records.clearRequests(tab);
        return 'No request.';
      }
      if (input['save'] case final String save) {
        final saved = await _saveHar(tab, requests, _path(save, call.cwd));
        if (input['clear'] == true) records.clearRequests(tab);
        return saved;
      }
      if (input['clear'] == true) records.clearRequests(tab);
      final limit = input['limit'] as int? ?? 50;
      final shown = requests.length > limit
          ? requests.sublist(requests.length - limit)
          : requests;
      final all = records.requests(tab);
      final since = records.since(tab);
      return [
        if (since != null && !all.any((r) => r.type == 'Document'))
          'The page\'s load is not among them: they are kept from '
              '${since.toIso8601String().substring(11, 19)}, when Caocode '
              'first used the tab (browser_navigate reload records it).',
        if (shown.length < requests.length)
          'The last ${shown.length} of ${requests.length}:',
        for (final r in shown)
          [
            r.id,
            r.method,
            // A response's status over a failure after it (its body let go).
            r.status?.toString() ?? r.failure ?? 'pending',
            r.type,
            if (r.fromCache) '(cache)' else _bytes(r.size),
            if (r.duration case final ms?) '$ms ms' else '…',
            _clip(r.url, 300),
          ].join(' '),
      ].join('\n');
    },
  ),
  ClaudeSdkTool(
    name: 'browser_request',
    description:
        'Requests of a shared tab (their ids, from browser_network): what '
        'made them (the code, mapped to the sources), their headers as '
        'sent (cookies too), body, and the response: status, headers, '
        'timing, body (text, or the image); a WebSocket\'s or an '
        "EventSource's messages. as: \"curl\" or \"fetch\" writes it as a "
        'command to run again. replay: sends it again from the page (its '
        'cookies), changed by changes {url, method, headers, body}, and '
        'answers what came back.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'id': {'type': 'string'},
        'ids': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'Several at once, instead of id. For many, browser_network '
              'saves them as a HAR file.',
        },
        'as': {
          'type': 'string',
          'enum': ['curl', 'fetch'],
        },
        'replay': {'type': 'boolean'},
        'changes': {
          'type': 'object',
          'description':
              'replay: url, method, headers (null takes one out), body.',
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final tab = BrowserTab(BrowserTools._browser(), input['tabId'] as int);
      if (input['as'] != null || input['replay'] == true) {
        final id = input['id'] as String? ?? '';
        final r = BrowserRecords.instance.request(tab, id);
        if (r == null) {
          throw BrowserError('No request $id: list them with browser_network.');
        }
        if (input['replay'] == true) {
          return _replay(
            tab,
            r,
            ((input['changes'] as Map?) ?? const {}).cast<String, Object?>(),
          );
        }
        final body = await BrowserRecords.instance.requestBody(tab, r);
        return input['as'] == 'fetch' ? _asFetch(r, body) : _asCurl(r, body);
      }
      final ids = [
        if (input['id'] case final String id) id,
        ...?(input['ids'] as List?)?.map((id) => '$id'),
      ];
      if (ids.isEmpty) throw StateError('Give the id of a request, or ids.');
      // Several share what one would say.
      final clip = ids.length == 1
          ? 30000
          : (60000 ~/ ids.length).clamp(2000, 30000);
      final answer = <Object?>[];
      final texts = StringBuffer();
      for (final id in ids) {
        final r = BrowserRecords.instance.request(tab, id);
        final described = r == null
            ? ['No request $id: list them with browser_network.']
            : await _describeRequest(tab, r, clip);
        for (final part in described) {
          if (part is String) {
            if (texts.isNotEmpty) texts.write('\n\n');
            texts.write(part);
          } else {
            // A picture after its request's lines.
            answer
              ..add(claudeSdkText('$texts'))
              ..add(part);
            texts.clear();
          }
        }
      }
      if (answer.isEmpty) return '$texts';
      if (texts.isNotEmpty) answer.add(claudeSdkText('$texts'));
      return answer;
    },
  ),
  ClaudeSdkTool(
    name: 'browser_performance',
    description:
        "Records a shared tab's performance, as DevTools' Performance panel "
        'does: "reload" (the default) reloads the page and records its '
        'load; "start" begins a recording and "stop" ends it, for what you '
        'do in between. Returns Web Vitals (LCP and its element, CLS and '
        'what shifted, INP and the slowest interactions, FCP, TTFB), the '
        "long animation frames and the scripts in them, the main thread's "
        'busy time by kind, its long tasks and what ran in them, the '
        'functions that took the most CPU (mapped to the sources), the '
        'slowest requests, and the paths of the trace and the CPU profile '
        'saved, which DevTools opens.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'action': {
          'type': 'string',
          'enum': ['reload', 'start', 'stop'],
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final browser = BrowserTools._browser();
      final tab = BrowserTab(browser, input['tabId'] as int);
      switch (input['action'] as String? ?? 'reload') {
        case 'start':
          await _Trace.start(tab);
          return 'Recording. Stop with action "stop".';
        case 'stop':
          final trace = _Trace.of(tab);
          if (trace == null) throw StateError('Not recording: start first.');
          return trace.stop();
        default:
          final trace = await _Trace.start(tab);
          await BrowserTools._loading(
            browser,
            tab.tabId,
            () => browser.cdp(tab.tabId, 'Page.reload'),
            timeout: const Duration(seconds: 30),
          );
          // What follows the load: late scripts, layout shifts.
          await Future<void>.delayed(const Duration(seconds: 2));
          return trace.stop();
      }
    },
  ),
  ClaudeSdkTool(
    name: 'browser_emulate',
    description:
        'Makes a shared tab run as on a slower machine or network, or a '
        'phone, or for another user: dark mode, reduced motion, print, '
        'another language, time zone or place, user agent; its cache off; '
        'its scripts off; as one with a vision deficiency sees it. Kept '
        'while Caocode uses the tab. "none" (or "") undoes each.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'cpu': {
          'type': 'number',
          'description': 'How many times slower (4: a mid phone). 1: none.',
        },
        'network': {
          'type': 'string',
          'enum': ['none', 'offline', 'slow3g', 'fast3g', 'fast4g'],
        },
        'device': {
          'type': 'string',
          'enum': ['none', 'phone', 'tablet'],
        },
        'viewport': {
          'type': 'object',
          'description':
              'Instead of device: {width, height, scale, mobile}, CSS pixels.',
        },
        'colorScheme': {
          'type': 'string',
          'enum': ['none', 'light', 'dark'],
        },
        'reducedMotion': {'type': 'boolean'},
        'media': {
          'type': 'string',
          'enum': ['none', 'print', 'screen'],
        },
        'locale': {'type': 'string', 'description': 'e.g. en-US, zh-CN.'},
        'timezone': {'type': 'string', 'description': 'e.g. America/New_York.'},
        'geolocation': {
          'type': 'object',
          'description': '{latitude, longitude, accuracy}; {} to undo.',
        },
        'userAgent': {'type': 'string'},
        'cache': {
          'type': 'boolean',
          'description': 'false: the cache off, as DevTools\' Disable cache.',
        },
        'javascript': {'type': 'boolean'},
        'vision': {
          'type': 'string',
          'enum': [
            'none',
            'blurredVision',
            'reducedContrast',
            'achromatopsia',
            'deuteranopia',
            'protanopia',
            'tritanopia',
          ],
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final browser = BrowserTools._browser();
      final tabId = input['tabId'] as int;
      final tab = BrowserTab(browser, tabId);
      final done = <String>[];
      final media = _media.putIfAbsent(tab, () => {});
      var mediaChanged = false;
      if (input['colorScheme'] case final String scheme) {
        media['prefers-color-scheme'] = scheme == 'none' ? '' : scheme;
        mediaChanged = true;
        done.add('Color scheme: $scheme');
      }
      if (input['reducedMotion'] case final bool reduced) {
        media['prefers-reduced-motion'] = reduced ? 'reduce' : '';
        mediaChanged = true;
        done.add('Reduced motion: ${reduced ? 'on' : 'off'}');
      }
      if (input['media'] case final String type) {
        media[''] = type == 'none' ? '' : type;
        mediaChanged = true;
        done.add('Media: $type');
      }
      if (mediaChanged) {
        await browser.cdp(tabId, 'Emulation.setEmulatedMedia', {
          'media': media[''] ?? '',
          'features': [
            for (final MapEntry(:key, :value) in media.entries)
              if (key.isNotEmpty) {'name': key, 'value': value},
          ],
        });
      }
      if (input['locale'] case final String locale) {
        await browser.cdp(tabId, 'Emulation.setLocaleOverride', {
          if (locale.isNotEmpty && locale != 'none') 'locale': locale,
        });
        done.add('Locale: ${locale.isEmpty ? 'as is' : locale}');
      }
      if (input['timezone'] case final String zone) {
        await browser.cdp(tabId, 'Emulation.setTimezoneOverride', {
          'timezoneId': zone == 'none' ? '' : zone,
        });
        done.add(
          'Time zone: ${zone.isEmpty || zone == 'none' ? 'as is' : zone}',
        );
      }
      if (input['geolocation'] case final Map place) {
        if (place['latitude'] is num && place['longitude'] is num) {
          await browser.cdp(tabId, 'Emulation.setGeolocationOverride', {
            'latitude': place['latitude'],
            'longitude': place['longitude'],
            'accuracy': place['accuracy'] ?? 50,
          });
          done.add('Place: ${place['latitude']}, ${place['longitude']}');
        } else {
          await browser.cdp(tabId, 'Emulation.clearGeolocationOverride');
          done.add('Place: as is');
        }
      }
      if (input['userAgent'] case final String agent) {
        await browser.cdp(tabId, 'Emulation.setUserAgentOverride', {
          'userAgent': agent == 'none' ? '' : agent,
        });
        done.add(
          'User agent: ${agent.isEmpty || agent == 'none' ? 'as is' : agent}',
        );
      }
      if (input['cache'] case final bool cache) {
        await browser.cdp(tabId, 'Network.setCacheDisabled', {
          'cacheDisabled': !cache,
        });
        done.add('Cache: ${cache ? 'on' : 'off'}');
      }
      if (input['javascript'] case final bool on) {
        await browser.cdp(tabId, 'Emulation.setScriptExecutionDisabled', {
          'value': !on,
        });
        done.add(
          'JavaScript: ${on ? 'on' : 'off (reload to see the page without)'}',
        );
      }
      if (input['vision'] case final String vision) {
        await browser.cdp(tabId, 'Emulation.setEmulatedVisionDeficiency', {
          'type': vision,
        });
        done.add('Vision: $vision');
      }
      if (input['viewport'] case final Map view) {
        await browser.cdp(tabId, 'Emulation.setDeviceMetricsOverride', {
          'width': (view['width'] as num?)?.toInt() ?? 0,
          'height': (view['height'] as num?)?.toInt() ?? 0,
          'deviceScaleFactor': view['scale'] ?? 0,
          'mobile': view['mobile'] == true,
        });
        done.add('Viewport: ${view['width']}×${view['height']}');
      }
      if (input['cpu'] case final num rate) {
        await browser.cdp(tabId, 'Emulation.setCPUThrottlingRate', {
          'rate': rate < 1 ? 1 : rate,
        });
        done.add(rate <= 1 ? 'CPU: as is' : 'CPU: ${rate}x slower');
      }
      if (input['network'] case final String network) {
        // DevTools' presets: latency (ms), down and up (bytes a second).
        final (latency, down, up) = switch (network) {
          'slow3g' => (2000, 50000, 50000),
          'fast3g' => (563, 180000, 84375),
          'fast4g' => (165, 1012500, 168750),
          _ => (0, -1, -1),
        };
        await browser.cdp(tabId, 'Network.emulateNetworkConditions', {
          'offline': network == 'offline',
          'latency': latency,
          'downloadThroughput': down,
          'uploadThroughput': up,
        });
        done.add('Network: $network');
      }
      if (input['device'] case final String device) {
        if (device == 'none') {
          await browser.cdp(tabId, 'Emulation.clearDeviceMetricsOverride');
          await browser.cdp(tabId, 'Emulation.setTouchEmulationEnabled', {
            'enabled': false,
          });
        } else {
          final phone = device == 'phone';
          await browser.cdp(tabId, 'Emulation.setDeviceMetricsOverride', {
            'width': phone ? 390 : 820,
            'height': phone ? 844 : 1180,
            'deviceScaleFactor': phone ? 3 : 2,
            'mobile': true,
          });
          await browser.cdp(tabId, 'Emulation.setTouchEmulationEnabled', {
            'enabled': true,
            'maxTouchPoints': 5,
          });
        }
        done.add('Device: $device');
      }
      return done.isEmpty ? 'Nothing asked.' : done.join('\n');
    },
  ),
  ClaudeSdkTool(
    name: 'browser_coverage',
    description:
        "What of a shared tab's style sheets was used, as DevTools' "
        'Coverage panel shows: "reload" (the default) reloads the page and '
        'records its load; "start" and "stop" around what you do. Returns '
        "each sheet's size and how much of it no element used (its rules "
        'never matched), the most unused first; the unused ranges saved to a '
        "file. Scripts' coverage the extension cannot record (DevTools › "
        'Coverage can).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'action': {
          'type': 'string',
          'enum': ['reload', 'start', 'stop'],
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final browser = BrowserTools._browser();
      final tab = BrowserTab(browser, input['tabId'] as int);
      switch (input['action'] as String? ?? 'reload') {
        case 'start':
          await _startCoverage(tab);
          _covering.add(tab);
          return 'Recording coverage. Stop with action "stop".';
        case 'stop':
          if (!_covering.remove(tab)) {
            throw const BrowserError('Not recording: start first.');
          }
          return _stopCoverage(tab);
        default:
          await _startCoverage(tab);
          await BrowserTools._loading(
            browser,
            tab.tabId,
            () => browser.cdp(tab.tabId, 'Page.reload'),
            timeout: const Duration(seconds: 30),
          );
          await Future<void>.delayed(const Duration(seconds: 2));
          return _stopCoverage(tab);
      }
    },
  ),
  ClaudeSdkTool(
    name: 'browser_memory',
    description:
        "A shared tab's memory, as DevTools' Memory panel: \"usage\" (the "
        'default): its JS heap, DOM nodes, listeners, documents; '
        '"snapshot": its live objects (garbage collected first) counted by '
        'constructor, the detached DOM trees still held, and what grew '
        'since the last snapshot (take one, do the thing a few times, take '
        'another: what leaks grows by about as many); "count": the live '
        'objects of a class (`of`: an expression, e.g. "MyStore" or '
        '"HTMLDivElement"); "gc" collects garbage. Sizes and retainers the '
        "extension cannot read (DevTools' heap snapshots can).",
    inputSchema: {
      'type': 'object',
      'properties': {
        'tabId': BrowserTools._tabId,
        'action': {
          'type': 'string',
          'enum': ['usage', 'snapshot', 'count', 'gc'],
        },
        'of': {
          'type': 'string',
          'description':
              '"count": a class (constructor) or prototype, as the page '
              'names it.',
        },
      },
      'required': ['tabId'],
    },
    run: (input, call) async {
      final browser = BrowserTools._browser();
      final tab = BrowserTab(browser, input['tabId'] as int);
      switch (input['action'] as String? ?? 'usage') {
        case 'gc':
          await _queryObjects(tab, '({})', 'function () { return 0; }');
          return 'Collected garbage.\n${await _memoryUsage(tab)}';
        case 'snapshot':
          return _objectSnapshot(tab);
        case 'count':
          final of = (input['of'] as String?)?.trim() ?? '';
          if (of.isEmpty) throw const BrowserError('"count" needs `of`.');
          final count = await _queryObjects(
            tab,
            '(() => { const v = ($of); return typeof v === "function" ? v.prototype : v; })()',
            'function () { return this.length; }',
          );
          return 'Live objects of $of: $count (after collecting garbage).';
        default:
          return _memoryUsage(tab);
      }
    },
  ),
];

/// The emulated media (`''`: its type) of each tab.
final Map<BrowserTab, Map<String, String>> _media = {};

/// The tabs whose coverage is recorded.
final Set<BrowserTab> _covering = {};

Future<void> _startCoverage(BrowserTab tab) async {
  final browser = tab.browser;
  await browser.cdp(tab.tabId, 'DOM.enable');
  await browser.cdp(tab.tabId, 'CSS.enable');
  await browser.cdp(tab.tabId, 'CSS.startRuleUsageTracking');
}

Future<String> _stopCoverage(BrowserTab tab) async {
  final browser = tab.browser;
  final css = await browser.cdp(tab.tabId, 'CSS.stopRuleUsageTracking');
  final rules = (css['ruleUsage'] as List? ?? const []).cast<Map>();
  final bySheet = <String, List<Map>>{};
  for (final r in rules) {
    (bySheet[r['styleSheetId'] as String] ??= []).add(r);
  }
  // Each of the page's own sheets (not the browser's, nor an extension's).
  final sheets = [
    for (final MapEntry(:key, :value)
        in BrowserRecords.instance.styleSheets(tab).entries)
      if ((value['origin'] ?? 'regular') == 'regular' &&
          ((value['length'] as num?) ?? 0) > 0)
        key,
  ];
  final inputs = <(String, String, List<Map>)>[];
  for (final id in sheets) {
    try {
      final text = await browser.cdp(tab.tabId, 'CSS.getStyleSheetText', {
        'styleSheetId': id,
      });
      inputs.add((
        await _sheetName(tab, id),
        text['text'] as String? ?? '',
        bySheet[id] ?? const [],
      ));
    } on Object {
      // Gone with its page.
    }
  }
  final files = await Isolate.run(
    () => [
      for (final (name, text, used) in inputs)
        if (text.trim().isNotEmpty) styleCoverage(name, text, used),
    ],
  );
  if (files.isEmpty) return 'Nothing recorded: the page has no style sheet.';
  files.sort((a, b) => b.unusedSize.compareTo(a.unusedSize));
  String percent(int part, int whole) =>
      whole == 0 ? '0%' : '${(part * 100 / whole).round()}%';
  final size = files.fold(0, (sum, f) => sum + f.size);
  final unused = files.fold(0, (sum, f) => sum + f.unusedSize);

  final folder = Directory(
    p.join(Directory.systemTemp.path, 'caocode-coverage'),
  )..createSync(recursive: true);
  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final file = File(p.join(folder.path, 'coverage-$stamp.json'));
  await file.writeAsString(
    jsonEncode({
      'files': [
        for (final f in files)
          {
            'url': f.url,
            'kind': f.kind,
            'size': f.size,
            'unusedSize': f.unusedSize,
            'unused': [
              for (final (start, end) in f.unused) [start, end],
            ],
            'unusedRules': f.unusedRules,
          },
      ],
    }),
  );
  return [
    'CSS ${_bytes(unused)} of ${_bytes(size)} unused (${percent(unused, size)}): '
        'rules no element matched meanwhile.',
    'Most unused first:',
    for (final f in files.take(25)) ...[
      '  ${percent(f.unusedSize, f.size)} unused — ${_bytes(f.unusedSize)} of '
          '${_bytes(f.size)} — ${_clip(f.url, 200)}',
      if (f.unusedRules.isNotEmpty)
        '    ${_clip(f.unusedRules.take(12).join(' | '), 400)}'
            '${f.unusedRules.length > 12 ? ' | … ${f.unusedRules.length - 12} more' : ''}',
    ],
    if (files.length > 25) '  … ${files.length - 25} more',
    'Unused ranges and rules (offsets in each sheet): ${file.path}',
    "Scripts' coverage: not through the extension (DevTools › Coverage).",
  ].join('\n');
}

Future<String> _memoryUsage(BrowserTab tab) async {
  final result = await tab.browser.cdp(tab.tabId, 'Performance.getMetrics');
  final metrics = {
    for (final m in (result['metrics'] as List? ?? const []).cast<Map>())
      m['name'] as String: m['value'] as num,
  };
  return [
    'JS heap: ${_bytes(metrics['JSHeapUsedSize']?.toInt())} used of '
        '${_bytes(metrics['JSHeapTotalSize']?.toInt())}',
    'DOM nodes: ${metrics['Nodes']?.toInt() ?? '?'}, '
        'listeners: ${metrics['JSEventListeners']?.toInt() ?? '?'}, '
        'documents: ${metrics['Documents']?.toInt() ?? '?'}, '
        'frames: ${metrics['Frames']?.toInt() ?? '?'}',
  ].join('\n');
}

/// The live objects whose prototype chain has what [prototype] (an
/// expression) is, as [function] (called on their array) sees them.
/// Garbage is collected first.
Future<Object?> _queryObjects(
  BrowserTab tab,
  String prototype,
  String function,
) async {
  final browser = tab.browser;
  const group = 'caocode-memory';
  try {
    final found = await browser.cdp(tab.tabId, 'Runtime.evaluate', {
      'expression': prototype,
      'objectGroup': group,
    });
    if (found['exceptionDetails'] case final Map details) {
      throw BrowserError(
        '${(details['exception'] as Map?)?['description'] ?? details['text']}',
      );
    }
    final id = (found['result'] as Map?)?['objectId'] as String?;
    if (id == null) throw const BrowserError('Not an object.');
    final objects = await browser.cdp(tab.tabId, 'Runtime.queryObjects', {
      'prototypeObjectId': id,
      'objectGroup': group,
    }, const Duration(minutes: 2));
    final result = await browser.cdp(tab.tabId, 'Runtime.callFunctionOn', {
      'objectId': (objects['objects'] as Map)['objectId'],
      'functionDeclaration': function,
      'returnByValue': true,
      'objectGroup': group,
    }, const Duration(minutes: 2));
    if (result['exceptionDetails'] case final Map details) {
      throw BrowserError(
        '${(details['exception'] as Map?)?['description'] ?? details['text']}',
      );
    }
    return (result['result'] as Map?)?['value'];
  } finally {
    await browser
        .cdp(tab.tabId, 'Runtime.releaseObjectGroup', {'objectGroup': group})
        .catchError((Object _) => const <String, Object?>{});
  }
}

/// Counts objects by their constructor.
const _countByConstructor = r'''
function () {
  const counts = new Map();
  for (const o of this) {
    let name = typeof o === 'function' ? 'Function' : '(object)';
    try {
      const proto = Object.getPrototypeOf(o);
      const c = proto && Object.prototype.hasOwnProperty.call(proto, 'constructor') ? proto.constructor : null;
      if (typeof c === 'function' && c.name) name = c.name;
    } catch (e) {}
    counts.set(name, (counts.get(name) || 0) + 1);
  }
  return [this.length, [...counts].sort((a, b) => b[1] - a[1]).slice(0, 2000)];
}''';

/// The detached DOM trees: each one's root and how many nodes.
const _detachedTrees = r'''
function () {
  const trees = new Map();
  for (const n of this) {
    let root;
    try {
      // (The prototypes, Element.prototype and the like, are no nodes.)
      if (n.isConnected) continue;
      root = n.getRootNode();
    } catch (e) {
      continue;
    }
    // Not a document's, a template's or a shadow root's: a tree let go of.
    if (root.nodeType === 9 || root.nodeType === 11) continue;
    trees.set(root, true);
  }
  const name = (n) => {
    if (n.nodeType !== 1) return n.nodeName.toLowerCase();
    let s = n.tagName.toLowerCase();
    if (n.id) s += '#' + n.id;
    else if (n.classList.length) s += '.' + Array.from(n.classList).slice(0, 2).join('.');
    const t = (n.textContent || '').replace(/\s+/g, ' ').trim();
    return t ? s + ' "' + t.slice(0, 30) + '"' : s;
  };
  // Its size: its elements (most of them no script holds itself).
  const size = (n) => n.nodeType === 1 ? n.getElementsByTagName('*').length + 1 : 1;
  return [...trees.keys()].map((root) => [name(root), size(root)]).sort((a, b) => b[1] - a[1]);
}''';

/// Each tab's last snapshot: its objects by constructor, how many, its
/// detached elements, and when: what the next is compared with.
final Map<BrowserTab, (Map<String, int>, int, int, DateTime)> _lastObjects = {};

Future<String> _objectSnapshot(BrowserTab tab) async {
  final [total as int, counted as List] =
      await _queryObjects(tab, 'Object.prototype', _countByConstructor) as List;
  final trees = (await _queryObjects(
    tab,
    'Node.prototype',
    _detachedTrees,
  ) as List).cast<List>();
  final counts = {for (final [name, n] in counted) name as String: n as int};
  final detached = trees.fold(0, (sum, t) => sum + (t[1] as int));
  String count(int n) => n.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  final lines = [
    '${count(total)} live objects (after collecting garbage).',
    await _memoryUsage(tab),
    'By constructor:',
    for (final MapEntry(:key, :value) in counts.entries.take(25))
      '  ${count(value)} — $key',
    if (trees.isEmpty)
      'Detached DOM trees: none.'
    else ...[
      'Detached DOM trees still held: ${trees.length} ($detached elements), '
          'a leak if they grow:',
      for (final [root, n] in trees.take(10)) '  $n elements — $root',
    ],
  ];
  final before = _lastObjects[tab];
  _lastObjects[tab] = (counts, total, detached, DateTime.now());
  if (before != null) {
    final (old, oldTotal, oldDetached, at) = before;
    final grew = [
      for (final key in {...counts.keys, ...old.keys})
        (key, (counts[key] ?? 0) - (old[key] ?? 0)),
    ].where((c) => c.$2 > 0).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final all = total - oldTotal;
    final nodes = detached - oldDetached;
    lines
      ..add(
        'Since the snapshot ${DateTime.now().difference(at).inSeconds} s ago: '
        '${all >= 0 ? '+' : ''}${count(all)} objects, '
        '${nodes >= 0 ? '+' : ''}$nodes detached elements.'
        '${grew.isEmpty ? ' Nothing grew.' : ' Grew most:'}',
      )
      ..addAll([
        for (final (name, n) in grew.take(15)) '  +${count(n)} — $name',
      ]);
  }
  return lines.join('\n');
}

String _clip(String text, int max) => text.length > max
    ? '${text.substring(0, max)}… (${text.length} chars)'
    : text;

String _bytes(int? bytes) => switch (bytes) {
  null => '?',
  < 1024 => '$bytes B',
  < 1024 * 1024 => '${(bytes / 1024).toStringAsFixed(1)} kB',
  _ => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB',
};

/// [path] as an agent gave it: from its working directory, or `~/`.
String _path(String path, String? cwd) {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null && (path == '~' || path.startsWith('~/'))) {
    return p.join(home, path.substring(path.length < 2 ? 1 : 2));
  }
  return p.isAbsolute(path) || cwd == null ? path : p.join(cwd, path);
}

const _pictures = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

/// [r] as browser_request says it: its lines, and its response's picture
/// if it is one. Its bodies clipped to [clip].
Future<List<Object>> _describeRequest(
  BrowserTab tab,
  NetworkRequest r,
  int clip,
) async {
  final records = BrowserRecords.instance;
  String headers(Map<String, Object?>? map) => map == null || map.isEmpty
      ? '  (none)'
      : [for (final e in map.entries) '  ${e.key}: ${e.value}'].join('\n');
  final postData = r.hasPostData
      ? await records.requestBody(tab, r) ?? '(not kept)'
      : null;
  final text = [
    '${r.method} ${r.url}',
    'Id: ${r.id}, type: ${r.type}'
        '${r.protocol == null ? '' : ', ${r.protocol}'}'
        '${r.remoteAddress == null ? '' : ', from ${r.remoteAddress}'}'
        '${r.fromServiceWorker ? ', from the service worker' : ''}',
    ...await _initiator(tab, r),
    'Request headers${r.wireRequestHeaders == null ? '' : ' (as sent)'}:',
    headers(r.sentHeaders),
    if (postData != null) 'Request body:\n${_clip(postData, clip)}',
    '',
    if (r.failure != null) 'Failed: ${r.failure}',
    if (r.status != null) 'Status: ${r.status} ${r.statusText ?? ''}',
    if (r.duration case final ms?)
      'Time: $ms ms, ${_bytes(r.size)}${_phases(r)}',
    if (r.receivedHeaders != null) 'Response headers:',
    if (r.receivedHeaders != null) headers(r.receivedHeaders),
  ];
  if (r.type == 'WebSocket' || r.type == 'EventSource') {
    text.addAll(_frames(r, clip));
    return [text.join('\n')];
  }
  if (r.failure != null || r.status == null || !r.finished) {
    return [text.join('\n')];
  }
  final body = await records.responseBody(tab, r);
  if (body == null) {
    text.add('Response body: not kept by the browser.');
  } else if (!body.base64) {
    text.add('Response body:\n${_clip(body.data, clip)}');
  } else if (_pictures.contains(r.mimeType)) {
    return [
      '${text.join('\n')}\nResponse body:',
      claudeSdkImage(body.data, r.mimeType!),
    ];
  } else {
    text.add('Response body: binary, ${_bytes(body.data.length * 3 ~/ 4)}.');
  }
  return [text.join('\n')];
}

/// What made [r]: the parser (a tag of a page), or a script (its calls,
/// mapped to the sources).
Future<List<String>> _initiator(BrowserTab tab, NetworkRequest r) async {
  final initiator = r.initiator;
  if (initiator == null) return const [];
  final type = initiator['type'] as String? ?? 'other';
  final stack = ScriptFrame.stackOf(initiator['stack'], max: 8);
  if (stack.isNotEmpty) {
    return [
      'Made by a script${type == 'script' ? '' : ' ($type)'}:',
      ...await _stackLines(tab, stack, indent: '  ', max: 8),
    ];
  }
  final url = initiator['url'] as String?;
  if (url == null || url.isEmpty) return ['Made by: $type'];
  final line = (initiator['lineNumber'] as num?)?.toInt();
  return ['Made by: $type, $url${line == null ? '' : ':${line + 1}'}'];
}

/// [r]'s phases, as DevTools' Timing tab has them.
String _phases(NetworkRequest r) {
  final t = r.timing;
  if (t == null) return '';
  double at(String key) => (t[key] as num?)?.toDouble() ?? -1;
  String span(String name, String start, String end) {
    final from = at(start);
    final to = at(end);
    if (from < 0 || to < 0 || to <= from) return '';
    return '$name ${(to - from).round()}';
  }

  final phases = [
    span('DNS', 'dnsStart', 'dnsEnd'),
    span('connect', 'connectStart', 'connectEnd'),
    span('TLS', 'sslStart', 'sslEnd'),
    span('waiting (TTFB)', 'sendEnd', 'receiveHeadersEnd'),
  ].where((s) => s.isNotEmpty).toList();
  final headers = at('receiveHeadersEnd');
  if (r.duration case final total? when headers >= 0) {
    // The browser's request started at requestTime; the record's at its own.
    final started = ((t['requestTime'] as num? ?? r.start) - r.start) * 1000;
    final download = total - started - headers;
    if (download > 0) phases.add('download ${download.round()}');
  }
  return phases.isEmpty ? '' : ' (${phases.join(', ')} ms)';
}

/// A WebSocket's or an EventSource's messages, the last of them.
List<String> _frames(NetworkRequest r, int clip) {
  if (r.frames.isEmpty) return ['', 'No message yet.'];
  final shown = r.frames.length > 100
      ? r.frames.sublist(r.frames.length - 100)
      : r.frames;
  final each = (clip ~/ shown.length).clamp(200, 2000);
  final first = r.frames.first.timestamp;
  return [
    '',
    'Messages (${r.frames.length + r.framesDropped}'
        '${shown.length < r.frames.length + r.framesDropped ? ', the last ${shown.length}' : ''}; '
        '↑ sent, ↓ received; seconds from the first):',
    for (final f in shown)
      '  ${f.sent ? '↑' : '↓'} ${(f.timestamp - first).toStringAsFixed(3)}s '
          '${switch (f.opcode) {
            -1 => 'error: ${f.error}',
            2 => 'binary ${_bytes(f.length * 3 ~/ 4)}',
            8 => 'close',
            9 => 'ping',
            10 => 'pong',
            _ => '${f.event == null ? '' : '[${f.event}] '}${_clip(f.payload, each)}',
          }}',
  ];
}

/// The headers a page's fetch may not set: the browser's own.
const _forbidden = {
  'accept-charset',
  'accept-encoding',
  'access-control-request-headers',
  'access-control-request-method',
  'connection',
  'content-length',
  'cookie',
  'cookie2',
  'date',
  'dnt',
  'expect',
  'host',
  'keep-alive',
  'origin',
  'referer',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'via',
};

bool _forbiddenHeader(String name) {
  final lower = name.toLowerCase();
  return _forbidden.contains(lower) ||
      lower.startsWith(':') ||
      lower.startsWith('sec-') ||
      lower.startsWith('proxy-');
}

/// Sends [r] again from its page (its cookies, its origin), changed by
/// [changes]: what came back.
Future<String> _replay(
  BrowserTab tab,
  NetworkRequest r,
  Map<String, Object?> changes,
) async {
  final body = changes.containsKey('body')
      ? changes['body'] as String?
      : await BrowserRecords.instance.requestBody(tab, r);
  final method = (changes['method'] as String? ?? r.method).toUpperCase();
  final headers = <String, String>{};
  final dropped = <String>[];
  for (final MapEntry(:key, :value) in r.sentHeaders.entries) {
    if (_forbiddenHeader(key)) {
      dropped.add(key);
    } else {
      headers[key] = '$value';
    }
  }
  if (changes['headers'] case final Map changed) {
    for (final MapEntry(:key, :value) in changed.entries) {
      headers.removeWhere((k, _) => k.toLowerCase() == '$key'.toLowerCase());
      if (value != null) headers['$key'] = '$value';
    }
  }
  final url = changes['url'] as String? ?? r.url;
  final script =
      '''
(async () => {
  const started = performance.now();
  const response = await fetch(${jsonEncode(url)}, {
    method: ${jsonEncode(method)},
    headers: ${jsonEncode(headers)},
    ${method == 'GET' || method == 'HEAD' || body == null ? '' : 'body: ${jsonEncode(body)},'}
    credentials: 'include',
    cache: 'no-store',
  });
  const text = await response.text();
  return {
    status: response.status,
    statusText: response.statusText,
    headers: Array.from(response.headers.entries()),
    body: text,
    ms: Math.round(performance.now() - started),
  };
})()''';
  final value =
      await BrowserTools._evaluate(tab.browser, tab.tabId, script) as Map;
  return [
    '$method $url',
    if (dropped.isNotEmpty)
      '(the browser sets ${dropped.join(', ')} itself: its cookies are sent)',
    'Status: ${value['status']} ${value['statusText']} in ${value['ms']} ms',
    'Response headers:',
    for (final h in (value['headers'] as List).cast<List>())
      '  ${h[0]}: ${h[1]}',
    'Response body:',
    _clip('${value['body']}', 30000),
    '(browser_network lists it too.)',
  ].join('\n');
}

String _shellQuote(String text) => "'${text.replaceAll("'", r"'\''")}'";

/// [r] as a curl command, as DevTools' Copy as cURL writes it.
String _asCurl(NetworkRequest r, String? body) => [
  'curl ${_shellQuote(r.url)}',
  if (r.method != 'GET' && !(r.method == 'POST' && body != null))
    '-X ${r.method}',
  for (final MapEntry(:key, :value) in r.sentHeaders.entries)
    if (!key.startsWith(':') && key.toLowerCase() != 'content-length')
      for (final line in '$value'.split('\n'))
        '-H ${_shellQuote('$key: $line')}',
  if (body != null) '--data-raw ${_shellQuote(body)}',
  if (r.sentHeaders.keys.any((k) => k.toLowerCase() == 'accept-encoding'))
    '--compressed',
].join(' \\\n  ');

/// [r] as a fetch call, as DevTools' Copy as fetch writes it.
String _asFetch(NetworkRequest r, String? body) {
  final headers = {
    for (final MapEntry(:key, :value) in r.sentHeaders.entries)
      if (!_forbiddenHeader(key)) key: '$value',
  };
  return 'fetch(${jsonEncode(r.url)}, '
      '${const JsonEncoder.withIndent('  ').convert({'method': r.method, 'headers': headers, 'body': ?body, 'credentials': 'include'})});';
}

/// Saves [requests] to [path] as a HAR file (1.2), as DevTools' Network
/// panel exports them: with their bodies, those the browser still has.
Future<String> _saveHar(
  BrowserTab tab,
  List<NetworkRequest> requests,
  String path,
) async {
  final records = BrowserRecords.instance;
  // A header the protocol joins with new lines (Set-Cookie): one each.
  List<Map<String, String>> headers(Map<String, Object?>? map) => [
    for (final MapEntry(:key, :value) in (map ?? const {}).entries)
      for (final line in '$value'.split('\n')) {'name': key, 'value': line},
  ];
  String? header(Map<String, Object?>? map, String name) {
    for (final MapEntry(:key, :value) in (map ?? const {}).entries) {
      if (key.toLowerCase() == name) return '$value';
    }
    return null;
  }

  var bodies = 0;
  var lost = 0;
  final entries = <Map<String, Object?>>[];
  for (final r in requests) {
    final postData = await records.requestBody(tab, r);
    final body = r.finished && r.failure == null && r.status != null
        ? await records.responseBody(tab, r)
        : null;
    if (body != null) {
      bodies++;
    } else if (r.finished && r.failure == null && r.status != null) {
      lost++;
    }
    final uri = Uri.tryParse(r.url);
    entries.add({
      'startedDateTime': DateTime.fromMillisecondsSinceEpoch(
        (r.wall * 1000).round(),
      ).toUtc().toIso8601String(),
      'time': r.duration ?? 0,
      'request': {
        'method': r.method,
        'url': r.url,
        'httpVersion': r.protocol ?? '',
        'cookies': const [],
        'headers': headers(r.sentHeaders),
        'queryString': [
          if (uri != null)
            for (final MapEntry(:key, :value) in uri.queryParametersAll.entries)
              for (final v in value) {'name': key, 'value': v},
        ],
        if (postData != null)
          'postData': {
            'mimeType': header(r.sentHeaders, 'content-type') ?? '',
            'text': postData,
          },
        'headersSize': -1,
        'bodySize': postData == null ? 0 : utf8.encode(postData).length,
      },
      'response': {
        'status': r.status ?? 0,
        'statusText': r.statusText ?? r.failure ?? '',
        'httpVersion': r.protocol ?? '',
        'cookies': const [],
        'headers': headers(r.receivedHeaders),
        'content': {
          'size': body == null
              ? -1
              : body.base64
              ? body.data.length * 3 ~/ 4
              : utf8.encode(body.data).length,
          'mimeType': r.mimeType ?? '',
          if (body != null) 'text': body.data,
          if (body != null && body.base64) 'encoding': 'base64',
        },
        'redirectURL': header(r.responseHeaders, 'location') ?? '',
        'headersSize': -1,
        'bodySize': r.size ?? -1,
        if (r.failure != null) '_error': r.failure,
      },
      'cache': const {},
      'timings': _harTimings(r),
      if (r.remoteAddress case final address?)
        'serverIPAddress': address.substring(0, address.lastIndexOf(':')),
      '_resourceType': r.type.toLowerCase(),
      '_requestId': r.id,
      '_initiator': ?r.initiator,
      if (r.frames.isNotEmpty)
        '_webSocketMessages': [
          for (final f in r.frames)
            {
              'type': f.sent ? 'send' : 'receive',
              'time': r.wallOf(f),
              'opcode': f.opcode,
              'data': f.payload,
              'event': ?f.event,
            },
        ],
    });
  }
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(
    jsonEncode({
      'log': {
        'version': '1.2',
        'creator': {'name': 'Caocode', 'version': '1'},
        'pages': const [],
        'entries': entries,
      },
    }),
  );
  return [
    'Saved ${entries.length} requests to ${file.path} '
        '(${_bytes(file.lengthSync())}).',
    'Response bodies: $bodies saved'
        '${lost == 0 ? '' : ', $lost no longer kept by the browser'}.',
    'Entries: .log.entries[] {request: {method, url, headers, postData}, '
        'response: {status, headers, content: {mimeType, text, encoding}}, '
        '_resourceType, _requestId}.',
  ].join('\n');
}

/// [r]'s phases as a HAR's timings: -1 for those it did not go through.
Map<String, num> _harTimings(NetworkRequest r) {
  final t = r.timing;
  final total = r.duration ?? 0;
  if (t == null) return {'send': 0, 'wait': total, 'receive': 0};
  num span(String start, String end) {
    final from = (t[start] as num?) ?? -1;
    final to = (t[end] as num?) ?? -1;
    return from < 0 || to < 0 ? -1 : (to - from).clamp(0, 1 << 31);
  }

  final send = span('sendStart', 'sendEnd');
  final wait = span('sendEnd', 'receiveHeadersEnd');
  final headers = (t['receiveHeadersEnd'] as num?) ?? 0;
  return {
    'blocked': (t['dnsStart'] as num? ?? -1) > 0 ? t['dnsStart'] as num : -1,
    'dns': span('dnsStart', 'dnsEnd'),
    'connect': span('connectStart', 'connectEnd'),
    'ssl': span('sslStart', 'sslEnd'),
    'send': send < 0 ? 0 : send,
    'wait': wait < 0 ? 0 : wait,
    'receive': (total - headers).clamp(0, 1 << 31),
  };
}

/// A recording of a tab's: its trace events as they come, then what they
/// say.
class _Trace {
  _Trace._(this.tab);

  final BrowserTab tab;
  final List<Object?> _events = [];
  final _complete = Completer<void>();
  StreamSubscription<BrowserEvent>? _subscription;
  late final double _started;

  static final Map<BrowserTab, _Trace> _recording = {};

  static _Trace? of(BrowserTab tab) => _recording[tab];

  /// The categories of DevTools' Performance panel.
  static const _categories = [
    '-*',
    'blink.console',
    'blink.user_timing',
    'devtools.timeline',
    'disabled-by-default-devtools.timeline',
    'disabled-by-default-devtools.timeline.frame',
    'disabled-by-default-devtools.timeline.stack',
    'disabled-by-default-v8.cpu_profiler',
    'latencyInfo',
    'loading',
    'toplevel',
    'v8.execute',
  ];

  static Future<_Trace> start(BrowserTab tab) async {
    if (_recording.remove(tab) case final old?) {
      await old._end().catchError((Object _) {});
    }
    final trace = _Trace._(tab);
    trace._subscription = BrowserBridge.instance.events.listen((event) {
      if (event.event != 'cdp' ||
          !identical(event.connection, tab.browser) ||
          event.tabId != tab.tabId) {
        return;
      }
      final params = event.message['params'] as Map?;
      switch (event.message['method']) {
        case 'Tracing.dataCollected':
          trace._events.addAll(params?['value'] as List? ?? const []);
        case 'Tracing.tracingComplete':
          if (!trace._complete.isCompleted) trace._complete.complete();
      }
    });
    trace._started = DateTime.now().millisecondsSinceEpoch / 1000;
    await tab.browser.cdp(tab.tabId, 'Tracing.start', {
      'transferMode': 'ReportEvents',
      'traceConfig': {
        'recordMode': 'recordAsMuchAsPossible',
        'includedCategories': _categories.where((c) => c != '-*').toList(),
        'excludedCategories': ['*'],
      },
    });
    _recording[tab] = trace;
    return trace;
  }

  Future<void> _end() async {
    try {
      await tab.browser.cdp(tab.tabId, 'Tracing.end');
      await _complete.future.timeout(const Duration(seconds: 30));
    } finally {
      await _subscription?.cancel();
    }
  }

  /// The CPU profile in the trace (its `ProfileChunk`s): the busiest
  /// thread's, as one profile.
  Map? _cpuProfile() {
    final profiles =
        <String, ({List<Map> nodes, List<int> samples, List<num> deltas})>{};
    for (final e in _events.whereType<Map>()) {
      if (e['name'] != 'ProfileChunk') continue;
      final data = ((e['args'] as Map?)?['data'] as Map?) ?? const {};
      final cpu = data['cpuProfile'] as Map? ?? const {};
      final p = profiles['${e['pid']}:${e['id']}'] ??= (
        nodes: [],
        samples: [],
        deltas: [],
      );
      p.nodes.addAll((cpu['nodes'] as List? ?? const []).cast<Map>());
      p.samples.addAll((cpu['samples'] as List? ?? const []).cast<int>());
      p.deltas.addAll((data['timeDeltas'] as List? ?? const []).cast<num>());
    }
    if (profiles.isEmpty) return null;
    final busiest = profiles.values.reduce(
      (a, b) => a.samples.length >= b.samples.length ? a : b,
    );
    return {
      'nodes': busiest.nodes,
      'samples': busiest.samples,
      'timeDeltas': busiest.deltas,
    };
  }

  Future<String> stop() async {
    _recording.remove(tab);
    await _end();
    final profile = _cpuProfile();
    final browser = tab.browser;
    final metrics = await browser.cdp(tab.tabId, 'Performance.getMetrics');
    final vitals = await BrowserTools._evaluate(
      browser,
      tab.tabId,
      _vitalsScript,
    );
    final file = await _save('trace', {'traceEvents': _events});
    final cpu = profile == null
        ? null
        : await _save('cpu', profile, '.cpuprofile');
    return [
      ...await _summarizeVitals(vitals),
      '',
      ..._summarizeMetrics(metrics),
      '',
      ..._summarizeMainThread(),
      if (profile != null) ...['', ...await _summarizeCpu(profile)],
      '',
      ..._summarizeRequests(),
      '',
      'Trace: ${file.path} (${_bytes(file.lengthSync())}; DevTools ›'
          ' Performance › Load profile opens it)',
      if (cpu != null) 'CPU profile: ${cpu.path}',
    ].join('\n');
  }

  Future<File> _save(
    String kind,
    Object? data, [
    String extension = '.json',
  ]) async {
    final folder = Directory(
      p.join(Directory.systemTemp.path, 'caocode-traces'),
    )..createSync(recursive: true);
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File(p.join(folder.path, '$kind-$stamp$extension'));
    await file.writeAsString(jsonEncode(data));
    return file;
  }

  /// The functions that took the CPU's time, by their own (self) and with
  /// what they called (total).
  Future<List<String>> _summarizeCpu(Map profile) async {
    final summary = CpuSummary.of(profile);
    final busy = summary.all - summary.idle;
    // The page's own: not the browser's (no URL) nor its extensions'.
    final functions = summary.functions
        .where(
          (f) =>
              f.function.url.isNotEmpty &&
              !f.function.url.startsWith('chrome-extension://') &&
              f.total > 0,
        )
        .toList();
    String ms(double v) =>
        v < 10 ? '${v.toStringAsFixed(1)} ms' : '${v.round()} ms';
    return [
      'CPU: busy ${ms(busy)} (scripts ${ms(busy - summary.garbage - summary.program)}, '
          'garbage collection ${ms(summary.garbage)}, the browser ${ms(summary.program)}). '
          '${functions.isEmpty ? 'No script of the page ran.' : 'Most time (self, total):'}',
      for (final f in functions.take(12))
        await _locatedCall(
          tab,
          f.function.name,
          f.function.url,
          f.function.line,
          f.function.column,
          definition: true,
        ).then((c) => '  ${ms(f.self)}, ${ms(f.total)} — ${c.name} (${c.at})'),
    ];
  }

  static const _vitalsScript = r'''
new Promise((done) => {
  const out = {};
  try {
    new PerformanceObserver((list) => {
      const entries = list.getEntries();
      const last = entries[entries.length - 1];
      if (last) { out.lcp = last.startTime; out.lcpElement = last.element ? last.element.tagName.toLowerCase() + (last.element.id ? '#' + last.element.id : '') : (last.url || ''); }
    }).observe({ type: 'largest-contentful-paint', buffered: true });
  } catch (e) {}
  const name = (n) => {
    if (!n || n.nodeType !== 1) return n && n.nodeName ? n.nodeName.toLowerCase() : '';
    let s = n.tagName.toLowerCase();
    if (n.id) s += '#' + n.id;
    else if (n.classList && n.classList.length) s += '.' + Array.from(n.classList).slice(0, 2).join('.');
    const t = (n.innerText || n.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
    return t ? s + ' "' + t.slice(0, 40) + '"' : s;
  };
  let cls = 0;
  const shifts = [];
  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        if (e.hadRecentInput) continue;
        cls += e.value;
        shifts.push({ value: e.value, at: e.startTime, nodes: (e.sources || []).map((s) => name(s.node)).filter(Boolean).slice(0, 3) });
      }
    }).observe({ type: 'layout-shift', buffered: true });
  } catch (e) {}
  // Interactions: each one's slowest event (its time to the next paint).
  const interactions = new Map();
  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        if (!e.interactionId) continue;
        const old = interactions.get(e.interactionId);
        if (!old || e.duration > old.duration) interactions.set(e.interactionId, {
          duration: e.duration, type: e.name, target: name(e.target), at: e.startTime,
          input: e.processingStart - e.startTime, processing: e.processingEnd - e.processingStart,
          presentation: e.startTime + e.duration - e.processingEnd,
        });
      }
    }).observe({ type: 'event', buffered: true, durationThreshold: 16 });
  } catch (e) {}
  const frames = [];
  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) frames.push({
        duration: e.duration, blocking: e.blockingDuration, at: e.startTime,
        scripts: (e.scripts || []).sort((a, b) => b.duration - a.duration).slice(0, 3).map((s) => ({
          duration: s.duration, invoker: s.invoker, source: s.sourceURL, fn: s.sourceFunctionName, char: s.sourceCharPosition,
        })),
      });
    }).observe({ type: 'long-animation-frame', buffered: true });
  } catch (e) {}
  const nav = performance.getEntriesByType('navigation')[0];
  const fcp = performance.getEntriesByName('first-contentful-paint')[0];
  setTimeout(() => {
    const slow = Array.from(interactions.values()).sort((a, b) => b.duration - a.duration);
    done({
      lcp: out.lcp, lcpElement: out.lcpElement, cls,
      shifts: shifts.sort((a, b) => b.value - a.value).slice(0, 5),
      // INP: the worst, or near it with many.
      inp: slow.length ? slow[Math.min(Math.floor(slow.length / 50), slow.length - 1)].duration : undefined,
      interactions: slow.slice(0, 5), interactionCount: slow.length,
      frames: frames.sort((a, b) => b.duration - a.duration).slice(0, 5), frameCount: frames.length,
      fcp: fcp && fcp.startTime,
      ttfb: nav && nav.responseStart,
      domContentLoaded: nav && nav.domContentLoadedEventEnd,
      load: nav && nav.loadEventEnd,
      transferSize: nav && nav.transferSize,
      resources: performance.getEntriesByType('resource').length,
    });
  }, 100);
})
''';

  static String _ms(Object? value) =>
      value is num ? '${value.round()} ms' : '—';

  Future<List<String>> _summarizeVitals(Object? value) async {
    final v = (value as Map?)?.cast<String, Object?>() ?? {};
    String rate(num? value, num good, num poor) => value == null
        ? ''
        : value <= good
        ? ' (good)'
        : value <= poor
        ? ' (needs improvement)'
        : ' (poor)';
    final cls = v['cls'] as num?;
    final inp = v['inp'] as num?;
    final shifts = (v['shifts'] as List? ?? const []).cast<Map>();
    final interactions = (v['interactions'] as List? ?? const []).cast<Map>();
    final frames = (v['frames'] as List? ?? const []).cast<Map>();
    return [
      'Web Vitals (of the page as loaded):',
      '  LCP: ${_ms(v['lcp'])}${rate(v['lcp'] as num?, 2500, 4000)}'
          '${v['lcpElement'] is String && (v['lcpElement'] as String).isNotEmpty ? ' — ${v['lcpElement']}' : ''}',
      '  CLS: ${cls == null ? '—' : cls.toStringAsFixed(3)}${rate(cls, 0.1, 0.25)}',
      for (final s in shifts.take(3))
        if ((s['nodes'] as List? ?? const []).isNotEmpty)
          '    shifted ${(s['value'] as num).toStringAsFixed(3)} at ${_ms(s['at'])}: '
              '${(s['nodes'] as List).join(', ')}',
      if (inp != null)
        '  INP: ${_ms(inp)}${rate(inp, 200, 500)} — of ${v['interactionCount']} interactions',
      for (final i in interactions.take(3))
        '    ${i['type']} on ${i['target']} at ${_ms(i['at'])}: ${_ms(i['duration'])} '
            '(input delay ${_ms(i['input'])}, handlers ${_ms(i['processing'])}, '
            'to paint ${_ms(i['presentation'])})',
      '  FCP: ${_ms(v['fcp'])}${rate(v['fcp'] as num?, 1800, 3000)}',
      '  TTFB: ${_ms(v['ttfb'])}${rate(v['ttfb'] as num?, 800, 1800)}',
      '  DOMContentLoaded: ${_ms(v['domContentLoaded'])}, load: ${_ms(v['load'])}',
      '  Resources: ${v['resources'] ?? '—'}',
      if (frames.isNotEmpty) ...[
        '',
        'Long animation frames (${v['frameCount']}; the longest, and what ran in them):',
        for (final f in frames)
          '  at ${_ms(f['at'])}: ${_ms(f['duration'])} (blocking ${_ms(f['blocking'])})'
              '${[for (final s in (f['scripts'] as List? ?? const []).cast<Map>()) ' — ${_ms(s['duration'])} ${s['invoker'] ?? ''}${'${s['fn'] ?? ''}'.isEmpty ? '' : ' ${s['fn']}'}${'${s['source'] ?? ''}'.isEmpty ? '' : ' (${_clip('${s['source']}', 120)}, char ${s['char']})'}'].join(';')}',
      ],
    ];
  }

  static List<String> _summarizeMetrics(Map<String, Object?> result) {
    final metrics = {
      for (final m in (result['metrics'] as List? ?? const []).cast<Map>())
        m['name'] as String: m['value'] as num,
    };
    String seconds(String name) =>
        metrics[name] == null ? '—' : '${(metrics[name]! * 1000).round()} ms';
    return [
      'Page now:',
      '  JS heap: ${_bytes(metrics['JSHeapUsedSize']?.toInt())} used of '
          '${_bytes(metrics['JSHeapTotalSize']?.toInt())}',
      '  DOM nodes: ${metrics['Nodes']?.toInt() ?? '—'}, listeners: '
          '${metrics['JSEventListeners']?.toInt() ?? '—'}, frames: '
          '${metrics['Frames']?.toInt() ?? '—'}',
      '  Since the page opened: script ${seconds('ScriptDuration')}, layout '
          '${seconds('LayoutDuration')} (${metrics['LayoutCount']?.toInt() ?? '—'}x), '
          'style ${seconds('RecalcStyleDuration')} '
          '(${metrics['RecalcStyleCount']?.toInt() ?? '—'}x)',
    ];
  }

  /// What the page's main thread did: busy time by kind, and its long
  /// tasks (50 ms or more), each with what took longest in it.
  List<String> _summarizeMainThread() {
    final events = _events.whereType<Map>().toList();
    // The page's main thread: the renderer's busiest.
    final mains = <(int, int)>{
      for (final e in events)
        if (e['ph'] == 'M' &&
            e['name'] == 'thread_name' &&
            (e['args'] as Map?)?['name'] == 'CrRendererMain')
          (e['pid'] as int, e['tid'] as int),
    };
    final busy = <(int, int), num>{};
    for (final e in events) {
      if (e['ph'] != 'X' || e['name'] != 'RunTask') continue;
      final thread = (e['pid'] as int, e['tid'] as int);
      if (!mains.contains(thread)) continue;
      busy[thread] = (busy[thread] ?? 0) + (e['dur'] as num? ?? 0);
    }
    if (busy.isEmpty) return ['Main thread: nothing recorded.'];
    final main = busy.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final onMain = [
      for (final e in events)
        if (e['ph'] == 'X' &&
            e['pid'] == main.$1 &&
            e['tid'] == main.$2 &&
            e['dur'] is num)
          e,
    ]..sort((a, b) => (a['ts'] as num).compareTo(b['ts'] as num));

    const kinds = {
      'Scripting': {
        'FunctionCall',
        'EvaluateScript',
        'v8.compile',
        'v8.compileModule',
        'EventDispatch',
        'TimerFire',
        'FireAnimationFrame',
        'FireIdleCallback',
        'RunMicrotasks',
        'V8.GCScavenger',
        'MajorGC',
        'MinorGC',
      },
      'Rendering': {
        'Layout',
        'UpdateLayoutTree',
        'PrePaint',
        'Paint',
        'Layerize',
        'Commit',
        'ScrollLayer',
        'IntersectionObserverController::computeIntersections',
      },
      'Parsing': {'ParseHTML', 'ParseAuthorStyleSheet'},
    };
    String? kindOf(String name) {
      for (final MapEntry(:key, :value) in kinds.entries) {
        if (value.contains(name)) return key;
      }
      return null;
    }

    // Each kind's outermost events alone: not counted twice nested.
    final totals = <String, num>{};
    num covered = 0;
    for (final e in onMain) {
      final kind = kindOf(e['name'] as String);
      if (kind == null) continue;
      final ts = e['ts'] as num;
      if (ts < covered) continue;
      totals[kind] = (totals[kind] ?? 0) + (e['dur'] as num);
      covered = ts + (e['dur'] as num);
    }
    String ms(num micros) => '${(micros / 1000).round()} ms';
    final tasks = [
      for (final e in onMain)
        if (e['name'] == 'RunTask' && (e['dur'] as num) >= 50000) e,
    ]..sort((a, b) => (b['dur'] as num).compareTo(a['dur'] as num));
    final first = onMain.first['ts'] as num;

    Map data(Map e) => ((e['args'] as Map?)?['data'] as Map?) ?? const {};
    bool located(Map e) {
      final d = data(e);
      return (d['url'] is String && (d['url'] as String).isNotEmpty) ||
          (d['functionName'] is String &&
              (d['functionName'] as String).isNotEmpty);
    }

    /// What took longest in [task]: the longest of the code it ran that
    /// says where it is (a script's URL, a function), else of any kind.
    String what(Map task) {
      final start = task['ts'] as num;
      final end = start + (task['dur'] as num);
      Map? longest;
      Map? located0;
      for (final e in onMain) {
        final ts = e['ts'] as num;
        if (ts < start || ts >= end || identical(e, task)) continue;
        if (kindOf(e['name'] as String) == null) continue;
        final dur = e['dur'] as num;
        if (longest == null || dur > (longest['dur'] as num)) longest = e;
        if (located(e) &&
            (located0 == null || dur > (located0['dur'] as num))) {
          located0 = e;
        }
      }
      longest = located0 ?? longest;
      if (longest == null) return '';
      final data0 = data(longest);
      final where = [
        if (data0['functionName'] case final String f when f.isNotEmpty) f,
        if (data0['url'] case final String u when u.isNotEmpty)
          // The trace's lines count from 1.
          '${_clip(u, 120)}${data0['lineNumber'] is int ? ':${data0['lineNumber']}' : ''}',
        if (data0['type'] case final String t when t.isNotEmpty) t,
      ].join(' ');
      return ' — ${longest['name']} ${ms(longest['dur'] as num)}'
          '${where.isEmpty ? '' : ' ($where)'}';
    }

    return [
      'Main thread: busy ${ms(busy[main]!)}; '
          '${['Scripting', 'Rendering', 'Parsing'].map((k) => '${k.toLowerCase()} ${ms(totals[k] ?? 0)}').join(', ')}',
      if (tasks.isEmpty) '  No long task (50 ms or more).',
      if (tasks.isNotEmpty)
        '  Long tasks (${tasks.length}; total blocking '
            '${ms(tasks.fold<num>(0, (sum, t) => sum + (t['dur'] as num) - 50000))}):',
      for (final task in tasks.take(10))
        '  at ${ms((task['ts'] as num) - first)}: ${ms(task['dur'] as num)}'
            '${what(task)}',
    ];
  }

  List<String> _summarizeRequests() {
    final requests = BrowserRecords.instance
        .requests(tab)
        .where((r) => r.duration != null)
        .toList();
    // Those of the recording: the browser's clock is not the wall's, so by
    // the order they came in, the last of them (since it started).
    final during = requests.where((r) => r.wall >= _started).toList()
      ..sort((a, b) => b.duration!.compareTo(a.duration!));
    if (during.isEmpty) return ['Requests: none recorded.'];
    final total = during.fold<int>(0, (sum, r) => sum + (r.size ?? 0));
    return [
      'Requests: ${during.length}, ${_bytes(total)} over the network. '
          'Slowest:',
      for (final r in during.take(5))
        '  ${r.duration} ms ${r.status ?? r.failure ?? ''} ${r.type} '
            '${_bytes(r.size)} ${_clip(r.url, 200)} (${r.id})',
    ];
  }
}
