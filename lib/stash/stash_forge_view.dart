import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/widgets/hover_builder.dart';
import '../forge/forge_accounts.dart';
import '../forge/forge_api.dart';
import '../forge/forge_ref.dart';
import '../forge/forge_view.dart';
import '../ide/ide_button.dart';
import '../ide/ide_hover.dart';
import '../ide/ide_input.dart';
import '../ide/ide_menu.dart';
import '../ide/ide_spinning.dart';
import '../l10n/l10n.dart';
import '../settings/pages/model_dialogs.dart'
    show ModelCheckbox, ModelDialogFrame;
import '../settings/pages/settings_dropdown.dart';
import '../settings/settings_dialog.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/editor_launcher.dart' show openExternal;
import '../workspace/workspace.dart' show Project;
import 'stash_forge.dart';
import 'stash_note.dart';
import 'stash_thread_view.dart' show StashRowBox, stashRowIndent;
import 'stash_view.dart' show StashBadge, StashBanner;

/// [state]'s name, as the stashes show it.
String forgeStateLabel(
  AppLocalizations l10n,
  ForgeItemKind kind,
  ForgeState state,
) => switch (state) {
  ForgeState.open => l10n.forgeStateOpen,
  ForgeState.draft => l10n.forgeStateDraft,
  ForgeState.closed => l10n.forgeStateClosed,
  ForgeState.merged => l10n.forgeStateMerged,
};

/// Shows Settings → Accounts, where the window can (null where it cannot:
/// the Stash panel's own window).
VoidCallback? accountsOpener(BuildContext context) =>
    switch (SettingsOpener.maybeOf(context)) {
      final open? => () => open(SettingsSection.accounts),
      null => null,
    };

// --- On a card -----------------------------------------------------------------

/// On a stash's card: its first issue or pull request, in its state's
/// color, and how many more.
class StashIssueBadge extends StatelessWidget {
  const StashIssueBadge({super.key, required this.forge, required this.note});

  final StashForge forge;
  final StashNote note;

  @override
  Widget build(BuildContext context) {
    final links = [
      for (final link in note.issues)
        if (forge.refOf(link.url) case final ref?) (link, ref),
    ];
    if (links.isEmpty) return const SizedBox.shrink();
    final (link, ref) = links.first;
    final state = forge.stateOf(link);
    final (icon, color) = forgeStateLook(ref.kind, state);
    final l10n = context.l10n;
    return IdeHover(
      message: [
        for (final (link, ref) in links)
          [
            ref.fullTag,
            ?link.title,
            if (forge.stateOf(link) case final state?)
              '(${forgeStateLabel(l10n, ref.kind, state)})',
          ].join(' '),
      ].join('\n'),
      child: StashBadge(
        icon: icon,
        color: color,
        label: [
          ref.tag,
          if (links.length > 1) '+${links.length - 1}',
        ].join(' '),
      ),
    );
  }
}

// --- In its detail -------------------------------------------------------------

/// In a stash's detail: what its issues ask of the user (closed: is it
/// done? it done: say so there?), then each issue and pull request linked
/// (its state, title, labels, checks), opened in the browser by a click,
/// commented on or closed from its menu, once the user confirms what goes.
class StashIssueSection extends StatefulWidget {
  const StashIssueSection({super.key, required this.forge, required this.note});

  final StashForge forge;
  final StashNote note;

  @override
  State<StashIssueSection> createState() => _StashIssueSectionState();
}

class _StashIssueSectionState extends State<StashIssueSection> {
  @override
  void initState() {
    super.initState();
    // Shown: it should be as it is now.
    unawaited(widget.forge.refreshNote(widget.note.id));
  }

