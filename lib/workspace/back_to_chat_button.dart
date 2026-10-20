import 'package:flutter/material.dart';

import '../ide/ide_button.dart';
import '../l10n/l10n.dart';
import '../theme/codicons.dart';
import 'editor_launcher.dart';

/// The title bar's way from the IDE layout back to the chat, filled in the
/// IDE's button color to stand out there, and 22px high as the header's
/// other buttons: in the IDE's own title bar (macOS), and in the header
/// Windows draws.
class BackToChatButton extends StatelessWidget {
  const BackToChatButton({super.key, required this.onPressed, this.label});

  final VoidCallback onPressed;

  /// Back to Chat, by default.
  final String? label;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    // Centered in its width, it would take the bar's height too.
    constraints: BoxConstraints(
      minWidth: titleBarSwitchWidth(context),
      minHeight: 22,
      maxHeight: 22,
    ),
    child: IdeButton(
      icon: Codicons.commentDiscussion,
      label: label ?? context.l10n.workspaceBackToChat,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      expand: true,
      onPressed: onPressed,
    ),
  );
}

/// The chat's Open in Fast Ide button's chevron, with the line before it:
/// the room it takes beside the label.
const openInEditorChevronWidth = 1.0 + 3 + 14 + 4;

/// The least width of Back to Chat and of the chat's Open in Fast Ide, the
/// one in the other's place as the layout switches: room for either, so
/// neither moves.
double titleBarSwitchWidth(BuildContext context) {
  final l10n = context.l10n;
  final style = DefaultTextStyle.of(context).style
      .merge(const TextStyle(fontSize: 12, height: 16 / 12));
  double text(String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  // A border each side, then the padding, a 16px icon and 4px after it.
  const frame = 2 + 8 + 16 + 4;
  final back = frame + text(l10n.workspaceBackToChat) + 8;
  final open =
      frame +
      text(Editor.fastIde.localizedPlatformLabel(l10n)) +
      6 +
      openInEditorChevronWidth;
  return (back > open ? back : open).ceilToDouble();
}
