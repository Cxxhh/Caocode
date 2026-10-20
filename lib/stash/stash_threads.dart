import 'dart:async';

import '../chat/chat_models.dart';
import '../forge/forge_ref.dart';
import '../workspace/workspace.dart';
import 'stash_note.dart';
import 'stash_store.dart';

/// Every `[Stash #12]` in a message: how one names a stash (its tag, one
/// dropped in, "Implement in Caocode"'s message alike).
final stashReferencePattern = RegExp(r'\[Stash #(\d+)\]');

/// The pull (merge) requests [items] link to, in what the agent said or
/// its tools printed (`gh pr create`'s): their pages, once each.
List<String> stashPullsIn(Iterable<ChatItem> items, {ForgeKindOf? kindOf}) {
  final pulls = <String>{};
  void find(String? text) {
    if (text == null || !text.contains('http')) return;
    for (final ref in ForgeRef.allIn(text, kindOf: kindOf)) {
      if (ref.kind == ForgeItemKind.pull) pulls.add(ref.url.toString());
    }
  }

  for (final item in items) {
    switch (item) {
      case AssistantTextItem(:final text):
        find(text);
      case ToolCallItem(:final output, :final results):
        find(output);
        results.forEach(find);
      default:
    }
  }
  return pulls.toList();
}

/// Links the stashes to the conversations they are carried out in, from
/// what the conversations show and nothing else (see docs/stash.md): one a
/// message sent in names a stash is linked to it, the stash implementing
/// from then on; and as each of its turns ends, its title and what its
/// agent last said are kept with the link, for the cards to show while it
/// is not open. A pull (merge) request its agent opened, linked to in
/// what it said or what its tools printed, is linked to the stash too.
class StashThreads {
  StashThreads({
    required this.store,
    required this.workspace,
    this.forgeKindOf,
  });

  final StashStore store;
  final Workspace workspace;

  /// What the forges' hosts are, to tell a pull request's link (see
  /// [ForgeRef.parse]); github.com's and gitlab.com's alone without it.
  final ForgeKindOf? forgeKindOf;

  bool _started = false;
  bool _disposed = false;

  void start() {
    if (_started) return;
    _started = true;
    workspace.addListener(_changed);
    _changed();
  }

  void dispose() {
    _disposed = true;
    if (_started) workspace.removeListener(_changed);
  }

  /// The conversation [link] is to, if it is listed.
  AgentThread? threadOf(StashThreadLink link) {
    for (final thread in workspace.threads) {
      if (thread.id == link.session) return thread;
    }
    return null;
  }

  /// The stashes carried out in [session], the lowest number first: what
  /// its row in the sidebar shows.
  List<StashNote> stashesOf(String session) => [
    for (final note in store.notes)
      if (note.threadOf(session) != null) note,
  ]..sort((a, b) => a.id.compareTo(b.id));

  /// How many of each session's messages were read for the stashes they
  /// name; and of its items done with, for the pull requests they link.
  final Map<String, int> _read = {};
  final Map<String, int> _readDone = {};

  bool _syncing = false;
  bool _again = false;

  void _changed() {
    if (_disposed) return;
    if (_syncing) {
      _again = true;
      return;
    }
    unawaited(_sync());
  }

  Future<void> _sync() async {
    _syncing = true;
    try {
      do {
        _again = false;
        final seen = _seen();
        if (seen.isEmpty) continue;
        // What an agent wrote meanwhile (by the Stash skill), read before
        // it is written over.
        await store.reload();
        for (final MapEntry(key: id, value: (:threads, :pulls))
            in seen.entries) {
          final note = store.byId(id);
          if (note == null) continue;
          var changed = false;
          for (final link in threads) {
            changed = _keep(note, link) || changed;
          }
          for (final link in pulls) {
            if (note.issueOf(link.url) != null) continue;
            note.issues.add(link);
            changed = true;
          }
          if (changed) await store.save(note, touch: false);
        }
      } while (_again && !_disposed);
    } finally {
      _syncing = false;
    }
  }

  /// The links that are new or changed, by their stash's number: the
  /// stashes the open conversations' new messages name, and what those
  /// linked already were titled and last said, once a turn is over; the
  /// pull requests they opened.
  Map<int, _Seen> _seen() {
    final linked = <String, Set<int>>{};
    for (final note in store.notes) {
      for (final link in note.threads) {
        (linked[link.session] ??= {}).add(note.id);
      }
    }
    final seen = <int, _Seen>{};
    _Seen of(int id) => seen[id] ??= (threads: [], pulls: []);
    for (final thread in workspace.threads) {
      final session = thread.id;
      if (session == null || !thread.isOpen) continue;
      final ids = {...?linked[session], ..._named(session, thread)};
      final pulls = _pulls(session, thread);
      if (ids.isEmpty) continue;
      final working = switch (thread.status) {
        ThreadStatus.running || ThreadStatus.needsInput => true,
        _ => false,
      };
      for (final id in ids) {
        final note = store.byId(id);
        if (note == null) continue;
        final known = note.threadOf(session);
        final said = working
            ? known?.said
            : switch (thread.session.lastReply) {
                final reply? => oneLineExcerpt(reply, max: 240),
                null => known?.said,
              };
        final link =
            (known ??
                    StashThreadLink(
                      session: session,
                      project: thread.project.path,
                    ))
                .copyWith(
                  title: thread.title,
                  said: said,
                  at: known == null || said != known.said
                      ? DateTime.now()
                      : null,
                );
        if (link != known) of(note.id).threads.add(link);
        for (final url in pulls) {
          if (note.issueOf(url) == null) {
            of(note.id).pulls.add(StashIssueLink(url: url, session: session));
          }
        }
      }
    }
    return seen;
  }

  /// The stashes [thread]'s messages name that were not read yet.
  Set<int> _named(String session, AgentThread thread) {
    final feed = thread.session;
    // Not the row that says it is working, where a message taken up next
    // goes.
    final count = feed.itemCount - (feed.isStreaming ? 1 : 0);
    var from = _read[session] ?? 0;
    // Rewound, or read again.
    if (from > count) from = 0;
    _read[session] = count;
    return {
      for (var i = from; i < count; i++)
        if (feed.itemAt(i) case UserMessageItem(:final text))
          for (final match in stashReferencePattern.allMatches(text))
            int.parse(match[1]!),
    };
  }

  /// The pull requests [thread]'s agent linked to in what it said, or its
  /// tools printed (`gh pr create`'s), in the items done with since last
  /// read: their pages.
  List<String> _pulls(String session, AgentThread thread) {
    final feed = thread.session;
    // The one streaming may say more yet.
    final count = feed.itemCount - (feed.isStreaming ? 2 : 0);
    var from = _readDone[session] ?? 0;
    if (from > count) from = 0;
    if (count > from) _readDone[session] = count;
    return stashPullsIn([
      for (var i = from; i < count; i++) feed.itemAt(i),
    ], kindOf: forgeKindOf);
  }

  /// Puts [link] in [note]'s links (in place of the one to its session):
  /// a new one has it implementing. Whether that changed it.
  static bool _keep(StashNote note, StashThreadLink link) {
    final at = note.threads.indexWhere((l) => l.session == link.session);
    if (at < 0) {
      note.threads.add(link);
      if (note.status case StashStatus.collected || StashStatus.requirement) {
        note.status = StashStatus.implementing;
      }
      return true;
    }
    if (note.threads[at] == link) return false;
    note.threads[at] = link;
    return true;
  }
}

typedef _Seen = ({List<StashThreadLink> threads, List<StashIssueLink> pulls});
