/// [text]'s lines, a last line break ending the last rather than starting
/// another.
List<String> diffLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.last.isEmpty) lines.removeLast();
  return [
    for (final line in lines)
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
  ];
}
