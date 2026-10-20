import 'dart:async';
import 'dart:convert';

/// One server-sent event: its name and its data, decoded from JSON when it
/// is JSON.
class SseEvent {
  const SseEvent(this.event, this.data);

  final String? event;
  final String data;

  /// [data] decoded, when it is a JSON object.
  Map<String, Object?>? get json {
    try {
      final decoded = jsonDecode(data);
      return decoded is Map ? decoded.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }
}

/// Splits a stream of text into server-sent events: `event:` and `data:`
/// lines up to a blank line; comments (`:`) and other fields are skipped.
class SseDecoder extends StreamTransformerBase<String, SseEvent> {
  const SseDecoder();

  @override
  Stream<SseEvent> bind(Stream<String> stream) async* {
    String? event;
    final data = <String>[];
    await for (final line in stream.transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
        event = null;
        data.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'event':
          event = value;
        case 'data':
          data.add(value);
      }
    }
    if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
  }
}
