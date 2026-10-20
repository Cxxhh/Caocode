import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/sse.dart';
import '../util/json.dart';
import '../util/processes.dart';
import 'jsonrpc.dart';

/// How an MCP server's messages travel.
abstract class McpTransport {
  /// The messages it sends.
  Stream<Map<String, Object?>> get messages;

  Future<void> start();

  Future<void> send(Map<String, Object?> message);

  Future<void> close();

  /// What went wrong, as far as it can tell (a process's last words).
  String? get detail => null;
}

/// A server run as a process, one JSON message a line on its stdin and
/// stdout.
class StdioTransport extends McpTransport {
  StdioTransport({
    required this.command,
    this.arguments = const [],
    this.environment = const {},
    this.workingDirectory,
  });

  final String command;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? workingDirectory;

  Process? _process;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  final List<String> _stderr = [];

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  String? get detail => _stderr.isEmpty ? null : _stderr.join('\n');

  @override
  Future<void> start() async {
    final process = await Process.start(
      command,
      arguments,
      environment: environment,
      includeParentEnvironment: false,
      workingDirectory: workingDirectory,
      runInShell: Platform.isWindows,
    );
    _process = process;
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            try {
              final decoded = jsonDecode(line);
              if (decoded is Map) {
                _messages.add(decoded.cast<String, Object?>());
              } else if (decoded is List) {
                for (final item in decoded) {
                  if (item is Map) _messages.add(item.cast<String, Object?>());
                }
              }
            } on FormatException {
              _note(line);
            }
          },
          onDone: () {
            if (!_messages.isClosed) _messages.close();
          },
        );
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_note);
    unawaited(
      process.exitCode.then((code) {
        if (code != 0) _note('Process exited with code $code');
      }),
    );
  }

  void _note(String line) {
    _stderr.add(line);
    if (_stderr.length > 20) _stderr.removeAt(0);
  }

  @override
  Future<void> send(Map<String, Object?> message) async {
    final process = _process;
    if (process == null) throw const JsonRpcError('Not started');
    process.stdin.writeln(jsonEncode(message));
  }

  @override
  Future<void> close() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    try {
      await process.stdin.close();
    } on Object {
      // Gone already.
    }
    final exited = await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
    if (exited == -1) await killTree(process.pid);
  }
}

/// Supplies the headers a request to a server signs in with.
typedef HeaderSource = Future<Map<String, String>> Function();

/// The server answered 401: the user is to sign in.
class McpUnauthorized implements Exception {
  const McpUnauthorized(this.url, {this.resourceMetadata});

  final Uri url;

  /// Where the server says its sign-in is described
  /// (`WWW-Authenticate: Bearer resource_metadata="…"`).
  final Uri? resourceMetadata;

  @override
  String toString() => 'Authentication required for $url';
}

HttpClient _httpClient(Map<String, String> environment) => HttpClient()
  ..connectionTimeout = const Duration(seconds: 30)
  ..findProxy = (url) =>
      HttpClient.findProxyFromEnvironment(url, environment: environment);

Uri? _resourceMetadata(HttpClientResponse response) {
  final header = response.headers.value(HttpHeaders.wwwAuthenticateHeader);
  if (header == null) return null;
  final match = RegExp(r'resource_metadata="([^"]+)"').firstMatch(header);
  return match == null ? null : Uri.tryParse(match[1]!);
}

/// A server over Streamable HTTP: each message POSTed, answered with JSON
/// or an event stream.
class StreamableHttpTransport extends McpTransport {
  StreamableHttpTransport(
    this.url, {
    this.headers = const {},
    this.auth,
    this.environment = const {},
  });

  final Uri url;
  final Map<String, String> headers;
  final HeaderSource? auth;
  final Map<String, String> environment;

  late final HttpClient _client = _httpClient(environment);
  String? _sessionId;
  String? _protocolVersion;
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  set protocolVersion(String version) => _protocolVersion = version;

  @override
  Future<void> start() async {}

