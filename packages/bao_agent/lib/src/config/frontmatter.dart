import 'package:yaml/yaml.dart';

/// A markdown file's `---` header, as a map, and the text after it.
class Frontmatter {
  const Frontmatter(this.fields, this.body);

  /// Reads [text]: its header when it starts with one. The header is YAML;
  /// one that is not quite (a description with a colon in it, unquoted) is
  /// read a line at a time, `key: value`.
  factory Frontmatter.parse(String text) {
    final normalized = text.replaceAll('\r\n', '\n');
    if (!normalized.startsWith('---\n') && normalized.trim() != '---') {
      return Frontmatter(const {}, normalized);
    }
    final end = RegExp(r'^---\s*$', multiLine: true);
    final matches = end.allMatches(normalized).toList();
    if (matches.length < 2) return Frontmatter(const {}, normalized);
    final header = normalized.substring(4, matches[1].start);
    final body = normalized
        .substring(matches[1].end)
        .replaceFirst(RegExp(r'^\n'), '');
    return Frontmatter(_fields(header), body);
  }

  final Map<String, Object?> fields;
  final String body;

  static Map<String, Object?> _fields(String header) {
    try {
      final yaml = loadYaml(header);
      if (yaml is YamlMap) return _plain(yaml) as Map<String, Object?>;
      if (yaml == null) return const {};
    } on Object {
      // Read by lines below.
    }
    final fields = <String, Object?>{};
    String? last;
    for (final line in header.split('\n')) {
      final match = RegExp(r'^([A-Za-z0-9_-]+):\s*(.*)$').firstMatch(line);
      if (match != null) {
        last = match[1]!;
        fields[last] = _unquote(match[2]!.trim());
      } else if (last != null && line.trim().isNotEmpty) {
        fields[last] = '${fields[last]}\n${line.trim()}'.trim();
      }
    }
    return fields;
  }

  static String _unquote(String value) {
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  static Object? _plain(Object? yaml) => switch (yaml) {
    final YamlMap map => <String, Object?>{
      for (final MapEntry(:key, :value) in map.entries) '$key': _plain(value),
    },
    final YamlList list => [for (final item in list) _plain(item)],
    _ => yaml,
  };

  String? string(String key) => switch (fields[key]) {
    final String value when value.trim().isNotEmpty => value.trim(),
    final num value => '$value',
    _ => null,
  };

  /// A field that is a list, or a comma-separated string (`tools: Read,
  /// Grep`).
  List<String>? list(String key) => switch (fields[key]) {
    final List<Object?> items => [
      for (final item in items)
        if (item != null && '$item'.trim().isNotEmpty) '$item'.trim(),
    ],
    final String value when value.trim().isNotEmpty => [
      for (final item in value.split(RegExp(r'[,\n]')))
        if (item.trim().isNotEmpty) item.trim(),
    ],
    _ => null,
  };

  bool? flag(String key) => switch (fields[key]) {
    final bool value => value,
    'true' => true,
    'false' => false,
    _ => null,
  };
}
