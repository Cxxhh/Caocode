// What the browser's profiles say, read as DevTools' panels read them: a
// CPU profile's busiest functions (Performance's Bottom-up), what of the
// style sheets was used (Coverage). Plain data in, plain data out: for an
// isolate, and tests.

/// A function in a profile, where it is: its script's URL, line and column
/// from 0.
typedef ProfileFunction = ({String name, String url, int line, int column});

/// A CPU profile's (a trace's `ProfileChunk`s) functions, by the time spent in
/// them: their own (self), and with what they called (total); and the
/// time spent on nothing, collecting garbage, or on the program itself.
class CpuSummary {
  CpuSummary(this.functions, this.idle, this.garbage, this.program, this.all);

  final List<({ProfileFunction function, double self, double total})> functions;

  /// Milliseconds.
  final double idle;
  final double garbage;
  final double program;
  final double all;

  static CpuSummary of(Map profile) {
    final nodes = (profile['nodes'] as List? ?? const []).cast<Map>();
    final samples = (profile['samples'] as List? ?? const []).cast<int>();
    final deltas = (profile['timeDeltas'] as List? ?? const []).cast<num>();
    final byId = <int, Map>{for (final n in nodes) n['id'] as int: n};
    // Its tree: by children (Profiler's), or by parent (a trace's).
    final parent = <int, int>{};
    for (final n in nodes) {
      for (final child in (n['children'] as List? ?? const []).cast<int>()) {
        parent[child] = n['id'] as int;
      }
      if (n['parent'] case final int of) parent[n['id'] as int] = of;
    }
    ProfileFunction function(Map node) {
      final frame = node['callFrame'] as Map;
      final name = frame['functionName'] as String? ?? '';
      return (
        name: name.isEmpty ? '(anonymous)' : name,
        url: frame['url'] as String? ?? '',
        line: (frame['lineNumber'] as num?)?.toInt() ?? 0,
        column: (frame['columnNumber'] as num?)?.toInt() ?? 0,
      );
    }

    final self = <ProfileFunction, double>{};
    final total = <ProfileFunction, double>{};
    var idle = 0.0;
    var garbage = 0.0;
    var program = 0.0;
    var all = 0.0;
    for (var i = 0; i < samples.length; i++) {
      // A sample's time: until the next.
      final ms = (i + 1 < deltas.length ? deltas[i + 1] : 0).toDouble() / 1000;
      if (ms <= 0) continue;
      all += ms;
      final node = byId[samples[i]];
      if (node == null) continue;
      final name = (node['callFrame'] as Map)['functionName'];
      if (name == '(idle)') {
        idle += ms;
        continue;
      }
      if (name == '(garbage collector)') {
        garbage += ms;
        continue;
      }
      if (name == '(program)') {
        program += ms;
        continue;
      }
      final own = function(node);
      self[own] = (self[own] ?? 0) + ms;
      // Each function on the stack once (a recursive one too).
      final seen = <ProfileFunction>{};
      for (int? id = samples[i]; id != null; id = parent[id]) {
        final n = byId[id];
        if (n == null) break;
        final f = function(n);
        if (f.name == '(root)') break;
        if (seen.add(f)) total[f] = (total[f] ?? 0) + ms;
      }
    }
    final functions = [
      for (final f in total.keys)
        (function: f, self: self[f] ?? 0, total: total[f]!),
    ]..sort((a, b) => b.self.compareTo(a.self));
    return CpuSummary(functions, idle, garbage, program, all);
  }
}

/// What of a file was used: its size, and its parts that were not
/// ([unused], `[start, end)` offsets), the rules there ([unusedRules]:
/// their selectors).
class FileCoverage {
  FileCoverage(
    this.url,
    this.kind,
    this.size,
    this.unused, [
    this.unusedRules = const [],
  ]);

  final String url;

  /// `CSS`.
  final String kind;
  final int size;
  final List<(int, int)> unused;
  final List<String> unusedRules;

  int get unusedSize => unused.fold(0, (sum, r) => sum + r.$2 - r.$1);
}

/// A style sheet's coverage: of its [text], what its used rules
/// (`CSS.stopRuleUsageTracking`'s) leave, but blanks.
FileCoverage styleCoverage(String url, String text, List<Map> rules) {
  final size = text.length;
  final used = List<bool>.filled(size, false);
  for (final r in rules) {
    if (r['used'] != true) continue;
    final start = (r['startOffset'] as num).toInt().clamp(0, size);
    final end = (r['endOffset'] as num).toInt().clamp(0, size);
    for (var i = start; i < end; i++) {
      used[i] = true;
    }
  }
  final blank = RegExp(r'\s');
  final unused = <(int, int)>[];
  final selectors = <String>[];
  for (var (start, end) in _gaps(used)) {
    while (start < end && blank.hasMatch(text[start])) {
      start++;
    }
    while (end > start && blank.hasMatch(text[end - 1])) {
      end--;
    }
    final part = text
        .substring(start, end)
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    // Nothing but what closes a block: no rule.
    if (part.replaceAll(RegExp(r'[\s}]'), '').isEmpty) continue;
    unused.add((start, end));
    for (final m in RegExp(r'([^{};]+)\{').allMatches(part)) {
      final selector = m[1]!.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (selector.isNotEmpty &&
          !selector.startsWith('@') &&
          !selectors.contains(selector)) {
        selectors.add(selector);
      }
    }
  }
  return FileCoverage(url, 'CSS', size, unused, selectors);
}

List<(int, int)> _gaps(List<bool> used) {
  final gaps = <(int, int)>[];
  int? start;
  for (var i = 0; i <= used.length; i++) {
    final isUsed = i == used.length || used[i];
    if (!isUsed) {
      start ??= i;
    } else if (start != null) {
      gaps.add((start, i));
      start = null;
    }
  }
  return gaps;
}
