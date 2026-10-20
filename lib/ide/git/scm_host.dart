import '../file_service.dart';
import 'git_repository.dart';

/// What the Source Control view works on: the IDE's workspace, or the
/// project of the chat window's side panel. One view for both, so that they
/// look and behave the same.
abstract interface class IdeScmHost {
  /// The project's folder: the graph's root until its repository is read.
  String get root;

  /// The project's files, on its host.
  IdeFileService get files;

  /// The repositories CHANGES lists under their headers, by folder, when
  /// there are more than one (#76).
  List<(String root, IdeGitRepository git)> get repositories;

  /// The repository shown: the one CHANGES lists alone, the graph's.
  IdeGitRepository? get git;

  /// Makes [git] the one shown, as a click on its rows does.
  void selectRepository(IdeGitRepository git);

  /// The repositories folded under their headers in CHANGES, by root.
  Set<String> get scmCollapsedRepositories;

  /// Reads the files at [paths] again where they are open, after Git
  /// changed them (a discard).
  Future<void> reload(Iterable<String> paths);

  /// Appends [lines] to the text file at [path], made when missing, and
  /// saves it (Add to .gitignore).
  Future<void> appendLines(String path, String lines);
}

/// [text] with [lines] after it on lines of their own, ending with a line
/// break.
String ideAppendLines(String text, String lines) {
  final lastLine = text.substring(text.lastIndexOf('\n') + 1);
  return lastLine.trim().isEmpty ? '$text$lines\n' : '$text\n$lines\n';
}

/// [ideAppendLines] on the file at [path] in [files], made when missing.
Future<void> ideAppendLinesToFile(
  IdeFileService files,
  String path,
  String lines,
) async {
  String text;
  try {
    text = await files.read(path);
  } on IdeFileNotFoundException {
    await files.create(path);
    text = '';
  }
  await files.write(path, ideAppendLines(text, lines), expectedText: text);
}
