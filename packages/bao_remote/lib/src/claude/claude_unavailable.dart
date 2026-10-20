/// Claude Code cannot start: not installed, its folder gone, or the
/// process failed to.
class ClaudeUnavailable implements Exception {
  const ClaudeUnavailable(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => message;
}

/// Claude Code is not on the machine: neither the user's nor one Caocode
/// installed.
class ClaudeNotInstalled extends ClaudeUnavailable {
  const ClaudeNotInstalled(super.message, {super.detail});
}

/// Claude Code could not be downloaded or installed.
class ClaudeDownloadFailed extends ClaudeUnavailable {
  const ClaudeDownloadFailed(super.message, {super.detail});
}

/// Caocode's own core has no model to run on: no upstream turned on.
class ClaudeNoModel extends ClaudeUnavailable {
  const ClaudeNoModel(super.message);
}

/// The project folder Claude Code was to work in is not there (moved,
/// deleted, an unplugged drive).
class ClaudeFolderGone extends ClaudeUnavailable {
  const ClaudeFolderGone(this.folder)
    : super('The project folder is gone: $folder');

  final String folder;
}
