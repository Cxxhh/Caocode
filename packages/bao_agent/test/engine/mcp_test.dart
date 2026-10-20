import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart';
import 'package:bao_agent/src/mcp/jsonrpc.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// An MCP server over HTTP that wants its users signed in (OAuth with
/// PKCE), asks them things while it works, and changes its tools; and one
/// over the older HTTP+SSE transport.
class _Servers {
  _Servers._(this._http);

  static Future<_Servers> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final servers = _Servers._(http);
    http.listen(servers._handle);
    return servers;
  }

  final HttpServer _http;
  String get base => 'http://127.0.0.1:${_http.port}';

  /// The tokens it takes, as it gave them.
  final Set<String> tokens = {};

  /// Each token a request to `/mcp` came with.
  final List<String?> seen = [];
  String? challenge;
  bool added = false;
  final Map<String, Completer<Map<String, Object?>>> _answers = {};
  HttpResponse? _sse;

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    Future<void> json(Object value, {int status = 200}) async {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(value));
      await response.close();
    }

    switch ((request.method, path)) {
      case ('GET', '/.well-known/oauth-protected-resource/mcp'):
        return json({
          'resource': '$base/mcp',
          'authorization_servers': [base],
          'scopes_supported': ['mcp'],
        });
      case ('GET', '/.well-known/oauth-authorization-server'):
        return json({
          'issuer': base,
          'authorization_endpoint': '$base/authorize',
          'token_endpoint': '$base/token',
          'registration_endpoint': '$base/register',
        });
      case ('POST', '/register'):
        final body = jsonDecode(await utf8.decodeStream(request)) as Map;
        expect(body['redirect_uris'], isNotEmpty);
        return json({'client_id': 'client-1'});
      case ('POST', '/token'):
        final form = Uri.splitQueryString(await utf8.decodeStream(request));
        if (form['grant_type'] == 'authorization_code') {
          final digest = base64Url
              .encode(
                sha256.convert(ascii.encode(form['code_verifier']!)).bytes,
              )
              .replaceAll('=', '');
          if (form['code'] != 'good-code' || digest != challenge) {
            return json({'error': 'invalid_grant'}, status: 400);
          }
          tokens.add('at1');
          return json({
            'access_token': 'at1',
            'refresh_token': 'rt1',
            'expires_in': 1,
          });
        }
        if (form['refresh_token'] == 'rt1') {
          tokens.add('at2');
          return json({'access_token': 'at2', 'expires_in': 3600});
        }
        return json({'error': 'invalid_grant'}, status: 400);
      case ('POST', '/mcp'):
        return _mcp(request);
      case ('DELETE', '/mcp'):
        response.statusCode = 200;
        return response.close();
      case ('GET', '/sse'):
        response.headers.contentType = ContentType('text', 'event-stream');
        response.bufferOutput = false;
        response.write('event: endpoint\ndata: /messages?session=1\n\n');
        await response.flush();
        _sse = response;
        return;
      case ('POST', '/messages'):
        final message = jsonDecode(await utf8.decodeStream(request)) as Map;
        response.statusCode = 202;
        await response.close();
        final id = message['id'];
        if (id == null || message['method'] == null) return;
        final result = switch (message['method']) {
          'initialize' => {
            'protocolVersion': '2024-11-05',
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'old', 'version': '1'},
          },
          'tools/list' => {
            'tools': [
              {
                'name': 'echo',
                'description': 'Echoes',
                'inputSchema': {'type': 'object'},
              },
            ],
          },
          'tools/call' => {
            'content': [
              {
                'type': 'text',
                'text':
                    'echo ${jsonEncode((message['params'] as Map)['arguments'])}',
              },
            ],
          },
          _ => <String, Object?>{},
        };
        _sse?.write(
          'event: message\ndata: ${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n\n',
        );
        await _sse?.flush();
        return;
    }
    response.statusCode = 404;
    await response.close();
  }

  Future<void> _mcp(HttpRequest request) async {
    final response = request.response;
    final auth = request.headers.value('authorization');
    final token = auth?.replaceFirst('Bearer ', '');
    seen.add(token);
    if (token == null || !tokens.contains(token)) {
      await utf8.decodeStream(request);
      response.statusCode = 401;
      response.headers.set(
        'www-authenticate',
        'Bearer resource_metadata="$base/.well-known/oauth-protected-resource/mcp"',
      );
      return response.close();
    }
    final message = (jsonDecode(await utf8.decodeStream(request)) as Map)
        .cast<String, Object?>();
    final id = message['id'];
    final method = message['method'];
    if (method == null) {
      // An answer to one of its own requests.
      _answers
          .remove('$id')
          ?.complete((message['result'] as Map? ?? {}).cast());
      response.statusCode = 202;
      return response.close();
    }
    if (id == null) {
      response.statusCode = 202;
      return response.close();
    }
    response.headers.set('mcp-session-id', 'session-1');
    Future<void> json(Object result) async {
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
      );
      await response.close();
    }

    switch (method) {
      case 'initialize':
        return json({
          'protocolVersion': '2025-06-18',
          'capabilities': {
            'tools': {'listChanged': true},
          },
          'serverInfo': {'name': 'secure', 'version': '1'},
        });
      case 'tools/list':
        return json({
          'tools': [
            {
              'name': 'ask',
              'description': 'Asks the user',
              'inputSchema': {'type': 'object'},
            },
            if (added)
              {
                'name': 'added',
                'description': 'New',
                'inputSchema': {'type': 'object'},
              },
          ],
        });
      case 'tools/call':
        // Its answer as an event stream, the server's own requests first.
        response.headers.contentType = ContentType('text', 'event-stream');
        response.bufferOutput = false;
        Future<Map<String, Object?>> ask(
          String key,
          String method,
          Map<String, Object?> params,
        ) async {
          final answer = _answers[key] = Completer();
          response.write(
            'data: ${jsonEncode({'jsonrpc': '2.0', 'id': key, 'method': method, 'params': params})}\n\n',
          );
          await response.flush();
          return answer.future;
        }

        final roots = await ask('s1', 'roots/list', {});
        final name = await ask('s2', 'elicitation/create', {
          'message': 'Your name?',
          'requestedSchema': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
            },
          },
        });
        added = true;
        response.write(
          'data: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/tools/list_changed'})}\n\n',
        );
        response.write(
          'data: ${jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'content': [
                {'type': 'text', 'text': 'Hello ${(name['content'] as Map)['name']}; ${(roots['roots'] as List).length} root'},
              ],
            },
          })}\n\n',
        );
        return response.close();
    }
    return json({});
  }
}

