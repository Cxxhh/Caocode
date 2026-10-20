/*---------------------------------------------------------------------------------------------
 *  Copyright (c) Microsoft Corporation. All rights reserved.
 *  Licensed under the MIT License. See License.txt in the project root for license information.
 *--------------------------------------------------------------------------------------------*/

// The Git commands the workbench runs, as VS Code's Git extension runs
// them (extensions/git/src/git.ts at 6a598d4a13031703d483d103c1d934a36ad27971):
// status with the branch and ignored paths, add, restore (or the older
// reset, see `unstage`), checkout, clean, commit, log for the graph and the
// timeline, show for the texts a diff editor compares (`buffer`), blame for
// the editor's blame (`blame2`), fetch (one remote or all), pull and push
// for the actions, and for-each-ref, checkout and checkout -b for Checkout
// to… (`getRefs`, `findTrackingBranches`, `checkout`, `branch`).
//
// Deviations: no stash, and no credential prompts
// (`GIT_TERMINAL_PROMPT=0`: a remote that asks for a password fails).

import 'package:bao_remote/git.dart';
import 'package:path/path.dart' as p;

import 'git_model.dart';
import 'git_service_stub.dart'
    if (dart.library.io) 'git_service_io.dart'
    as platform;

export 'package:bao_remote/git.dart';

/// Runs `git` with [arguments] in [workingDirectory]; with [limit], reads
/// only that many NUL-terminated records of its output (`runGit`'s).
typedef IdeGitRunner = Future<IdeGitOutput> Function(
  List<String> arguments, {
  required String workingDirectory,
  int? limit,
});

/// Changes under the repository at [repositoryRoot].
typedef IdeGitWatcher = Stream<void> Function(String repositoryRoot);

/// `git --version`'s output (`git version 2.23.0.windows.1`, `git version
/// 2.39.2 (Apple Git-143)`) as (major, minor); null when it cannot be read
/// (an unexpected spelling).
(int, int)? parseGitVersion(String output) {
  final match = RegExp(r'(\d+)\.(\d+)').firstMatch(output);
  return match == null
      ? null
      : (int.parse(match[1]!), int.parse(match[2]!));
}

/// A file a commit changed.
class IdeGitCommitChange {
  const IdeGitCommitChange(this.path, this.status, {this.originalPath});

  final String path;
  final String? originalPath;

  /// `A`, `M`, `D`, `R`, `C` or `T`.
  final String status;
}

/// Git for the repository containing [root]; [runner] and [watcher]
/// replace running `git` and watching the files (for tests, and a remote
/// host's), [pathContext] how the host Git runs on spells paths (a Linux
/// or macOS host's from Windows).
class IdeGitService {
  IdeGitService(
    String root, {
    IdeGitRunner? runner,
    IdeGitWatcher? watcher,
    p.Context? pathContext,
  }) : pathContext = pathContext ?? p.context,
       root = (pathContext ?? p.context).normalize(root),
       _run = runner ?? platform.runGit,
       _watch = watcher ?? platform.watchRepository;

  final p.Context pathContext;
  final String root;
  final IdeGitRunner _run;
  final IdeGitWatcher _watch;
  String? _repositoryRoot;

  /// Changes under the repository, for refreshing; empty where files cannot
  /// be watched.
  Stream<void> watch(String repositoryRoot) => _watch(repositoryRoot);

  Future<IdeGitOutput> _git(
    List<String> arguments, {
    String? cwd,
    int? limit,
  }) => _run(
    arguments,
    workingDirectory: cwd ?? _repositoryRoot ?? root,
    limit: limit,
  );

  static IdeGitOutput _check(IdeGitOutput output, String what) {
    if (output.exitCode == 0) return output;
    final error = output.stderr.trim();
    final detail = error.length > 500 ? '${error.substring(0, 500)}…' : error;
    throw IdeGitException(detail.isEmpty ? what : '$what\n$detail');
  }

