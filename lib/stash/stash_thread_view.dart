import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../chat/widgets/hover_builder.dart';
import '../forge/forge_ref.dart' show ForgeItemKind;
import '../ide/ide_hover.dart';
import '../l10n/l10n.dart';
import '../sidebar/sidebar.dart' show SidebarPull, SidebarStash, SidebarStashes;
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../workspace/editor_launcher.dart' show openExternal;
import '../workspace/thread_status_mark.dart';
import '../workspace/workspace.dart';
import 'stash_controller.dart';
import 'stash_note.dart';

/// What the sidebar shows of [controller]'s stashes: each conversation's
/// on its row, [open] showing one; and the pull requests it opened for
/// them, in their state, opened in the browser.
SidebarStashes sidebarStashes(
  StashController controller,
  ValueChanged<int> open,
) => SidebarStashes(
  changes: Listenable.merge([controller.store, ?controller.forge]),
  of: (session) => <SidebarStash>[
    for (final note in controller.threads.stashesOf(session))
      (
        id: note.id,
        title: note.displayTitle,
        done: note.status == StashStatus.done,
      ),
  ],
  open: open,
  pulls: (session) => _pullsOf(controller, session),
  openPull: (url) => unawaited(openExternal(url)),
);

List<SidebarPull> _pullsOf(StashController controller, String session) {
  final forge = controller.forge;
  if (forge == null) return const [];
  final pulls = <String, SidebarPull>{};
  for (final note in controller.store.notes) {
    for (final link in note.issues) {
      if (link.session != session || pulls.containsKey(link.url)) continue;
      final ref = forge.refOf(link.url);
      if (ref == null || ref.kind != ForgeItemKind.pull) continue;
      pulls[link.url] = (
        url: link.url,
        tag: ref.fullTag,
        title: forge.itemOf(link.url)?.title ?? link.title,
        state: forge.stateOf(link),
      );
    }
  }
  return [...pulls.values];
}

/// [at] as the stashes show times: today's by the clock, this year's by
/// day, others by year.
String stashDateText(DateTime at) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(at.hour)}:${two(at.minute)}';
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return time;
  }
  if (at.year == now.year) return '${at.month}/${at.day} $time';
  return '${at.year}/${at.month}/${at.day}';
}

/// What a stash's links show of their conversation: listed (to open it,
/// and its status live), its title, what its agent last said.
typedef _Shown = ({AgentThread? thread, String title, String? said});

_Shown _shown(
  StashController controller,
  StashThreadLink link,
  AppLocalizations l10n,
) {
  final thread = controller.threads.threadOf(link);
  return (
    thread: thread,
    title:
        thread?.localizedTitle(l10n) ??
        link.title ??
        link.session.substring(0, 8),
    said: link.said,
  );
}

/// The conversation's mark: its status as the sidebar shows it while it
/// runs, waits or finished unseen; else a chat, faint when it is not
/// listed any more.
Widget _mark(
  AgentThread? thread, {
  IconData icon = Codicons.commentDiscussion,
}) {
  Widget idle(bool listed) => Icon(
    icon,
    size: 14,
    color: listed ? AppColors.textMuted : AppColors.textFaint,
  );
  return SizedBox.square(
    dimension: 16,
    child: Center(
      child: thread == null
          ? idle(false)
          : ThreadStatusBuilder(
              thread,
              (context, status) => status == ThreadStatus.idle
                  ? idle(true)
                  : ThreadStatusMark(status),
            ),
    ),
  );
}

/// Where a row's lines under its title start: past its 16px mark and
/// the gap after it.
const stashRowIndent = 22.0;

/// A clickable box, as the cards' rows are: framed, lit on hover.
class StashRowBox extends StatelessWidget {
  const StashRowBox({
    super.key,
    required this.onTap,
    required this.child,
    this.padding,
  });

  final VoidCallback? onTap;
  final EdgeInsets? padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => HoverBuilder(
    cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    builder: (context, hovered) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: padding ?? const EdgeInsets.fromLTRB(6, 5, 8, 5),
        decoration: BoxDecoration(
          color: hovered && onTap != null ? AppColors.hover : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      ),
    ),
  );
}