void main() {
  late Harness h;
  late _Servers servers;

  setUp(() async => servers = await _Servers.start());
  tearDown(() async {
    await h.dispose();
    await servers.close();
  });

  Future<Map<String, Object?>> statusOf(String name) async {
    final status = await h.request('mcp_status');
    return (status['mcpServers'] as List)
        .cast<Map>()
        .firstWhere((s) => s['name'] == name)
        .cast();
  }

  test('signed in with OAuth, then a call that asks the user', () async {
    h = await Harness.start(
      flagSettings: {
        'mcpServers': {
          'secure': {'type': 'http', 'url': '${servers.base}/mcp'},
        },
      },
    );
    expect((await statusOf('secure'))['status'], 'needs-auth');
    final auth = await h.request('mcp_authenticate', {'serverName': 'secure'});
    final url = Uri.parse('${auth['authUrl']}');
    expect(url.path, '/authorize');
    expect(url.queryParameters, containsPair('client_id', 'client-1'));
    expect(url.queryParameters, containsPair('code_challenge_method', 'S256'));
    expect(url.queryParameters, containsPair('scope', 'mcp'));
    servers.challenge = url.queryParameters['code_challenge'];
    // The browser comes back with the code.
    final callback = Uri.parse(url.queryParameters['redirect_uri']!).replace(
      queryParameters: {
        'code': 'good-code',
        'state': url.queryParameters['state'],
      },
    );
    final client = HttpClient();
    final page = await (await client.getUrl(callback)).close();
    expect(await utf8.decodeStream(page), contains('Signed in to secure'));
    client.close();
    for (
      var i = 0;
      i < 100 && (await statusOf('secure'))['status'] != 'connected';
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect((await statusOf('secure'))['status'], 'connected');
    // Its first token had expired: refreshed before it was used.
    expect(servers.seen.whereType<String>(), everyElement('at2'));

    final elicited = <Map<String, Object?>>[];
    h.onRequest = (request) async {
      if (request['subtype'] != 'elicitation') return const {};
      elicited.add(request);
      return {
        'action': 'accept',
        'content': {'name': 'Ada'},
      };
    };
    h.model.script.addAll([
      Reply.tool('mcp__secure__ask', {}),
      Reply.text('ok'),
    ]);
    await h.turn('ask');
    expect(
      jsonEncode(h.toolResults.single['content']),
      contains('Hello Ada; 1 root'),
    );
    expect(
      elicited.single,
      allOf(
        containsPair('mcp_server_name', 'secure'),
        containsPair('message', 'Your name?'),
      ),
    );
    // It said its tools changed: the next turn has the new one.
    for (var i = 0; i < 50 && !servers.added; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    h.model.script.add(Reply.text('ok'));
    await h.turn('again');
    final tools = [
      for (final t in h.model.turns.last.body['tools'] as List)
        (t as Map)['name'],
    ];
    expect(tools, contains('mcp__secure__added'));
  });

  test('the older HTTP+SSE transport', () async {
    h = await Harness.start(
      flagSettings: {
        'mcpServers': {
          'old': {'type': 'sse', 'url': '${servers.base}/sse'},
        },
      },
    );
    h.model.script.addAll([
      Reply.tool('mcp__old__echo', {'say': 'hi'}),
      Reply.text('ok'),
    ]);
    await h.turn('echo');
    expect(
      jsonEncode(h.toolResults.single['content']),
      contains('echo {\\"say\\":\\"hi\\"}'),
    );
  });

  test('a server that cannot start is failed, with why', () async {
    h = await Harness.start(
      flagSettings: {
        'mcpServers': {
          'broken': {'command': '/no/such/program'},
          'nothing': {'type': 'http', 'url': 'http://127.0.0.1:1/mcp'},
        },
      },
    );
    final broken = await statusOf('broken');
    expect(broken['status'], 'failed');
    expect((await statusOf('nothing'))['status'], 'failed');
    expect(
      () => h.request('mcp_toggle', {'serverName': 'none', 'enabled': false}),
      throwsStateError,
    );
  });

  group('JsonRpcPeer', () {
    test(
      'requests answered, failed, timed out, cancelled; requests answered',
      () async {
        h = await Harness.start();
        late JsonRpcPeer other;
        final peer = JsonRpcPeer(
          (m) async => scheduleMicrotask(() => other.receive(m)),
        );
        final notes = <String>[];
        other = JsonRpcPeer(
          (m) async => scheduleMicrotask(() => peer.receive(m)),
          onRequest: (method, params) async {
            switch (method) {
              case 'add':
                return {'sum': (params['a'] as int) + (params['b'] as int)};
              case 'fail':
                throw const JsonRpcError('no', code: 7);
              case 'slow':
                await Future<void>.delayed(const Duration(seconds: 5));
                return {};
            }
            throw StateError('boom');
          },
          onNotification: (method, _) => notes.add(method),
        );
        expect(await peer.request('add', {'a': 2, 'b': 3}), {'sum': 5});
        await expectLater(
          peer.request('fail'),
          throwsA(isA<JsonRpcError>().having((e) => e.code, 'code', 7)),
        );
        await expectLater(peer.request('other'), throwsA(isA<JsonRpcError>()));
        await expectLater(
          peer.request('slow', null, const Duration(milliseconds: 50)),
          throwsA(
            isA<JsonRpcError>().having(
              (e) => e.message,
              'message',
              contains('timed out'),
            ),
          ),
        );
        final cancel = CancelToken();
        final pending = peer.request('slow', null, null, cancel);
        cancel.cancel('stop');
        await expectLater(pending, throwsA(isA<Cancelled>()));
        await Future<void>.delayed(Duration.zero);
        expect(notes, contains('notifications/cancelled'));
        peer.close('done');
        await expectLater(peer.request('add'), throwsA(isA<JsonRpcError>()));
        expect(peer.closed, isTrue);
        expect('${const JsonRpcError('x', code: 401)}', 'x (code 401)');
        expect(const JsonRpcError('x', code: 401).unauthorized, isTrue);
      },
    );
  });
}
