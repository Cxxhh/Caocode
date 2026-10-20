import 'dart:convert';

import '../util/json.dart';

/// A content block of the answer, finished: its place in the message and
/// the block as the API would have sent it whole.
class FinishedBlock {
  const FinishedBlock(this.index, this.block);

  final int index;
  final Map<String, Object?> block;

  String get type => block['type'] as String? ?? '';
}

/// Puts a streamed answer together from its events: the message's id,
/// model and usage, and each content block once it is done.
class MessageAccumulator {
  String? id;
  String? model;
  String? requestId;
  String? stopReason;
  Map<String, Object?> usage = {};
  final Map<int, Map<String, Object?>> _open = {};
  final Map<int, StringBuffer> _json = {};
  final Map<int, Map<String, Object?>> _done = {};
  bool _started = false;
  bool _stopped = false;

  /// Whether the message has begun.
  bool get started => _started;

  /// Whether `message_stop` came.
  bool get stopped => _stopped;

  /// The blocks done so far, in order.
  List<Map<String, Object?>> get content {
    final indexes = _done.keys.toList()..sort();
    return [for (final i in indexes) _done[i]!];
  }

  /// The blocks begun and not done (a message cut off).
  Iterable<int> get openBlocks => _open.keys;

  /// What a block begun and not done looks like so far.
  Map<String, Object?>? partial(int index) => _open[index];

  /// Takes [event]; returns the block it finishes, if it does.
  FinishedBlock? add(Map<String, Object?> event) {
    switch (event['type']) {
      case 'message_start':
        final message = asMap(event['message']);
        _started = true;
        id = message['id'] as String?;
        model = message['model'] as String?;
        requestId = message['_request_id'] as String?;
        usage = {...asMap(message['usage'])};
      case 'content_block_start':
        final index = asInt(event['index']) ?? _open.length + _done.length;
        final block = {...asMap(event['content_block'])};
        switch (block['type']) {
          case 'text':
            block['text'] = block['text'] ?? '';
          case 'thinking':
            block['thinking'] = block['thinking'] ?? '';
          case 'tool_use' || 'server_tool_use' || 'mcp_tool_use':
            _json[index] = StringBuffer();
        }
        _open[index] = block;
      case 'content_block_delta':
        final index = asInt(event['index']);
        final block = index == null ? null : _open[index];
        if (block == null) return null;
        final delta = asMap(event['delta']);
        switch (delta['type']) {
          case 'text_delta':
            block['text'] = '${block['text'] ?? ''}${delta['text'] ?? ''}';
          case 'thinking_delta':
            block['thinking'] =
                '${block['thinking'] ?? ''}${delta['thinking'] ?? ''}';
          case 'signature_delta':
            block['signature'] =
                '${block['signature'] ?? ''}${delta['signature'] ?? ''}';
          case 'input_json_delta':
            _json[index]?.write(delta['partial_json'] ?? '');
          case 'citations_delta':
            block['citations'] = [
              ...asList(block['citations']),
              delta['citation'],
            ];
        }
      case 'content_block_stop':
        final index = asInt(event['index']);
        final block = index == null ? null : _open.remove(index);
        if (block == null) return null;
        if (_json.remove(index) case final json?) {
          block['input'] = _decodeInput(json.toString(), block['input']);
        }
        _done[index!] = block;
        return FinishedBlock(index, block);
      case 'message_delta':
        final delta = asMap(event['delta']);
        stopReason = delta['stop_reason'] as String? ?? stopReason;
        for (final MapEntry(:key, :value) in asMap(event['usage']).entries) {
          if (value != null) usage[key] = value;
        }
      case 'message_stop':
        _stopped = true;
    }
    return null;
  }

  static Map<String, Object?> _decodeInput(String json, Object? fallback) {
    if (json.trim().isEmpty) return asMap(fallback);
    try {
      return asMap(jsonDecode(json));
    } on FormatException {
      return {'_unparsed': json};
    }
  }

  /// The whole message, as the API would have sent it unstreamed.
  Map<String, Object?> message() => {
    'id': id,
    'type': 'message',
    'role': 'assistant',
    'model': model,
    'content': content,
    'stop_reason': stopReason,
    'stop_sequence': null,
    'usage': usage,
  };
}
