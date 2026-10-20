// The debugging history end to end, in a real browser (see
// browser_bridge_live_test.dart): a shared tab's page, requests and console
// kept with no agent looking, its secrets not; the bodies and the user's
// steps once detailed; read back with browser_history; cleared. Run by hand:
//
//   BAO_BROWSER_LIVE="/path/to/Google Chrome for Testing" \
//     flutter test test/browser/browser_history_live_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:caocode/browser/browser_bridge.dart';
import 'package:caocode/browser/browser_tools.dart';
import 'package:caocode/kernel/claude_code/claude_sdk_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final chrome = Platform.environment['BAO_BROWSER_LIVE'];
  final host = p.absolute(
    'build/macos/Build/Products/Debug/Caocode.app/Contents/MacOS/'
    'caocode-browser-host',
  );

  test(
    "a shared tab's history is kept, read back, and cleared",
    () async {
      final profile = Directory.systemTemp.createTempSync('bao-history-');
      addTearDown(() => profile.deleteSync(recursive: true));
      final hosts = Directory(p.join(profile.path, 'NativeMessagingHosts'))
        ..createSync();
      File(p.join(hosts.path, '${BrowserBridge.hostName}.json'))
          .writeAsStringSync(
            jsonEncode({
              'name': BrowserBridge.hostName,
              'description': 'Caocode',
              'path': host,
              'type': 'stdio',
              'allowed_origins': [
                for (final id in BrowserBridge.extensionIds)
                  'chrome-extension://$id/',
              ],
            }),
          );
      final kept = p.join(profile.path, 'history');
      BrowserHistory.folderOverride = kept;
      addTearDown(() => BrowserHistory.folderOverride = null);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/api/save') {
          final body = await utf8.decodeStream(request);
          response
            ..statusCode = 500
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'db down', 'got': body}));
        } else {
          response.headers.contentType = ContentType.html;
          response.write('''
<!doctype html><title>Notes</title>
<input id=who placeholder="Name">
<input id=pw type=password>
<button id=save style="margin: 20px; width: 80px; height: 30px">Save</button>
<div id=out></div>
<script>
document.getElementById('save').addEventListener('click', async () => {
  console.log('saving', who.value);
  const r = await fetch('/api/save', {
    method: 'POST',
    headers: {'Authorization': 'Bearer s3cret-token', 'Content-Type': 'application/json'},
    body: JSON.stringify({name: who.value}),
  });
  if (!r.ok) {
    console.error('Save failed: ' + r.status);
    out.textContent = 'failed';
  }
});
</script>
''');
        }
        await response.close();
      });
      final page = 'http://127.0.0.1:${server.port}/';

      final sockets = Directory('/tmp').createTempSync('bao-');
      addTearDown(() => sockets.deleteSync(recursive: true));
      BrowserBridge.socketFolder = sockets.path;
      final bridge = BrowserBridge.instance;
      final history = BrowserHistory.instance;
      history.start();
      addTearDown(history.stop);
      await bridge.start();
      BrowserTools.register();
      final browser = await Process.start(
        chrome!,
        [
          '--user-data-dir=${profile.path}',
          '--load-extension=${p.absolute('browser_extension')}',
          '--disable-features=DisableLoadExtensionCommandLineSwitch',
          '--no-first-run',
          '--no-default-browser-check',
          '--window-size=1000,700',
          'about:blank',
        ],
        environment: {'TMPDIR': sockets.path, 'XDG_RUNTIME_DIR': sockets.path},
      );
      addTearDown(() {
        browser.kill();
        unawaited(bridge.stop());
      });
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (bridge.browsers.isEmpty && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(bridge.browsers, isNotEmpty, reason: 'the extension connects');
      final connection = bridge.browsers.first;

      var id = 0;
      Future<String> call(String name, Map<String, Object?> input) async {
        final answer = await ClaudeSdkTools.handle({
          'jsonrpc': '2.0',
          'id': ++id,
          'method': 'tools/call',
          'params': {'name': name, 'arguments': input},
        }, ClaudeSdkCall(cwd: profile.path));
        final result = answer['result'] as Map;
        final text = (result['content'] as List)
            .cast<Map>()
            .where((c) => c['type'] == 'text')
            .map((c) => c['text'])
            .join('\n');
        // ignore: avoid_print
        print('── $name ${jsonEncode(input)}\n$text');
        expect(result['isError'] == true, isFalse, reason: '$name: $text');
        return text;
      }

      Future<void> until(Future<bool> Function() done) async {
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (!await done()) {
          if (DateTime.now().isAfter(end)) fail('timed out');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      final opened = await call('browser_open', {'url': page});
      final tabId = int.parse(RegExp(r'\[(\d+)\]').firstMatch(opened)![1]!);
      Future<Object?> evaluate(String expression) async {
        final result = await connection.cdp(tabId, 'Runtime.evaluate', {
          'expression': expression,
          'returnByValue': true,
        });
        return (result['result'] as Map?)?['value'];
      }

      // The user's own clicks and typing: the browser's, trusted.
      Future<void> click(String selector) async {
        final box = await evaluate(
          'JSON.stringify(document.querySelector("$selector")'
          '.getBoundingClientRect())',
        ) as String;
        final rect = jsonDecode(box) as Map;
        final x = (rect['x'] as num) + (rect['width'] as num) / 2;
        final y = (rect['y'] as num) + (rect['height'] as num) / 2;
        for (final type in ['mousePressed', 'mouseReleased']) {
          await connection.cdp(tabId, 'Input.dispatchMouseEvent', {
            'type': type,
            'x': x,
            'y': y,
            'button': 'left',
            'clickCount': 1,
          });
        }
      }

      Future<void> type(String selector, String text) async {
        await click(selector);
        await connection.cdp(tabId, 'Input.insertText', {'text': text});
      }

      // Not detailed: the page, the failed request and the error, but not
      // the log, the bodies, the token, nor the steps.
      await type('#who', 'Ada');
      await click('#save');
      await until(() async => await evaluate('out.textContent') == 'failed');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final timeline = await call('browser_history', {'tabId': tabId});
      expect(timeline, contains('page $page — "Notes"'));
      expect(timeline, contains('POST 500 Fetch'));
      expect(timeline, contains('console error: Save failed: 500'));
      expect(timeline, isNot(contains('saving')));
      expect(timeline, isNot(contains('user click')));
      expect(timeline, contains('Detailed history is off'));
      final requestId = RegExp(r'POST 500 .*\((\S+)\)')
          .firstMatch(timeline)![1]!;
      final whole = await call('browser_history', {'id': requestId});
      expect(whole, isNot(contains('s3cret-token')));
      expect(whole, contains('(not kept: '));
      expect(whole, contains('detailed history was off'));
      final failed = await call('browser_history', {'failed': true});
      expect(failed, contains('POST 500'));
      expect(failed, isNot(contains('page http')));

      // Detailed: the bodies, every log, the user's steps (no password).
      history.detailed = true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await evaluate('out.textContent = ""');
      await type('#who', ' Lovelace');
      await type('#pw', 'hunter2');
      await click('#save');
      await until(() async => await evaluate('out.textContent') == 'failed');
      await Future<void>.delayed(const Duration(milliseconds: 800));
      final detailed = await call('browser_history', {
        'tabId': tabId,
        'since': '1m',
      });
      expect(detailed, contains('console log: saving Ada Lovelace'));
      expect(detailed, contains('user click'));
      expect(detailed, contains('Lovelace'));
      expect(detailed, isNot(contains('hunter2')));
      expect(detailed, isNot(contains('Detailed history is off')));
      final last = RegExp(r'POST 500 .*\((\S+)\)')
          .allMatches(detailed)
          .last[1]!;
      final bodies = await call('browser_history', {'id': last});
      expect(bodies, contains('Request body:\n{"name":"Ada Lovelace"}'));
      expect(bodies, contains('Response body:'));
      expect(bodies, contains('db down'));
      final query = await call('browser_history', {'query': 'db down'});
      expect(query, contains('POST 500'));

      // Closed, the tab's file ends; still read back after.
      await call('browser_close', {'tabId': tabId});
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final files = Directory(kept)
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(files, hasLength(1));
      final lines = files.single.readAsLinesSync();
      expect(jsonDecode(lines.first)['t'], 'tab');
      expect(jsonDecode(lines.last)['t'], 'end');
      expect(
        await call('browser_history', {
          'kinds': ['request'],
        }),
        contains('POST 500'),
      );

      expect(history.size, greaterThan(0));
      await history.clear();
      expect(history.size, 0);
      expect(Directory(kept).existsSync(), isFalse);
      expect(
        await call('browser_history', {}),
        startsWith('Nothing kept from'),
      );
    },
    skip: chrome == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