  @override
  Future<void> send(Map<String, Object?> message) async {
    final request = await _client.postUrl(url);
    request.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    for (final MapEntry(:key, :value) in headers.entries) {
      request.headers.set(key, value);
    }
    if (auth case final auth?) {
      for (final MapEntry(:key, :value) in (await auth()).entries) {
        request.headers.set(key, value);
      }
    }
    if (_sessionId case final id?) request.headers.set('mcp-session-id', id);
    if (_protocolVersion case final version?) {
      request.headers.set('mcp-protocol-version', version);
    }
    request.add(utf8.encode(jsonEncode(message)));
    final response = await request.close();
    if (response.headers.value('mcp-session-id') case final id?) {
      _sessionId = id;
    }
    if (response.statusCode == 401) {
      await response.drain<void>();
      throw McpUnauthorized(url, resourceMetadata: _resourceMetadata(response));
    }
    if (response.statusCode == 202 || response.statusCode == 204) {
      await response.drain<void>();
      return;
    }
    if (response.statusCode >= 400) {
      final body = await response.transform(utf8.decoder).join();
      // The session expired: a new one is started by the next initialize.
      if (response.statusCode == 404 && _sessionId != null) _sessionId = null;
      throw JsonRpcError(
        'HTTP ${response.statusCode}: ${body.length > 300 ? body.substring(0, 300) : body}',
        code: response.statusCode,
      );
    }
    final type = response.headers.contentType?.mimeType ?? '';
    if (type == 'text/event-stream') {
      // Read on its own: a long call's answer comes when it comes.
      unawaited(
        response
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const SseDecoder())
            .forEach((event) {
              if (event.json case final data?) _messages.add(data);
            })
            .catchError((Object error) {}),
      );
      return;
    }
    final body = await response.transform(utf8.decoder).join();
    if (body.trim().isEmpty) return;
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      _messages.add(decoded.cast<String, Object?>());
    } else if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) _messages.add(item.cast<String, Object?>());
      }
    }
  }

  @override
  Future<void> close() async {
    if (_sessionId case final id?) {
      try {
        final request = await _client.deleteUrl(url);
        request.headers.set('mcp-session-id', id);
        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        await response.drain<void>();
      } on Object {
        // Gone with it.
      }
    }
    _client.close(force: true);
    if (!_messages.isClosed) await _messages.close();
  }
}

/// A server over the older HTTP+SSE transport: an event stream to read, and
/// an endpoint it names to POST to.
class SseTransport extends McpTransport {
  SseTransport(
    this.url, {
    this.headers = const {},
    this.auth,
    this.environment = const {},
  });

  final Uri url;
  final Map<String, String> headers;
  final HeaderSource? auth;
  final Map<String, String> environment;

  late final HttpClient _client = _httpClient(environment);
  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();
  Uri? _endpoint;
  StreamSubscription<SseEvent>? _subscription;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  Future<Map<String, String>> _headers() async => {
    ...headers,
    if (auth != null) ...await auth!(),
  };

  @override
  Future<void> start() async {
    final request = await _client.getUrl(url);
    request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
    for (final MapEntry(:key, :value) in (await _headers()).entries) {
      request.headers.set(key, value);
    }
    final response = await request.close();
    if (response.statusCode == 401) {
      await response.drain<void>();
      throw McpUnauthorized(url, resourceMetadata: _resourceMetadata(response));
    }
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw JsonRpcError(
        'HTTP ${response.statusCode}',
        code: response.statusCode,
      );
    }
    final endpoint = Completer<Uri>();
    _subscription = response
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const SseDecoder())
        .listen(
          (event) {
            if (event.event == 'endpoint') {
              if (!endpoint.isCompleted) {
                endpoint.complete(url.resolve(event.data.trim()));
              }
              return;
            }
            if (event.json case final data?) _messages.add(data);
          },
          onError: (Object error) {
            if (!endpoint.isCompleted) endpoint.completeError(error);
          },
          onDone: () {
            if (!_messages.isClosed) _messages.close();
          },
        );
    _endpoint = await endpoint.future.timeout(const Duration(seconds: 30));
  }

  @override
  Future<void> send(Map<String, Object?> message) async {
    final endpoint = _endpoint;
    if (endpoint == null) throw const JsonRpcError('Not connected');
    final request = await _client.postUrl(endpoint);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    for (final MapEntry(:key, :value) in (await _headers()).entries) {
      request.headers.set(key, value);
    }
    request.add(utf8.encode(jsonEncode(message)));
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode == 401) {
      throw McpUnauthorized(url, resourceMetadata: _resourceMetadata(response));
    }
    if (response.statusCode >= 400) {
      throw JsonRpcError(
        'HTTP ${response.statusCode}',
        code: response.statusCode,
      );
    }
  }

  @override
  Future<void> close() async {
    // The connection first: a stream the server holds open is not let go
    // of by cancelling it alone.
    _client.close(force: true);
    await _subscription?.cancel().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    if (!_messages.isClosed) await _messages.close();
  }
}

/// A server of the host's own: its messages go through the control
/// channel (`mcp_message`).
class SdkTransport extends McpTransport {
  SdkTransport(this.name, this._request);

  final String name;

  /// Sends a control request to the host and waits for its answer.
  final Future<Map<String, Object?>> Function(
    String subtype,
    Map<String, Object?> fields,
  )
  _request;

  final StreamController<Map<String, Object?>> _messages =
      StreamController.broadcast();

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> send(Map<String, Object?> message) async {
    final response = await _request('mcp_message', {
      'server_name': name,
      'message': message,
    });
    final answer = asMap(response['mcp_response']);
    if (answer.isNotEmpty && message.containsKey('id')) _messages.add(answer);
  }

  @override
  Future<void> close() async {
    if (!_messages.isClosed) await _messages.close();
  }
}
