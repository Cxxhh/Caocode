import 'package:flutter/widgets.dart';

import '../chat/chat_models.dart' show FileChange;
import '../chat/chat_session.dart';

/// Follows [session]'s agent and [open]s each file it changes, so the IDE's
/// editor shows what the agent did as it happens (as Cursor does).
///
/// Nothing is drawn: it is mounted wherever its session's chat is
/// (the IDE's chat), and reacts to the session alone.
///
/// The changes pending when it mounts are not opened — they were made
/// before the user came here (its chat a tab restored, the window opened) —
/// and neither is [enabled] false or one whose diff cannot be read (no
/// review of the project: [open] with no original shows the file).
class IdeAgentChanges extends StatefulWidget {
  const IdeAgentChanges({
    super.key,
    required this.session,
    required this.enabled,
    required this.open,
  });

  final ChatSession session;

  /// Whether changes are opened at all (the setting; see
  /// [IdeAgentChanges.enabledSetting]).
  final bool enabled;

  /// Opens [change]'s file, its text before the change read by the reader
  /// (null where it is not known).
  final void Function(FileChange change, Future<String> Function()? original)
  open;

  /// The setting that turns this on and off, in settings.json
  /// (`chat.autoOpenAgentChanges`); off unless it is set to true: each
  /// change would take the editor's tab from what is being looked at.
  static const enabledSetting = 'chat.autoOpenAgentChanges';

  /// Whether the setting's value turns it on.
  static bool enabledBy(Object? value) => value == true;

  @override
  State<IdeAgentChanges> createState() => _IdeAgentChangesState();
}

class _IdeAgentChangesState extends State<IdeAgentChanges> {
  /// The paths whose changes were seen (opened, or pending as it mounted).
  final Set<String> _seen = {};

  @override
  void initState() {
    super.initState();
    // What is pending now was made before this showed: not opened (the
    // chat's tab restored, the window opened on changes already there).
    _seen.addAll([for (final change in widget.session.fileChanges) change.path]);
    widget.session.addListener(_changed);
  }

  @override
  void didUpdateWidget(IdeAgentChanges old) {
    super.didUpdateWidget(old);
    if (identical(old.session, widget.session)) return;
    old.session.removeListener(_changed);
    _seen
      ..clear()
      ..addAll([for (final change in widget.session.fileChanges) change.path]);
    widget.session.addListener(_changed);
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final changes = widget.session.fileChanges;
    // A change no longer pending (kept, undone) may open again the next
    // time the agent edits that file.
    final pending = {for (final change in changes) change.path};
    _seen.removeWhere((path) => !pending.contains(path));
    if (!widget.enabled) {
      _seen.addAll(pending);
      return;
    }
    for (final change in changes) {
      // add: opened once; a change made again after being kept opens anew.
      if (_seen.add(change.path)) {
        widget.open(change, widget.session.originalOf(change));
      }
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