  @override
  void didUpdateWidget(StashIssueSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.note.id != widget.note.id) {
      unawaited(widget.forge.refreshNote(widget.note.id));
    }
  }

  StashForge get _forge => widget.forge;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _forge,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final l10n = context.l10n;
    final note = widget.note;
    final links = [
      for (final link in note.issues)
        if (_forge.refOf(link.url) case final ref?) (link, ref),
    ];
    if (links.isEmpty) return const SizedBox.shrink();
    // Issues first, then pull requests.
    links.sort((a, b) => a.$2.kind.index - b.$2.kind.index);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final link in _forge.closedIssues(note))
          StashBanner(
            icon: Codicons.issueClosed,
            iconColor: themeColors['charts.purple'],
            text: l10n.stashIssueClosedBanner(_tagOf(link)),
            actions: [
              (l10n.stashMarkDone, () => unawaited(_markDone(link))),
              (
                l10n.stashDismiss,
                () => unawaited(_forge.answer(note.id, [link.url])),
              ),
            ],
          ),
        for (final link in _forge.openIssues(note))
          StashBanner(
            icon: Codicons.issues,
            iconColor: themeColors['charts.green'],
            text: l10n.stashIssueOpenBanner(_tagOf(link)),
            actions: [
              (
                l10n.stashIssueReplyClose,
                () => unawaited(_write(link, close: true, draft: true)),
              ),
              (
                l10n.stashDismiss,
                () => unawaited(_forge.answer(note.id, [link.url])),
              ),
            ],
          ),
        const SizedBox(height: 12),
        Text(
          l10n.stashIssues,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        for (final (link, ref) in links) ...[
          const SizedBox(height: 6),
          _row(context, link, ref),
        ],
      ],
    );
  }

  String _tagOf(StashIssueLink link) =>
      _forge.refOf(link.url)?.fullTag ?? link.url;

  Future<void> _markDone(StashIssueLink link) async {
    final id = widget.note.id;
    await _forge.store.update(id, (note) => note.status = StashStatus.done);
    await _forge.answer(id, [link.url]);
  }

  Future<void> _write(
    StashIssueLink link, {
    bool close = false,
    bool draft = false,
  }) => showStashWriteDialog(
    context,
    forge: _forge,
    note: widget.note,
    link: link,
    close: close,
    draft: draft
        ? stashWriteDraft(context.l10n, _forge, widget.note, link)
        : '',
  );

  Widget _row(BuildContext context, StashIssueLink link, ForgeRef ref) {
    final l10n = context.l10n;
    final item = _forge.itemOf(link.url);
    final state = _forge.stateOf(link);
    final checks = item?.checks ?? ForgeChecks.parse(link.checks);
    final failure = _forge.failureOf(link.url);
    final signedIn = _forge.canAsk(link.url);
    final faint = TextStyle(color: AppColors.textFaint, fontSize: 12);
    final openSettings = accountsOpener(context);
    final details = <Widget>[
      if (state != null)
        Text(forgeStateLabel(l10n, ref.kind, state), style: faint),
      if (item?.author case final author?) Text('@$author', style: faint),
      for (final label in item?.labels.take(4) ?? const <ForgeLabel>[])
        _Label(label),
      if (!signedIn) ...[
        Text(l10n.stashIssueNotSignedIn(ref.repo.kind.label), style: faint),
        if (openSettings != null)
          _Link(l10n.stashIssueSignIn, onTap: openSettings),
      ] else if (failure != null)
        IdeHover(
          message: failure.message,
          child: Text(
            l10n.stashIssueFailed,
            style: faint.copyWith(color: themeColors['errorForeground']),
          ),
        ),
    ];
    final title = item?.title ?? link.title;
    // As the conversations' rows above it: the same frame, mark, title
    // line and line under it; its number where theirs say when.
    return StashRowBox(
      onTap: () => unawaited(openExternal(link.url)),
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox.square(
                dimension: 16,
                child: Center(child: ForgeStateIcon(ref.kind, state)),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  // Its number in its place till its title is known.
                  title ?? ref.fullTag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (title != null) ...[
                const SizedBox(width: 8),
                Text(
                  ref.fullTag,
                  style: TextStyle(color: AppColors.textFaint, fontSize: 11),
                ),
              ],
              if (checks != null) ...[
                const SizedBox(width: 6),
                IdeHover(
                  message: switch (checks) {
                    ForgeChecks.success => l10n.forgeChecksPassed,
                    ForgeChecks.failure => l10n.forgeChecksFailed,
                    ForgeChecks.pending => l10n.forgeChecksRunning,
                  },
                  child: ForgeChecksIcon(checks, size: 12),
                ),
              ],
              const SizedBox(width: 4),
              IdeMenuButton(
                icon: Codicons.ellipsis,
                tooltip: l10n.stashMore,
                size: 16,
                iconSize: 14,
                entries: () => _entries(l10n, link, ref, state, signedIn),
              ),
            ],
          ),
          if (details.isNotEmpty) ...[
            const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsets.only(left: stashRowIndent),
              child: Wrap(
                spacing: 6,
                runSpacing: 3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: details,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<IdeMenuEntry> _entries(
    AppLocalizations l10n,
    StashIssueLink link,
    ForgeRef ref,
    ForgeState? state,
    bool signedIn,
  ) {
    final inText = widget.note.body.contains(link.url);
    return ideMenuGroups([
      [
        IdeMenuAction(
          l10n.stashIssueOpen,
          onSelected: () => unawaited(openExternal(link.url)),
        ),
        IdeMenuAction(
          l10n.stashIssueCopy,
          onSelected: () =>
              unawaited(Clipboard.setData(ClipboardData(text: link.url))),
        ),
      ],
      [
        if (signedIn)
          IdeMenuAction(
            l10n.stashIssueComment,
            onSelected: () => unawaited(_write(link)),
          ),
        if (signedIn &&
            ref.kind == ForgeItemKind.issue &&
            (state?.isOpen ?? false))
          IdeMenuAction(
            l10n.stashIssueClose,
            onSelected: () => unawaited(_write(link, close: true)),
          ),
      ],
      [
        // Linked by its text, it would be linked again.
        if (!inText)
          IdeMenuAction(
            l10n.stashIssueUnlink,
            onSelected: () =>
                unawaited(_forge.unlink(widget.note.id, link.url)),
          ),
      ],
    ]);
  }
}

class _Label extends StatelessWidget {
  const _Label(this.label);

  final ForgeLabel label;

  @override
  Widget build(BuildContext context) {
    final color = forgeLabelColor(label.color) ?? AppColors.textFaint;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Text(
        label.name,
        style: TextStyle(color: AppColors.text, fontSize: 10.5),
      ),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link(this.label, {required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HoverBuilder(
    cursor: SystemMouseCursors.click,
    builder: (context, hovered) => GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(
          color: themeColors['textLink.foreground'],
          fontSize: 12,
          decoration: hovered ? TextDecoration.underline : null,
          decorationColor: themeColors['textLink.foreground'],
        ),
      ),
    ),
  );
}

// --- Written there -------------------------------------------------------------

/// What is offered to say on [link]'s issue when [note] is done: the pull
/// requests it was done in, if it is linked to any.
String stashWriteDraft(
  AppLocalizations l10n,
  StashForge forge,
  StashNote note,
  StashIssueLink link,
) {
  final issue = forge.refOf(link.url);
  final pulls = [
    for (final other in note.issues)
      if (forge.refOf(other.url) case final ref?
          when ref.kind == ForgeItemKind.pull)
        // The forge links its own repository's by their number.
        ref.repo == issue?.repo ? ref.tag : ref.url.toString(),
  ];
  return pulls.isEmpty ? '' : l10n.stashWriteFixedIn(pulls.join(', '));
}

/// Comments on [link]'s issue or pull request, and closes it when [close]
/// is checked (an issue's): what goes shown in full, editable, and what
/// should not go out (a path on this machine, a secret) pointed out; sent
/// only by the user's click.
Future<void> showStashWriteDialog(
  BuildContext context, {
  required StashForge forge,
  required StashNote note,
  required StashIssueLink link,
  bool close = false,
  String draft = '',
}) => showGeneralDialog<void>(
  context: context,
  // Closed by its buttons, Escape or the close button: a click beside it
  // would lose what was typed.
  barrierDismissible: false,
  barrierLabel: context.l10n.commonDismiss,
  barrierColor: const Color(0x80000000),
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) => StashWriteDialog(
    forge: forge,
    note: note,
    link: link,
    close: close,
    draft: draft,
  ),
);

class StashWriteDialog extends StatefulWidget {
  const StashWriteDialog({
    super.key,
    required this.forge,
    required this.note,
    required this.link,
    this.close = false,
    this.draft = '',
  });

  final StashForge forge;
  final StashNote note;
  final StashIssueLink link;
  final bool close;
  final String draft;

  @override
  State<StashWriteDialog> createState() => _StashWriteDialogState();
}

class _StashWriteDialogState extends State<StashWriteDialog> {
  late final _text = TextEditingController(text: widget.draft);
  late bool _close = widget.close;
  var _sending = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  ForgeRef? get _ref => widget.forge.refOf(widget.link.url);

  bool get _canClose =>
      _ref?.kind == ForgeItemKind.issue &&
      (widget.forge.stateOf(widget.link)?.isOpen ?? true);

  Future<void> _send() async {
    final text = _text.text.trim();
    final close = _close && _canClose;
    if (_sending || text.isEmpty && !close) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.forge.write(
        widget.note.id,
        widget.link.url,
        text: text,
        close: close,
      );
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = error is ForgeException ? error.message : '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ref = _ref;
    final text = _text.text.trim();
    final close = _close && _canClose;
    final sensitive = StashForge.sensitive(_text.text);
    final account = ref == null
        ? null
        : widget.forge.accounts.accountFor(ref.repo.host);
    final muted = TextStyle(color: AppColors.textMuted, fontSize: 12);
    return ModelDialogFrame(
      title: close && text.isEmpty
          ? l10n.stashWriteCloseTitle(ref?.fullTag ?? widget.link.url)
          : l10n.stashWriteTitle(ref?.fullTag ?? widget.link.url),
      actions: [
        IdeButton(
          label: text.isEmpty && close
              ? l10n.stashWriteCloseOnly
              : sensitive.isNotEmpty
              ? l10n.stashWriteSendAnyway
              : close
              ? l10n.stashWriteSendClose
              : l10n.stashWriteSend,
          spinning: _sending,
          onPressed: _sending || text.isEmpty && !close
              ? null
              : () => unawaited(_send()),
        ),
        IdeButton(
          label: l10n.commonCancel,
          secondary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.forge.itemOf(widget.link.url)?.title ?? widget.link.title
                case final title?) ...[
              Text(title, style: muted),
              const SizedBox(height: 8),
            ],
            IdeInputBox(
              controller: _text,
              placeholder: l10n.stashWritePlaceholder,
              semanticsLabel: l10n.stashWritePlaceholder,
              minLines: 5,
              maxLines: 12,
              autofocus: true,
              onChanged: (_) => setState(() {}),
            ),
            if (_canClose) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  ModelCheckbox(
                    checked: _close,
                    semanticLabel: l10n.stashWriteAlsoClose,
                    onChanged: _sending
                        ? null
                        : (checked) => setState(() => _close = checked),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: GestureDetector(
                      onTap: _sending
                          ? null
                          : () => setState(() => _close = !_close),
                      child: Text(
                        l10n.stashWriteAlsoClose,
                        style: TextStyle(color: AppColors.text, fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (sensitive.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                l10n.stashWriteSensitive,
                style: muted.copyWith(color: themeColors['charts.yellow']),
              ),
              for (final found in sensitive.toSet())
                Text(
                  '  $found',
                  style: muted.copyWith(fontFamily: AppFonts.mono),
                ),
            ],
            const SizedBox(height: 10),
            Text(
              l10n.stashWriteAs(
                account?.login ?? '-',
                ref?.repo.host ?? widget.link.url,
              ),
              style: muted,
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 10),
              SelectableText(
                l10n.stashWriteFailed(error),
                style: muted.copyWith(color: themeColors['errorForeground']),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// --- Imported ------------------------------------------------------------------

/// Imports issues as stashes: those of a project's repository (assigned
/// to the user, theirs, or all open ones; searched), checked, or one
/// pasted by its link. Completes with the stashes, those imported before
/// among them; null when dismissed.
Future<List<StashNote>?> showStashImportDialog(
  BuildContext context, {
  required StashForge forge,
  String? project,
}) => showGeneralDialog<List<StashNote>>(
  context: context,
  barrierDismissible: false,
  barrierLabel: context.l10n.commonDismiss,
  barrierColor: const Color(0x80000000),
  transitionDuration: Duration.zero,
  pageBuilder: (dialogContext, _, _) => StashImportDialog(
    forge: forge,
    project: project,
    opener: accountsOpener(context),
  ),
);

class StashImportDialog extends StatefulWidget {
  const StashImportDialog({
    super.key,
    required this.forge,
    this.project,
    this.opener,
  });

  final StashForge forge;

  /// The project shown (the cards' filter): its repository first.
  final String? project;

  /// Shows Settings → Accounts, where it can be.
  final VoidCallback? opener;

  @override
  State<StashImportDialog> createState() => _StashImportDialogState();
}

typedef _Repo = ({ForgeRepo repo, Project project});

class _StashImportDialogState extends State<StashImportDialog> {
  List<_Repo>? _repos;
  _Repo? _repo;
  var _filter = ForgeIssueFilter.assigned;
  final _query = TextEditingController();
  final _link = TextEditingController();
  Timer? _typing;

  /// The repository's issues as listed for [_filter] and [_query]; null
  /// while they are asked.
  List<ForgeItem>? _items;
  String? _listError;

  /// Those pasted by their link, first.
  final List<ForgeItem> _pasted = [];
  String? _linkError;
  var _pasting = false;

  final Set<String> _checked = {};
  var _importing = false;

  /// Each list asked, numbered: an answer to one asked since is dropped.
  var _asked = 0;

  ForgeAccounts get _accounts => widget.forge.accounts;

  @override
  void initState() {
    super.initState();
    unawaited(_listRepos());
  }

  @override
  void dispose() {
    _typing?.cancel();
    _query.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _listRepos() async {
    final repos = await widget.forge.repositories();
    if (!mounted) return;
    setState(() {
      _repos = repos;
      _repo =
          repos.where((r) => r.project.path == widget.project).firstOrNull ??
          repos.firstOrNull;
    });
    unawaited(_list());
  }

  Future<void> _list() async {
    final repo = _repo;
    final asked = ++_asked;
    final api = repo == null ? null : _accounts.apiFor(repo.repo.host);
    setState(() {
      _items = null;
      _listError = null;
    });
    if (repo == null || api == null) return;
    try {
      final items = await api.issues(
        repo.repo,
        filter: _filter,
        query: _query.text.trim(),
      );
      if (mounted && asked == _asked) setState(() => _items = items);
    } on Object catch (error) {
      if (mounted && asked == _asked) {
        setState(
          () => _listError = error is ForgeException ? error.message : '$error',
        );
      }
    }
  }

  void _typed(String _) {
    _typing?.cancel();
    _typing = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_list()),
    );
  }

  Future<void> _paste() async {
    final l10n = context.l10n;
    final ref = widget.forge.refOf(_link.text.trim());
    if (ref == null) {
      setState(() => _linkError = l10n.stashImportNotALink);
      return;
    }
    final api = _accounts.apiOf(ref);
    if (api == null) {
      setState(() => _linkError = l10n.stashImportSignIn(ref.repo.kind.label));
      return;
    }
    setState(() {
      _pasting = true;
      _linkError = null;
    });
    try {
      final item = await api.item(ref);
      if (!mounted) return;
      final url = item.ref.url.toString();
      setState(() {
        _pasting = false;
        _pasted.removeWhere((pasted) => pasted.ref.url.toString() == url);
        _pasted.insert(0, item);
        if (widget.forge.stashOf(url) == null) _checked.add(url);
        _link.clear();
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _pasting = false;
        _linkError = error is ForgeException ? error.message : '$error';
      });
    }
  }

  Future<void> _import() async {
    final items = <String, ForgeItem>{
      for (final item in [..._pasted, ...?_items])
        if (_checked.contains(item.ref.url.toString()))
          item.ref.url.toString(): item,
    };
    if (items.isEmpty || _importing) return;
    setState(() => _importing = true);
    final notes = <StashNote>[];
    // Each about its repository's project.
    for (final item in items.values) {
      final project =
          _repos
              ?.where((repo) => repo.repo == item.ref.repo)
              .firstOrNull
              ?.project
              .path ??
          widget.project;
      notes.addAll(await widget.forge.import([item], project: project));
    }
    if (mounted) Navigator.pop(context, notes);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final count = _checked.length;
    final muted = TextStyle(color: AppColors.textMuted, fontSize: 12);
    return ModelDialogFrame(
      title: l10n.stashImportTitle,
      onSubmit: count == 0 ? null : () => unawaited(_import()),
      actions: [
        IdeButton(
          label: count == 0
              ? l10n.stashImportAction
              : l10n.stashImportCount(count),
          spinning: _importing,
          onPressed: count == 0 || _importing
              ? null
              : () => unawaited(_import()),
        ),
        IdeButton(
          label: l10n.commonCancel,
          secondary: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: IdeInputBox(
                  controller: _link,
                  placeholder: l10n.stashImportPaste,
                  semanticsLabel: l10n.stashImportPaste,
                  onSubmitted: (_) => unawaited(_paste()),
                ),
              ),
              const SizedBox(width: 6),
              IdeButton(
                label: l10n.stashImportAdd,
                secondary: true,
                spinning: _pasting,
                onPressed: _pasting ? null : () => unawaited(_paste()),
              ),
            ],
          ),
          if (_linkError case final error?) ...[
            const SizedBox(height: 4),
            Text(
              error,
              style: muted.copyWith(color: themeColors['errorForeground']),
            ),
          ],
          const SizedBox(height: 12),
          _repoBar(l10n),
          const SizedBox(height: 8),
          Flexible(child: _listView(l10n, muted)),
        ],
      ),
    );
  }

  Widget _repoBar(AppLocalizations l10n) {
    final repos = _repos;
    final repo = _repo;
    if (repos == null || repos.isEmpty || repo == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ForgeLogo(repo.repo.kind, size: 14, color: AppColors.textMuted),
            const SizedBox(width: 6),
            Flexible(
              child: SettingsDropdown(
                current: '${repo.repo.path} · ${repo.project.name}',
                semanticLabel: l10n.stashImportRepo,
                entries: () => [
                  for (final other in repos)
                    IdeMenuAction(
                      '${other.repo.path} · ${other.project.name}',
                      checked: other == repo,
                      onSelected: () {
                        setState(() {
                          _repo = other;
                          _checked.removeWhere(
                            (url) => !_pasted.any(
                              (item) => item.ref.url.toString() == url,
                            ),
                          );
                        });
                        unawaited(_list());
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final filter in ForgeIssueFilter.values) ...[
              _Choice(
                label: switch (filter) {
                  ForgeIssueFilter.assigned => l10n.stashImportAssigned,
                  ForgeIssueFilter.created => l10n.stashImportCreated,
                  ForgeIssueFilter.all => l10n.stashImportAll,
                },
                selected: _filter == filter,
                onTap: () {
                  if (_filter == filter) return;
                  setState(() => _filter = filter);
                  unawaited(_list());
                },
              ),
              const SizedBox(width: 6),
            ],
            const SizedBox(width: 6),
            Expanded(
              child: IdeInputBox(
                controller: _query,
                placeholder: l10n.stashImportSearch,
                semanticsLabel: l10n.stashImportSearch,
                onChanged: _typed,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _listView(AppLocalizations l10n, TextStyle muted) {
    final repos = _repos;
    final repo = _repo;
    final items = [
      ..._pasted,
      for (final item in _items ?? const <ForgeItem>[])
        if (!_pasted.any((pasted) => pasted.ref == item.ref)) item,
    ];
    Widget? note;
    if (repos == null) {
      note = _waiting(l10n.stashImportLoading, muted);
    } else if (repo == null) {
      note = Text(l10n.stashImportNoRepos, style: muted);
    } else if (_accounts.accountFor(repo.repo.host) == null) {
      note = Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(l10n.stashImportSignIn(repo.repo.kind.label), style: muted),
          if (widget.opener case final open?)
            IdeButton(
              label: l10n.stashIssueSignIn,
              secondary: true,
              onPressed: () {
                Navigator.pop(context);
                open();
              },
            ),
        ],
      );
    } else if (_listError case final error?) {
      note = SelectableText(
        error,
        style: muted.copyWith(color: themeColors['errorForeground']),
      );
    } else if (_items == null) {
      note = _waiting(l10n.stashImportLoading, muted);
    } else if (_items!.isEmpty) {
      note = Text(l10n.stashImportNone, style: muted);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 340),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final item in items) _item(l10n, item),
          if (note != null)
            Padding(padding: const EdgeInsets.all(8), child: note),
        ],
      ),
    );
  }

  Widget _waiting(String text, TextStyle muted) => Row(
    children: [
      IdeSpinning(Icon(Codicons.loading, size: 14, color: AppColors.textFaint)),
      const SizedBox(width: 8),
      Flexible(child: Text(text, style: muted)),
    ],
  );

  Widget _item(AppLocalizations l10n, ForgeItem item) {
    final url = item.ref.url.toString();
    final known = widget.forge.stashOf(url);
    final checked = known != null || _checked.contains(url);
    void toggle() => setState(() {
      if (!_checked.remove(url)) _checked.add(url);
    });
    return HoverBuilder(
      cursor: known == null ? SystemMouseCursors.click : MouseCursor.defer,
      builder: (context, hovered) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: known == null ? toggle : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            color: hovered && known == null ? AppColors.hover : null,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Opacity(
            opacity: known == null ? 1 : .55,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ModelCheckbox(
                  checked: checked,
                  semanticLabel: item.title,
                  onChanged: known == null ? (_) => toggle() : null,
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: ForgeStateIcon(item.ref.kind, item.state),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppColors.text, fontSize: 13),
                      ),
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 6,
                        runSpacing: 3,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            [
                              item.ref.fullTag,
                              if (item.author case final author?) '@$author',
                              if (known != null)
                                l10n.stashImportKnown(known.id),
                            ].join(' · '),
                            style: TextStyle(
                              color: AppColors.textFaint,
                              fontSize: 11.5,
                            ),
                          ),
                          for (final label in item.labels.take(4))
                            _Label(label),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the import's filters, as a pill.
class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? themeColors['badge.background'].withValues(alpha: .5)
                : hovered
                ? AppColors.hover
                : null,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppColors.borderStrong : AppColors.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AppColors.text : AppColors.textMuted,
              fontSize: 12,
            ),
          ),
        ),
      ),
    ),
  );
}
