/// A hunk of a line diff, as `structuredPatch` has it: where it starts in
/// each text (1-based), how many lines of each it spans, and its lines,
/// each marked ` ` (kept), `-` (removed) or `+` (added).
class Hunk {
  const Hunk({
    required this.oldStart,
    required this.oldLines,
    required this.newStart,
    required this.newLines,
    required this.lines,
  });

  final int oldStart;
  final int oldLines;
  final int newStart;
  final int newLines;
  final List<String> lines;

  Map<String, Object?> toJson() => {
    'oldStart': oldStart,
    'oldLines': oldLines,
    'newStart': newStart,
    'newLines': newLines,
    'lines': lines,
  };

  int get added => lines.where((l) => l.startsWith('+')).length;
  int get removed => lines.where((l) => l.startsWith('-')).length;
}

enum _Op { keep, remove, add }

/// The hunks that make [before] into [after], with [context] lines kept
/// around each change.
List<Hunk> diffLines(String before, String after, {int context = 3}) {
  if (before == after) return const [];
  final a = _split(before);
  final b = _split(after);
  // What both share at the start and end needs no diffing.
  var prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  final middle = _ops(
    a.sublist(prefix, a.length - suffix),
    b.sublist(prefix, b.length - suffix),
  );
  final ops = <(_Op, String)>[
    for (var i = 0; i < prefix; i++) (_Op.keep, a[i]),
    ...middle,
    for (var i = a.length - suffix; i < a.length; i++) (_Op.keep, a[i]),
  ];
  return _hunks(ops, context);
}

List<String> _split(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  // A final newline ends the last line rather than starting another.
  if (lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// The edit script from [a] to [b]: Myers' algorithm, falling back to all
/// of [a] removed and all of [b] added when the two differ too much to be
/// worth the time.
List<(_Op, String)> _ops(List<String> a, List<String> b) {
  if (a.isEmpty) return [for (final line in b) (_Op.add, line)];
  if (b.isEmpty) return [for (final line in a) (_Op.remove, line)];
  final n = a.length;
  final m = b.length;
  final max = n + m;
  // Each step keeps the furthest reach of its diagonals (2d + 1 of them):
  // memory grows as the square of the differences, so very different texts
  // are not diffed line by line.
  const limit = 3000;
  final trace = <List<int>>[];
  // Diagonal k (-max - 1 … max + 1) at index k + off.
  final off = max + 2;
  final v = List<int>.filled(2 * off + 1, 0);
  var found = false;
  for (var d = 0; d <= max && d <= limit; d++) {
    trace.add(v.sublist(off - d - 1, off + d + 2));
    for (var k = -d; k <= d; k += 2) {
      int x;
      if (k == -d || (k != d && v[k - 1 + off] < v[k + 1 + off])) {
        x = v[k + 1 + off];
      } else {
        x = v[k - 1 + off] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[k + off] = x;
      if (x >= n && y >= m) {
        found = true;
        break;
      }
    }
    if (found) break;
  }
  if (!found) {
    return [
      for (final line in a) (_Op.remove, line),
      for (final line in b) (_Op.add, line),
    ];
  }
  // Walk back through the trace.
  final ops = <(_Op, String)>[];
  var x = n;
  var y = m;
  for (var d = trace.length - 1; d > 0; d--) {
    // The reach before step d: diagonal k at index k + d + 1 (see above).
    final prev = trace[d];
    int at(int k) => prev[k + d + 1];
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && at(k - 1) < at(k + 1))) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = at(prevK);
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      ops.add((_Op.keep, a[x - 1]));
      x--;
      y--;
    }
    if (x == prevX) {
      ops.add((_Op.add, b[y - 1]));
      y--;
    } else {
      ops.add((_Op.remove, a[x - 1]));
      x--;
    }
  }
  while (x > 0 && y > 0) {
    ops.add((_Op.keep, a[x - 1]));
    x--;
    y--;
  }
  while (x > 0) {
    ops.add((_Op.remove, a[x - 1]));
    x--;
  }
  while (y > 0) {
    ops.add((_Op.add, b[y - 1]));
    y--;
  }
  return ops.reversed.toList();
}

List<Hunk> _hunks(List<(_Op, String)> ops, int context) {
  final hunks = <Hunk>[];
  var i = 0;
  var oldLine = 1;
  var newLine = 1;
  // Line numbers before each op.
  final oldAt = <int>[];
  final newAt = <int>[];
  for (final (op, _) in ops) {
    oldAt.add(oldLine);
    newAt.add(newLine);
    if (op != _Op.add) oldLine++;
    if (op != _Op.remove) newLine++;
  }
  while (i < ops.length) {
    if (ops[i].$1 == _Op.keep) {
      i++;
      continue;
    }
    // A change: from [context] lines before it to [context] lines after the
    // last change within reach.
    final start = (i - context).clamp(0, ops.length);
    var end = i;
    var lastChange = i;
    while (end < ops.length) {
      if (ops[end].$1 != _Op.keep) {
        lastChange = end;
      } else if (end - lastChange > context * 2) {
        break;
      }
      end++;
    }
    final stop = (lastChange + context + 1).clamp(0, ops.length);
    final slice = ops.sublist(start, stop);
    final oldCount = slice.where((op) => op.$1 != _Op.add).length;
    final newCount = slice.where((op) => op.$1 != _Op.remove).length;
    hunks.add(
      Hunk(
        oldStart: oldCount == 0 ? oldAt[start] - 1 : oldAt[start],
        oldLines: oldCount,
        newStart: newCount == 0 ? newAt[start] - 1 : newAt[start],
        newLines: newCount,
        lines: [
          for (final (op, line) in slice)
            switch (op) {
              _Op.keep => ' $line',
              _Op.remove => '-$line',
              _Op.add => '+$line',
            },
        ],
      ),
    );
    i = stop;
  }
  return hunks;
}

/// [hunks] as JSON.
List<Map<String, Object?>> patchJson(List<Hunk> hunks) => [
  for (final hunk in hunks) hunk.toJson(),
];