  /// The repository's top level, or null when [root] is not in one.
  Future<String?> repositoryRoot() async {
    if (_repositoryRoot case final known?) return known;
    final output = await _git(['rev-parse', '--show-toplevel'], cwd: root);
    if (output.exitCode != 0) return null;
    final top = output.stdout.trim();
    if (top.isEmpty) return null;
    return _repositoryRoot = pathContext.normalize(top);
  }

  /// The folders of the submodules of the repository [root] is in, as its
  /// `.gitmodules` names them (upstream's `git.detectSubmodules` reads the
  /// same); none where it has none, or Git cannot say.
  Future<List<String>> submodulePaths() async {
    try {
      // The top level from [root] as [root] is spelled (`--show-toplevel`
      // resolves links, which [root] may go through).
      final cdup = await _git(['rev-parse', '--show-cdup'], cwd: root);
      if (cdup.exitCode != 0) return const [];
      final up = cdup.stdout.trim();
      final top = pathContext.normalize(pathContext.join(root, up));
      final output = await _git([
        'config',
        '-z',
        '--file',
        up.isEmpty ? '.gitmodules' : '$up.gitmodules',
        '--get-regexp',
        r'^submodule\..*\.path$',
      ], cwd: root);
      if (output.exitCode != 0) return const [];
      // `-z`: each `key` newline `value`, then a NUL.
      return [
        for (final entry in output.stdout.split('\x00'))
          if (entry.indexOf('\n') case final newline when newline >= 0)
            pathContext.joinAll([
              top,
              ...entry.substring(newline + 1).split('/'),
            ]),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Whether [root] is a working tree's top level, not a folder in one
  /// (nor a bare repository): what finds the repositories of a folder's
  /// subfolders. Asked by the path's prefix in the tree, which is empty
  /// at its top, where the top level would be spelled with links resolved.
  Future<bool> isRepositoryTop() async {
    try {
      final output = await _git([
        'rev-parse',
        '--is-inside-work-tree',
        '--show-prefix',
      ], cwd: root);
      if (output.exitCode != 0) return false;
      final lines = output.stdout.split('\n');
      return lines.first.trim() == 'true' &&
          (lines.length < 2 || lines[1].trim().isEmpty);
    } catch (_) {
      // Git missing, or the folder gone.
      return false;
    }
  }

  Future<String> _requireRoot() async {
    final top = await repositoryRoot();
    if (top == null) throw const IdeGitException('Not a Git repository.');
    return top;
  }

  List<String> _relative(String top, Iterable<String> paths) => [
    for (final path in paths)
      pathContext.relative(path, from: top).replaceAll(r'\', '/'),
  ];

  /// [paths] relative to [top], or the whole tree (`.`) for none: long
  /// lists of paths are not passed on the command line.
  List<String> _pathspec(String top, Iterable<String>? paths) =>
      paths == null ? const ['.'] : _relative(top, paths);

  /// `git init` in [root]: Initialize Repository.
  Future<void> init() async {
    _check(
      await _git(['init'], cwd: root),
      'Cannot initialize the repository.',
    );
  }

  /// How many changes the status reads at most (VS Code's
  /// `git.statusLimit`): a folder with a huge untracked tree (a home
  /// folder made a repository) has hundreds of thousands, too many to read,
  /// keep and show.
  static const statusLimit = 10000;

  /// The status, or null outside a repository: at most [statusLimit]
  /// records, [IdeGitState.didHitLimit] when there were more.
  Future<IdeGitState?> status() async {
    final top = await repositoryRoot();
    if (top == null) return null;
    final output = _check(
      await _git(
        [
          'status',
          '-z',
          '--porcelain=v1',
          '--branch',
          '--untracked-files=all',
          '--ignored=matching',
        ],
        // And the branch's.
        limit: statusLimit + 1,
      ),
      'Cannot read the Git status.',
    );
    return parseGitStatus(
      top,
      output.stdout,
      truncated: output.truncated,
      pathContext: pathContext,
    );
  }

  /// `git add -A --`: stages the changes of [paths] (all when null),
  /// deletions included.
  Future<void> stage(Iterable<String>? paths) async {
    final top = await _requireRoot();
    _check(
      await _git(['add', '-A', '--', ..._pathspec(top, paths)]),
      'Cannot stage the changes.',
    );
  }

  /// Unstages [paths] (all when null): `git restore --staged` where Git has
  /// it (2.23+), else `git reset -q HEAD --` (2.0+); before the first
  /// commit, `git rm --cached -r -q --` either way (there is no HEAD to
  /// reset against).
  ///
  /// Older Gits (before 2.23, e.g. the 2.17 shipped on some systems) have no
  /// `restore`; asking for it fails outright, so the version is read once
  /// and `reset` used instead.
  Future<void> unstage(Iterable<String>? paths, {bool unborn = false}) async {
    final top = await _requireRoot();
    final relative = _pathspec(top, paths);
    final command = unborn
        ? ['rm', '--cached', '-r', '-q', '--', ...relative]
        : await _supportsRestore()
        ? ['restore', '--staged', '--', ...relative]
        : ['reset', '-q', 'HEAD', '--', ...relative];
    _check(await _git(command), 'Cannot unstage the changes.');
  }

  /// Whether this Git has `git restore` (added in 2.23), read once from
  /// `git --version`. A Git whose version cannot be read is taken to have
  /// it: the newer commands are the ones a modern Git expects.
  Future<bool> _supportsRestore() async =>
      _restoreSupport ??= switch (await _gitVersion()) {
        final version? => _atLeast(version, 2, 23),
        null => true,
      };

  /// The Git version, or null when Git is missing or its version cannot be
  /// read. Kept: it does not change while the service runs.
  Future<(int, int)?>? _gitVersionCache;
  Future<(int, int)?> _gitVersion() => _gitVersionCache ??= () async {
    final output = await _git(['--version']);
    if (output.exitCode != 0) return null;
    return parseGitVersion(output.stdout);
  }();

  bool? _restoreSupport;

  /// Whether [version] (major, minor) is [major].[minor] or newer.
  static bool _atLeast((int, int) version, int major, int minor) =>
      version.$1 != major ? version.$1 > major : version.$2 >= minor;

  /// Discards working-tree changes: tracked files are checked out from the
  /// index, untracked ones deleted (`git clean -f -q`).
  Future<void> discard(Iterable<IdeGitResource> resources) async {
    final top = await _requireRoot();
    final untracked = [
      for (final resource in resources)
        if (resource.status == IdeGitStatus.untracked) resource.path,
    ];
    final tracked = [
      for (final resource in resources)
        if (resource.status != IdeGitStatus.untracked) resource.path,
    ];
    if (tracked.isNotEmpty) {
      _check(
        await _git(['checkout', '-q', '--', ..._relative(top, tracked)]),
        'Cannot discard the changes.',
      );
    }
    if (untracked.isNotEmpty) {
      _check(
        await _git(['clean', '-f', '-q', '--', ..._relative(top, untracked)]),
        'Cannot delete the untracked files.',
      );
    }
  }

  /// Commits the index with [message]; [all] stages tracked changes first
  /// (`--all`), [amend] replaces the last commit, [empty] allows a commit
  /// without changes.
  Future<void> commit(
    String message, {
    bool all = false,
    bool amend = false,
    bool empty = false,
  }) async {
    await _requireRoot();
    _check(
      await _git([
        'commit',
        '--quiet',
        if (all) '--all',
        if (amend) '--amend',
        if (empty) '--allow-empty',
        if (message.isEmpty && amend) '--no-edit' else ...['-m', message],
      ]),
      'Cannot commit.',
    );
  }

  /// What a commit would take, as a unified diff: the staged changes
  /// ([staged]), else the tracked ones, and each of [untracked] as a new
  /// file (`git diff --no-index`, which exits 1 when there is a
  /// difference).
  Future<String> diff({
    required bool staged,
    Iterable<String> untracked = const [],
  }) async {
    final top = await _requireRoot();
    const options = ['--no-color', '--no-ext-diff'];
    final out = StringBuffer(
      _check(
        await _git(['diff', ...options, '-M', if (staged) '--cached']),
        'Cannot read the changes.',
      ).stdout,
    );
    for (final path in _relative(top, untracked)) {
      final added = await _git([
        'diff',
        ...options,
        '--no-index',
        '--',
        '/dev/null',
        path,
      ]);
      if (added.exitCode <= 1) out.write(added.stdout);
    }
    return out.toString();
  }

  /// Undoes [head], the last commit, keeping its changes staged: `git reset
  /// --soft HEAD~`, or for the first commit, deleting HEAD and unstaging.
  Future<void> undoCommit(IdeGitCommit head) async {
    await _requireRoot();
    if (head.parentIds.isNotEmpty) {
      _check(
        await _git(['reset', '--soft', 'HEAD~']),
        'Cannot undo the last commit.',
      );
    } else {
      _check(
        await _git(['update-ref', '-d', 'HEAD']),
        'Cannot undo the last commit.',
      );
      _check(
        await _git(['rm', '--cached', '-r', '-q', '--', '.']),
        'Cannot unstage the changes.',
      );
    }
  }

  /// [path]'s text at [ref] (`git show --textconv <ref>:<path>`): `HEAD`,
  /// `''` for the index, or `:1` to `:3` for a merge's stages.
  Future<String> show(String ref, String path) async {
    final top = await _requireRoot();
    final relative = _relative(top, [path]).single;
    return _check(
      await _git(['show', '--textconv', '$ref:$relative']),
      'Could not show object.',
    ).stdout;
  }

  /// `git blame --root --incremental` of [path] as it is on disk (`blame2`);
  /// null where Git cannot blame it: untracked, outside the repository, or
  /// before the first commit.
  Future<List<IdeGitBlameInformation>?> blame(String path) async {
    try {
      final top = await repositoryRoot();
      if (top == null) return null;
      final output = await _git([
        '-c',
        'i18n.logOutputEncoding=UTF-8',
        'blame',
        '--root',
        '--incremental',
        '--',
        ..._relative(top, [path]),
      ]);
      if (output.exitCode != 0) return null;
      return parseGitBlame(output.stdout.trim());
    } on IdeGitException {
      return null;
    }
  }

  /// The remotes' names (`git remote`).
  Future<List<String>> remotes() async {
    await _requireRoot();
    final output = _check(await _git(['remote']), 'Cannot read the remotes.');
    return [
      for (final line in output.stdout.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
  }

  /// `git fetch <remote> --tags` for one remote, or `git fetch --all
  /// --tags` for every remote (`git.fetch`/`git.fetchAll`).
  Future<void> fetch({String? remote}) async {
    await _requireRoot();
    _check(
      await _git(['fetch', ?remote, if (remote == null) '--all', '--tags']),
      remote == null ? 'Cannot fetch from all remotes.' : 'Cannot fetch.',
    );
  }

  /// `git pull --tags remote branch` (`pull` with `git.pullTags`, without
  /// rebasing: `git.rebaseWhenSync` is off by default).
  Future<void> pull(String remote, String branch) async {
    await _requireRoot();
    _check(await _git(['pull', '--tags', remote, branch]), 'Cannot pull.');
  }

  /// `git push [-u] remote name` (`push`; [setUpstream] to publish).
  Future<void> push(
    String remote,
    String name, {
    bool setUpstream = false,
  }) async {
    await _requireRoot();
    _check(
      await _git(['push', if (setUpstream) '-u', remote, name]),
      'Cannot push.',
    );
  }

  /// The branches, remote branches and tags with their commits' details,
  /// the last committed first (`getRefs` with `git.branchSortOrder:
  /// committerdate` and `git.showReferenceDetails`).
  Future<List<IdeGitRef>> refs() async {
    await _requireRoot();
    final output = _check(
      await _git([
        'for-each-ref',
        '--sort',
        '-committerdate',
        '--format',
        ideGitRefsFormat,
      ]),
      'Cannot read the branches.',
    );
    return parseGitRefs(output.stdout);
  }

  /// The local branches whose upstream is [upstream] (`origin/main`).
  Future<List<String>> trackingBranches(String upstream) async {
    await _requireRoot();
    final output = _check(
      await _git([
        'for-each-ref',
        '--format',
        '%(refname:short)%00%(upstream:short)',
        'refs/heads',
      ]),
      'Cannot read the branches.',
    );
    return [
      for (final line in output.stdout.trim().split('\n'))
        if (line.trim().split('\x00') case [final name, final tracked]
            when tracked == upstream)
          name,
    ];
  }

  /// `git checkout -q [--track] [--detach] <treeish>`.
  Future<void> checkout(
    String treeish, {
    bool track = false,
    bool detached = false,
  }) async {
    await _requireRoot();
    _check(
      await _git([
        'checkout',
        '-q',
        if (track) '--track',
        if (detached) '--detach',
        treeish,
      ]),
      'Cannot check out $treeish.',
    );
  }

  /// `git checkout -q -b <name> --no-track [<ref>]`: the new branch
  /// [name], checked out.
  Future<void> branch(String name, {String? ref}) async {
    await _requireRoot();
    _check(
      await _git(['checkout', '-q', '-b', name, '--no-track', ?ref]),
      'Cannot create the branch $name.',
    );
  }

  /// The resolved commit of [ref], or null.
  Future<String?> revParse(String ref) async {
    final output = await _git(['rev-parse', '--verify', '-q', ref]);
    return output.exitCode == 0 ? output.stdout.trim() : null;
  }

  /// The best common ancestor of [a] and [b], or null.
  Future<String?> mergeBase(String a, String b) async {
    final output = await _git(['merge-base', a, b]);
    return output.exitCode == 0 ? output.stdout.trim() : null;
  }

  /// `git log` of [refs] in topological order, newest first.
  Future<List<IdeGitCommit>> log({
    List<String> refs = const ['HEAD'],
    int limit = 50,
  }) async {
    await _requireRoot();
    final output = _check(
      await _git([
        'log',
        '--topo-order',
        '--decorate=full',
        '--format=$ideGitLogFormat',
        '-n',
        '$limit',
        ...refs,
        '--',
      ]),
      'Cannot read the Git history.',
    );
    return parseGitLog(output.stdout);
  }

  /// The commits that changed [path], following renames.
  Future<List<IdeGitCommit>> fileLog(String path, {int limit = 50}) async {
    final top = await _requireRoot();
    final output = _check(
      await _git([
        'log',
        '--follow',
        '--decorate=full',
        '--format=$ideGitLogFormat',
        '-n',
        '$limit',
        '--',
        ..._relative(top, [path]),
      ]),
      'Cannot read the file\'s history.',
    );
    return parseGitLog(output.stdout);
  }

  /// The files [commit] changed against its first parent.
  Future<List<IdeGitCommitChange>> commitChanges(String commit) async {
    final top = await _requireRoot();
    final output = _check(
      await _git([
        'show',
        '--format=',
        '--name-status',
        '-z',
        '--first-parent',
        '-m',
        commit,
      ]),
      'Cannot read the commit.',
    );
    final fields = output.stdout.split('\x00');
    final changes = <IdeGitCommitChange>[];
    String absolute(String relative) => pathContext.normalize(
      pathContext.join(top, pathContext.joinAll(relative.split('/'))),
    );
    for (var i = 0; i + 1 < fields.length; i++) {
      final status = fields[i].trim();
      if (status.isEmpty) continue;
      if (status.startsWith('R') || status.startsWith('C')) {
        if (i + 2 >= fields.length) break;
        changes.add(
          IdeGitCommitChange(
            absolute(fields[i + 2]),
            status[0],
            originalPath: absolute(fields[i + 1]),
          ),
        );
        i += 2;
      } else {
        changes.add(IdeGitCommitChange(absolute(fields[i + 1]), status[0]));
        i += 1;
      }
    }
    return changes;
  }
}
