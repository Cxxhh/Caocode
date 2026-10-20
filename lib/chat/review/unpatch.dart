/// [after] with the edit [diff] (a unified diff of it) taken back out:
/// the text before the edit; null when the diff does not fit it (changed
/// again since).
String? unpatch(String after, String diff) {
  final header = RegExp(r'^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@');
  final hunks = <({int start, List<String> before, List<String> after})>[];
  List<String>? oldSide;
  List<String>? newSide;
  // Whether the text before, and after, ends without a newline.
  var oldOpen = false;
  var newOpen = false;
  String? last;
  final diffLines = diff.split('\n');
  // The newline that ends the diff starts no line.
  if (diff.endsWith('\n')) diffLines.removeLast();
  for (var line in diffLines) {
    if (header.firstMatch(line) case final match?) {
      oldSide = [];
      newSide = [];
      // Where its lines are after the edit, from 0: one with none is
      // after the line it names.
      final start = int.parse(match[1]!);
      hunks.add((
        start: match[2] == '0' ? start : start - 1,
        before: oldSide,
        after: newSide,
      ));
      last = null;
      continue;
    }
    if (oldSide == null || newSide == null) continue;
    // An empty line of context, its space left out.
    if (line.isEmpty) line = ' ';
    final text = line.substring(1);
    switch (line[0]) {
      case ' ':
        oldSide.add(text);
        newSide.add(text);
      case '-':
        oldSide.add(text);
      case '+':
        newSide.add(text);
      case r'\':
        // `\ No newline at end of file`, of the line above.
        if (last != '+') oldOpen = true;
        if (last != '-') newOpen = true;
    }
    last = line[0];
  }
  if (hunks.isEmpty) return null;

  final lines = after.isEmpty ? <String>[] : after.split('\n');
  final closed = after.endsWith('\n');
  if (closed) lines.removeLast();
  // From the last, so that the lines of those before stay where they are.
  for (final hunk in hunks.reversed) {
    final at = _find(lines, hunk.after, hunk.start);
    if (at == null) return null;
    lines.replaceRange(at, at + hunk.after.length, hunk.before);
  }
  if (lines.isEmpty) return '';
  // As the text after, unless the edit touched its end.
  final ends = !oldOpen && (newOpen || closed);
  return '${lines.join('\n')}${ends ? '\n' : ''}';
}

/// Where [block] is in [lines], the nearest to [expected]; null where it
/// is not.
int? _find(List<String> lines, List<String> block, int expected) {
  bool at(int start) {
    if (start < 0 || start + block.length > lines.length) return false;
    for (var i = 0; i < block.length; i++) {
      if (lines[start + i] != block[i]) return false;
    }
    return true;
  }

  for (var distance = 0; distance <= lines.length; distance++) {
    if (at(expected - distance)) return expected - distance;
    if (distance > 0 && at(expected + distance)) return expected + distance;
  }
  return null;
}
