/// [value] as a map, or an empty one when it is not.
Map<String, Object?> asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

/// [value] as a list, or an empty one when it is not.
List<Object?> asList(Object? value) =>
    value is List ? value.cast<Object?>() : const [];

/// [value] when it is a string.
String? asString(Object? value) => value is String ? value : null;

/// [value] when it is a non-empty string, trimmed.
String? asText(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// [value] as an int, from a number or a numeric string.
int? asInt(Object? value) => switch (value) {
  final int n => n,
  final num n => n.toInt(),
  final String s => int.tryParse(s.trim()),
  _ => null,
};

/// [value] as a bool, from a bool or `"true"`/`"false"`.
bool? asBool(Object? value) => switch (value) {
  final bool b => b,
  'true' => true,
  'false' => false,
  _ => null,
};

/// A deep copy of [value], made of plain maps and lists, so that it can be
/// changed without changing what it was copied from.
Object? deepCopy(Object? value) => switch (value) {
  final Map<Object?, Object?> map => <String, Object?>{
    for (final MapEntry(:key, :value) in map.entries) '$key': deepCopy(value),
  },
  final List<Object?> list => [for (final item in list) deepCopy(item)],
  _ => value,
};

/// [base] with [over] laid over it: maps merged key by key, lists joined
/// without repeats (permission rules from every settings file count), other
/// values replaced.
Map<String, Object?> mergeSettings(
  Map<String, Object?> base,
  Map<String, Object?> over,
) {
  final merged = <String, Object?>{...base};
  for (final MapEntry(:key, :value) in over.entries) {
    final before = merged[key];
    if (before is Map && value is Map) {
      merged[key] = mergeSettings(
        before.cast<String, Object?>(),
        value.cast<String, Object?>(),
      );
    } else if (before is List && value is List) {
      merged[key] = [
        ...before,
        for (final item in value)
          if (!before.contains(item)) item,
      ];
    } else {
      merged[key] = value;
    }
  }
  return merged;
}
