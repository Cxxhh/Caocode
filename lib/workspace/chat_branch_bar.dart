// Under the chat input: the Git branch the agent works on. A project's
// branch (`*` after it with changes not committed), a menu of its branches
// to switch to and Create Branch…; a workspace's name, a menu of its
// folders with each one's branches at its side. Nothing to switch while
// the agent works (the files would change under it), nor without a
// repository: then only the name.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_session.dart';
import '../chat/composer/composer_picker.dart';
import '../ide/git/git_checkout.dart' show ideSanitizeBranchName;
import '../ide/git/git_model.dart';
import '../ide/git/git_repository.dart';
import '../ide/ide_dialog.dart';
import '../ide/ide_hover.dart';
import '../kernel/kernel_types.dart';
import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';

class ChatBranchBar extends StatefulWidget {
  const ChatBranchBar({
    super.key,
    required this.session,
    required this.name,
    this.workspace = false,
    this.repositories = const [],
  });

  /// The conversation whose input it is under: nothing is switched while
  /// it works.
  final ChatSession session;

  /// The project's name, or the workspace's.
  final String name;

  /// Whether it is a multi-folder workspace's, [repositories] its folders'.
  final bool workspace;

  /// The project's repository, or each of the workspace's folders', by
  /// folder; none without Git.
  final List<(String, IdeGitRepository)> repositories;

  @override
  State<ChatBranchBar> createState() => _ChatBranchBarState();
}

class _ChatBranchBarState extends State<ChatBranchBar> {
  /// Each repository's local branches, the last committed first.
  final Map<IdeGitRepository, List<String>> _branches = {};

  /// The branch each repository was on when its branches were read, and
  /// when: read again once it is on another, or pointed at a while after.
  final Map<IdeGitRepository, (String?, DateTime)> _read = {};

  static const _readAgainAfter = Duration(seconds: 3);

  /// Between an option of a workspace's submenu's folder and its branch.
  static const _separator = '\u0000';

  /// The branch of a workspace folder's Create Branch….
  static const _create = '\u0001';

  Iterable<IdeGitRepository> get _gits =>
      widget.repositories.map((repository) => repository.$2);

  @override
  void initState() {
    super.initState();
    for (final git in _gits) {
      git.addListener(_gitChanged);
    }
    _gitChanged();
  }

  @override
  void didUpdateWidget(ChatBranchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = {for (final (_, git) in oldWidget.repositories) git};
    final now = {..._gits};
    for (final git in old.difference(now)) {
      git.removeListener(_gitChanged);
      _branches.remove(git);
      _read.remove(git);
    }
    for (final git in now.difference(old)) {
      git.addListener(_gitChanged);
    }
    _gitChanged();
  }

  @override
  void dispose() {
    for (final git in _gits) {
      git.removeListener(_gitChanged);
    }
    super.dispose();
  }

  /// Reads the branches of a repository not read yet, or since on another.
  void _gitChanged() {
    for (final git in _gits) {
      final state = git.state;
      if (state == null) continue;
      if (_read[git] case (final branch, _) when branch == state.head.branch) {
        continue;
      }
      unawaited(_readBranches(git));
    }
  }

  /// Reads them again when pointed at: one made elsewhere shows.
  void _pointedAt() {
    final now = DateTime.now();
    for (final git in _gits) {
      if (!git.isRepository) continue;
      if (_read[git] case (_, final at)
          when now.difference(at) < _readAgainAfter) {
        continue;
      }
      unawaited(_readBranches(git));
    }
  }

  Future<void> _readBranches(IdeGitRepository git) async {
    _read[git] = (git.state?.head.branch, DateTime.now());
    try {
      final refs = await git.refs();
      if (!mounted || !_gits.contains(git)) return;
      setState(() {
        _branches[git] = [
          for (final ref in refs)
            if (ref.kind == IdeGitRefKind.branch) ref.name,
        ];
      });
    } on Object {
      // Not a repository after all, or Git failed: the menu lists what it
      // knows.
    }
  }

  /// [git]'s branch, as the pill reads it.
  String _branchLabel(IdeGitState state) {
    final branch = state.head.branch ?? context.l10n.branchBarDetached;
    return state.resources.isEmpty ? branch : '$branch*';
  }

  /// [git]'s branches, the one it is on among them.
  List<String> _branchesOf(IdeGitRepository git) {
    final branches = _branches[git] ?? const [];
    final current = git.state?.head.branch;
    return [
      if (current != null && !branches.contains(current)) current,
      ...branches,
    ];
  }

  // --- Actions ----------------------------------------------------------------

  /// Runs [operation] on [branch] unless the agent has started meanwhile;
  /// what Git said when it refused, in a dialog.
  Future<void> _run(String branch, Future<void> Function() operation) async {
    if (widget.session.isStreaming) return;
    try {
      await operation();
    } on Object catch (error) {
      if (!mounted) return;
      final l10n = context.l10n;
      await showIdeDialog(
        context,
        message: l10n.branchBarFailed(branch),
        detail: '$error',
        buttons: [l10n.commonOk],
        cancel: null,
        type: IdeDialogType.error,
      );
    }
  }

  void _checkout(IdeGitRepository git, String branch) {
    if (branch == git.state?.head.branch) return;
    unawaited(_run(branch, () => git.checkout(branch)));
  }

