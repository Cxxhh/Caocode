import 'dart:convert';
import 'dart:typed_data';

/// Lines added and removed from [before] to [after] (null: no file), as
/// a diff counts them; null when either is binary (a NUL in its first
/// 8000 bytes, as Git tells). Past a size, all of one replaced by the
/// other.
({int added, int removed})? countLines(Uint8List? before, Uint8List? after) {
  if (_isBinary(before) || _isBinary(after)) return null;
  // Lines as numbers, the same for the same text.
  final ids = <String, int>{};
  List<int> lines(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return const [];
    final text = utf8.decode(bytes, allowMalformed: true);
    final split = text.split('\n');
    // The newline at the end ends the last line; it starts none.
    if (text.endsWith('\n')) split.removeLast();
    return [for (final line in split) ids.putIfAbsent(line, () => ids.length)];
  }

  var a = lines(before);
  var b = lines(after);
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var end = 0;
  while (end < a.length - start &&
      end < b.length - start &&
      a[a.length - 1 - end] == b[b.length - 1 - end]) {
    end++;
  }
  a = a.sublist(start, a.length - end);
  b = b.sublist(start, b.length - end);
  final distance = _distance(a, b);
  if (distance == null) return (added: b.length, removed: a.length);
  return (
    added: (distance + b.length - a.length) ~/ 2,
    removed: (distance - b.length + a.length) ~/ 2,
  );
}

bool _isBinary(Uint8List? bytes) {
  if (bytes == null) return false;
  final end = bytes.length < 8000 ? bytes.length : 8000;
  for (var i = 0; i < end; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

/// How much work [_distance] may do: past it, a file is counted as
/// replaced.
const _budget = 50000000;

/// The lines to add and remove to make [a] into [b] (Myers); null when
/// that takes more than [_budget].
int? _distance(List<int> a, List<int> b) {
  final n = a.length;
  final m = b.length;
  if (n == 0 || m == 0) return n + m;
  final max = n + m;
  final limit = _budget ~/ max;
  final v = Int32List(2 * max + 2);
  final offset = max + 1;
  for (var d = 0; d <= max && d <= limit; d++) {
    for (var k = -d; k <= d; k += 2) {
      var x = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
          ? v[offset + k + 1]
          : v[offset + k - 1] + 1;
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) return d;
    }
  }
  return null;
}
