import 'dart:typed_data';

/// Undo and Redo where the focus is in the explorer (VS Code's own `undo`
/// and `redo` there): of their own, so that an editor's never runs these.
const explorerUndoCommandId = 'caocode.explorer.undo';
const explorerRedoCommandId = 'caocode.explorer.redo';

/// A file operation of the explorer's, as VS Code's undo/redo service keeps
/// them: undone with Undo, done again with Redo.
sealed class ExplorerOperation {
  const ExplorerOperation();
}

/// Renamed or moved (a rename, a cut and paste, a drag): each from where to.
final class ExplorerMoved extends ExplorerOperation {
  const ExplorerMoved(this.moves);

  final List<({String from, String to})> moves;
}

/// Made: a file or folder, after the folders made for it (`a/b/c.txt`).
final class ExplorerCreated extends ExplorerOperation {
  const ExplorerCreated(this.paths);

  final List<({String path, bool directory})> paths;
}

/// Copied (a paste): each copy of its source, [upload]ed from this machine
/// into a remote project.
final class ExplorerCopied extends ExplorerOperation {
  const ExplorerCopied(this.copies, {this.upload = false});

  final List<({String source, String copy})> copies;
  final bool upload;
}

/// A file deleted for good, its bytes kept to make it again (the Trash
/// gives its own back: not undone here).
final class ExplorerDeleted extends ExplorerOperation {
  const ExplorerDeleted(this.path, this.bytes);

  final String path;
  final Uint8List bytes;
}

/// The explorer's operations to undo and to redo, the last on top. Kept
/// with its controller, so that switching views keeps them.
class ExplorerHistory {
  static const _kept = 50;

  final List<ExplorerOperation> _undo = [];
  final List<ExplorerOperation> _redo = [];

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// [operation] was done: what was undone is no longer to redo.
  void done(ExplorerOperation operation) {
    _undo.add(operation);
    if (_undo.length > _kept) _undo.removeAt(0);
    _redo.clear();
  }

  /// The operation to undo, taken off; [undone] once it is.
  ExplorerOperation? takeUndo() => _undo.isEmpty ? null : _undo.removeLast();
  void undone(ExplorerOperation operation) => _redo.add(operation);

  /// The operation to redo, taken off; [redone] once it is.
  ExplorerOperation? takeRedo() => _redo.isEmpty ? null : _redo.removeLast();
  void redone(ExplorerOperation operation) => _undo.add(operation);
}
