typedef WslProject = ({String distribution, String path, String prefix});

WslProject? wslProject(String? path) {
  if (path == null) return null;
  final normalized = path.replaceAll('\\', '/');
  final match = RegExp(
    r'^//(wsl\.localhost|wsl\$)/([^/]+)(/.*)?$',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (match == null) return null;
  return (
    distribution: match.group(2)!,
    path: match.group(3) ?? '/',
    prefix: '//${match.group(1)}/${match.group(2)}',
  );
}