/// On a stash's card: the conversation it was last worked on in (its
/// status, title, what its agent last said; how many more there are).
/// Shown only: a click on it is the card's, opening the stash, not the
/// conversation (its detail lists them, each a click away).
class StashThreadChip extends StatelessWidget {
  const StashThreadChip({
    super.key,
    required this.controller,
    required this.note,
  });

  final StashController controller;
  final StashNote note;

  /// The link it shows: the one whose turn ended last.
  static StashThreadLink? latest(StashNote note) {
    StashThreadLink? latest;
    for (final link in note.threads) {
      final at = link.at;
      final best = latest?.at;
      if (latest == null ||
          (at != null && (best == null || at.isAfter(best)))) {
        latest = link;
      }
    }
    return latest;
  }

  @override
  Widget build(BuildContext context) {
    final link = latest(note);
    if (link == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    final shown = _shown(controller, link, l10n);
    final more = note.threads.length - 1;
    final thread = shown.thread;
    return StashRowBox(
      onTap: null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _mark(thread),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  shown.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (more > 0)
                Text(
                  '+$more',
                  style: TextStyle(color: AppColors.textFaint, fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Expanded(
            child: Text(
              shown.said ?? l10n.stashThreadNoReply,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: shown.said == null
                    ? AppColors.textFaint
                    : AppColors.textMuted,
                fontSize: 11.5,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// In a stash's detail: the conversations it is carried out in, the one
/// whose turn ended last first, and the one it was noted in; each with
/// its status, title, project and time, what its agent last said, and a
/// click away.
class StashThreadList extends StatelessWidget {
  const StashThreadList({
    super.key,
    required this.controller,
    required this.note,
    this.onOpen,
  });

  final StashController controller;
  final StashNote note;
  final ValueChanged<AgentThread>? onOpen;

  @override
  Widget build(BuildContext context) {
    final links = [...note.threads]
      ..sort((a, b) => (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0)));
    final source = note.source;
    final noted = switch (source.thread) {
      final session? when note.threadOf(session) == null => StashThreadLink(
        session: session,
        project: source.project ?? '',
      ),
      _ => null,
    };
    if (links.isEmpty && noted == null) return const SizedBox.shrink();
    final l10n = context.l10n;
    return ListenableBuilder(
      // Titled, listed, or gone meanwhile.
      listenable: controller.workspace,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.stashThreads,
            style: TextStyle(
              color: AppColors.textMuted,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final link in links) ...[
            const SizedBox(height: 6),
            _row(context, link),
          ],
          if (noted != null) ...[
            const SizedBox(height: 6),
            _row(context, noted, noted: true),
          ],
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    StashThreadLink link, {
    bool noted = false,
  }) {
    final l10n = context.l10n;
    final shown = _shown(controller, link, l10n);
    final thread = shown.thread;
    final said = noted ? l10n.stashThreadSource : shown.said;
    final details = [
      ?_projectName(link.project),
      if (link.at case final at?) stashDateText(at),
    ].join(' · ');
    final row = StashRowBox(
      onTap: thread == null || onOpen == null ? null : () => onOpen!(thread),
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 7),
      // The mark in the title's line, in its middle; the line under it
      // from where the title starts.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _mark(
                thread,
                icon: noted ? Codicons.note : Codicons.commentDiscussion,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  shown.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (details.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  details,
                  style: TextStyle(color: AppColors.textFaint, fontSize: 11),
                ),
              ],
            ],
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.only(left: stashRowIndent),
            child: Text(
              said ?? l10n.stashThreadNoReply,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: said == null ? AppColors.textFaint : AppColors.textMuted,
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
    return thread == null
        ? IdeHover(message: l10n.stashThreadGone, child: row)
        : row;
  }

  String? _projectName(String path) {
    if (path.isEmpty) return null;
    for (final project in controller.workspace.projects) {
      if (project.path == path) return project.name;
    }
    return p.basename(path);
  }
}