  /// Asks for a branch's name, then makes it where [git] is and checks it
  /// out; [message] says where.
  Future<void> _createBranch(IdeGitRepository git, String message) async {
    final l10n = context.l10n;
    final result = await showIdeInputDialog(
      context,
      message: message,
      buttons: [l10n.branchBarCreateButton],
      inputs: [IdeDialogInput(placeholder: l10n.gitBranchName)],
      type: IdeDialogType.question,
    );
    if (result == null || result.button != 0) return;
    final name = ideSanitizeBranchName(result.values.first);
    if (name.isEmpty) return;
    await _run(name, () => git.branch(name));
  }

  // --- Building -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.session, ..._gits]),
      builder: (context, _) => Padding(
        padding: const EdgeInsets.only(top: 4, left: 4),
        child: MouseRegion(
          onEnter: (_) => _pointedAt(),
          child: Row(children: [Flexible(child: _buildPill(context))]),
        ),
      ),
    );
  }

  Widget _buildPill(BuildContext context) {
    final l10n = context.l10n;
    final running = widget.session.isStreaming;
    if (widget.workspace) {
      if (running || widget.repositories.isEmpty) {
        return _Label(
          icon: Codicons.folderLibrary,
          label: widget.name,
          tooltip: running ? l10n.branchBarRunning : null,
        );
      }
      return _buildWorkspacePicker(context);
    }
    final git = widget.repositories.firstOrNull?.$2;
    final state = git?.state;
    if (git == null || state == null) {
      return _Label(icon: Codicons.folder, label: widget.name);
    }
    if (running) {
      return _Label(
        icon: Codicons.gitBranch,
        label: _branchLabel(state),
        tooltip: l10n.branchBarRunning,
      );
    }
    final current = state.head.branch;
    KernelOption option(String branch) =>
        KernelOption(branch, branch, Codicons.gitBranch, '');
    return ComposerPicker(
      options: [for (final branch in _branchesOf(git)) option(branch)],
      selected: current == null
          ? KernelOption('', l10n.branchBarDetached, Codicons.gitBranch, '')
          : option(current),
      label: _branchLabel(state),
      describes: false,
      title: l10n.branchBarSwitch,
      searchPlaceholder: l10n.branchBarSearch,
      footer: (
        label: l10n.branchBarCreate,
        icon: Codicons.add,
        onTap: () => unawaited(
          _createBranch(
            git,
            l10n.branchBarCreateFrom(current ?? l10n.branchBarDetached),
          ),
        ),
      ),
      onSelected: (option) => _checkout(git, option.id),
    );
  }

  /// The workspace's folders, each one's branches at its side.
  Widget _buildWorkspacePicker(BuildContext context) {
    final l10n = context.l10n;
    final gits = {for (final (folder, git) in widget.repositories) folder: git};
    // A workspace's folders are this machine's.
    String nameOf(String folder) => p.basename(folder);
    const create = KernelOptionGroup('create', '');
    return ComposerPicker(
      options: [
        for (final (folder, git) in widget.repositories)
          KernelOption(
            folder,
            nameOf(folder),
            Codicons.folder,
            switch (git.state) {
              final state? => _branchLabel(state),
              null => l10n.branchBarNotRepository,
            },
          ),
      ],
      selected: KernelOption('', widget.name, Codicons.folderLibrary, ''),
      // A line each, its branch at its end.
      descriptionAside: true,
      title: l10n.branchBarWorkspace,
      tooltip: l10n.branchBarWorkspace,
      menuWidth: 290,
      submenuOf: (option) => switch (gits[option.id]) {
        final git? when git.isRepository => [
          for (final branch in _branchesOf(git))
            KernelOption(
              '${option.id}$_separator$branch',
              branch,
              Codicons.gitBranch,
              '',
            ),
          KernelOption(
            '${option.id}$_separator$_create',
            l10n.branchBarCreate,
            Codicons.add,
            '',
            group: create,
          ),
        ],
        _ => const [],
      },
      // Each folder's branch.
      checks: (option) {
        final at = option.id.indexOf(_separator);
        if (at < 0) return false;
        final git = gits[option.id.substring(0, at)];
        return option.id.substring(at + 1) == git?.state?.head.branch;
      },
      onSelected: (option) {
        final at = option.id.indexOf(_separator);
        if (at < 0) return;
        final folder = option.id.substring(0, at);
        final branch = option.id.substring(at + 1);
        final git = gits[folder];
        if (git == null) return;
        if (branch == _create) {
          unawaited(_createBranch(git, l10n.branchBarCreateIn(nameOf(folder))));
        } else {
          _checkout(git, branch);
        }
      },
    );
  }
}

/// The pill's look with nothing to open: the name of a folder without a
/// repository, or the branch while the agent works ([tooltip] says so).
class _Label extends StatelessWidget {
  const _Label({required this.icon, required this.label, this.tooltip});

  final IconData icon;
  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final color = tooltip == null ? AppColors.textMuted : AppColors.textFaint;
    Widget label = Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              this.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 12),
            ),
          ),
        ],
      ),
    );
    if (tooltip case final tooltip?) {
      label = IdeHover(message: tooltip, child: label);
    }
    return label;
  }
}
