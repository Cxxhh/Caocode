// What MCP servers give back, as the model is given it: pictures, resources,
// sounds; what a server over HTTP says when it fails or wants a sign-in;
// the variables in a server's settings; and only the servers given, when
// asked for (`--strict-mcp-config`).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// A server over HTTP: its tools' answers made by [call]; its listings as
/// a batch (a JSON array), as a server may send them.
class _Server {
  _Server._(this._http, this.call);

  static Future<_Server> start(
    Object? Function(String tool, HttpResponse response) call,
  ) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _Server._(http, call);
    http.listen(server._handle);
    return server;
  }

  final HttpServer _http;
  final Object? Function(String tool, HttpResponse response) call;
  int get port => _http.port;

  /// The headers each request came with.
  final List<HttpHeaders> headers = [];

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    headers.add(request.headers);
    final response = request.response;
    final body = jsonDecode(await utf8.decodeStream(request)) as Map;
    final id = body['id'];
    if (id == null) {
      response.statusCode = 202;
      return response.close();
    }
    Object? result;
    switch (body['method']) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-06-18',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'media', 'version': '1'},
        };
      case 'tools/list':
        response.headers.contentType = ContentType.json;
        response.write(
          jsonEncode([
            {
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'tools': [
                  for (final name in ['media', 'broken', 'gated'])
                    {
                      'name': name,
                      'description': name,
                      'inputSchema': {'type': 'object'},
                    },
                ],
              },
            },
          ]),
        );
        return response.close();
      case 'tools/call':
        result = call((body['params'] as Map)['name'] as String, response);
        if (result == null) return response.close();
      default:
        result = <String, Object?>{};
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
    await response.close();
  }
}

void main() {
  late Harness h;
  late _Server server;

  setUp(() async {
    server = await _Server.start((tool, response) {
      switch (tool) {
        case 'media':
          return {
            'content': [
              {
                'type': 'image',
                'mimeType': 'image/png',
                'data': 'iVBORw0KGgo=',
              },
              {'type': 'image', 'mimeType': 'image/x-icon', 'data': 'AAAB'},
              {
                'type': 'resource',
                'resource': {'uri': 'mem://a', 'text': 'resource text'},
              },
              {
                'type': 'resource',
                'resource': {
                  'uri': 'mem://b',
                  'mimeType': 'application/pdf',
                  'blob': 'JVBERi0=',
                },
              },
              {
                'type': 'resource_link',
                'name': 'docs',
                'uri': 'https://x/docs',
              },
              {'type': 'audio', 'mimeType': 'audio/wav', 'data': 'UklGRg=='},
              {'type': 'hologram', 'depth': 3},
            ],
          };
        case 'broken':
          response
            ..statusCode = 500
            ..write('kaput');
          return null;
        case 'gated':
          response.statusCode = 401;
          return null;
      }
      return null;
    });
  });

  tearDown(() async {
    await h.dispose();
    await server.close();
  });

  Future<Map<String, Object?>> statusOf(String name) async {
    final status = await h.request('mcp_status');
    return (status['mcpServers'] as List)
        .cast<Map>()
        .firstWhere((s) => s['name'] == name)
        .cast();
  }

  test('pictures, resources, links and sounds, as the model takes them; '
      'its variables filled in', () async {
    h = await Harness.start(
      environment: {'MEDIA_PORT': '${server.port}'},
      flagSettings: {
        'mcpServers': {
          'media': {
            'type': 'http',
            'url': r'http://127.0.0.1:${MEDIA_PORT}/mcp',
            'headers': {
              'X-Token': r'${MEDIA_TOKEN:-fallback-token}',
              'X-Port': r'${MEDIA_PORT}',
            },
          },
        },
      },
    );
    h.model.script.addAll([
      Reply.tool('mcp__media__media', {}),
      Reply.text('ok'),
    ]);
    await h.turn('show me');
    final content = h.toolResults.single['content'];
    if (content is! List) fail('$content');
    final image = content.cast<Map>().firstWhere((b) => b['type'] == 'image');
    expect(image['source'], {
      'type': 'base64',
      'media_type': 'image/png',
      'data': 'iVBORw0KGgo=',
    });
    final text = jsonEncode(content);
    expect(text, contains('[Image of type image/x-icon]'));
    expect(text, contains('resource text'));
    expect(text, contains('[Resource mem://b (application/pdf)]'));
    expect(text, contains('[Resource link: docs https://x/docs]'));
    expect(text, contains('[Audio of type audio/wav]'));
    expect(text, contains('hologram'));
    expect(server.headers.last.value('x-token'), 'fallback-token');
    expect(server.headers.last.value('x-port'), '${server.port}');
  });

  test('a call the server fails; a server that wants a sign-in', () async {
    h = await Harness.start(
      flagSettings: {
        'mcpServers': {
          'media': {
            'type': 'http',
            'url': 'http://127.0.0.1:${server.port}/mcp',
          },
        },
      },
    );
    h.model.script.addAll([
      Reply.tool('mcp__media__broken', {}),
      Reply.tool('mcp__media__gated', {}),
      Reply.text('ok'),
    ]);
    await h.turn('try');
    final [broken, gated] = h.toolResults;
    expect(broken['is_error'], isTrue);
    expect(jsonEncode(broken['content']), contains('HTTP 500: kaput'));
    expect(gated['is_error'], isTrue);
    expect((await statusOf('media'))['status'], 'needs-auth');
  });

  test('only the servers given, and the host\'s, when strict', () async {
    h = await Harness.start(
      strictMcpConfig: true,
      sdkServers: ['host'],
      files: {
        '.mcp.json': jsonEncode({
          'mcpServers': {
            'project': {'command': 'never-run'},
          },
        }),
      },
      flagSettings: {
        'mcpServers': {
          'media': {
            'type': 'http',
            'url': 'http://127.0.0.1:${server.port}/mcp',
          },
        },
      },
    );
    // The host's own server, answered by the host.
    h.onRequest = (request) async {
      if (request['subtype'] != 'mcp_message') return const {};
      final message = request['message'] as Map;
      return {
        'mcp_response': {
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': switch (message['method']) {
            'initialize' => {
              'protocolVersion': '2025-06-18',
              'capabilities': {'tools': {}},
              'serverInfo': {'name': 'host', 'version': '1'},
            },
            'tools/list' => {'tools': []},
            _ => {},
          },
        },
      };
    };
    final status = await h.request('mcp_status');
    final names = [
      for (final s in (status['mcpServers'] as List).cast<Map>()) s['name'],
    ];
    expect(names, unorderedEquals(['media', 'host']));
  });
}
