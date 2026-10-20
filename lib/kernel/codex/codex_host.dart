typedef WslProject = ({String distribution, String path, String prefix});

/// `path`'s UNC spelling before Windows path normalization. package:path
/// treats a leading `//` as a single rooted slash and loses the UNC host;
/// native backslashes preserve both the server and distribution.
String wslWindowsPath(String path) {
  final project = wslProject(path);
  return project == null
      ? path
      : '${project.prefix}${project.path}'.replaceAll('/', '\\');
}

WslProject? wslProject(String? path) {
  if (path == null) return null;
  var normalized = path.replaceAll('\\', '/');
  // Native Windows pickers and resolveSymbolicLinks may return an
  // extended UNC path. It still belongs to the same WSL distribution.
  if (normalized.toLowerCase().startsWith('//?/unc/')) {
    normalized = '//${normalized.substring(8)}';
  }
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
