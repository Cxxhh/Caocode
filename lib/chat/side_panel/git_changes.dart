import '../../ide/file_service.dart';
import '../../ide/git/git_change_editor.dart';
import '../../ide/git/git_model.dart';
import '../../ide/git/git_repository.dart';
import 'file_open.dart';

/// [resource]'s changes, as the IDE's Source Control opens them (see
/// [IdeGitChangeEditor]): its text at HEAD or in the index against the
/// index's or the file's; an added file's against nothing, a deleted
/// one's text against nothing.
FileOpenRequest gitChangeRequest(
  IdeGitRepository git,
  IdeGitState state,
  IdeGitResource resource,
) {
  final editor = IdeGitChangeEditor.of(
    resource,
    staged: state.group(IdeGitGroup.staged),
  );
  Future<String> Function() show(IdeGitSide side) =>
      () => git.service.show(side.ref!, side.path);
  final (left, right) = (editor.left, editor.right);
  // Deleted: HEAD's text, and no file.
  if (left == null && right != null && right.ref == 'HEAD') {
    return FileOpenRequest(
      resource.path,
      diff: true,
      original: show(right),
      modified: () async => throw IdeFileNotFoundException(resource.path),
    );
  }
  return FileOpenRequest(
    resource.path,
    diff: true,
    // Not there (before the first commit): none before it.
    original: left == null
        ? () async => ''
        : () => show(left)().catchError((Object _) => ''),
    modified: right == null || right.isFile ? null : show(right),
  );
}
