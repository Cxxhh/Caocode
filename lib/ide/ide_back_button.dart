import 'package:flutter/material.dart';

import '../chat/widgets/hover_builder.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'ide_hover.dart';

/// The way back out of a page: "← Back" atop the settings' sidebar,
/// "← Models" over a provider's page. [IdeBackButton.compact] is a small
/// capsule, "← Conversation" over a subagent's conversation.
class IdeBackButton extends StatelessWidget {
  /// The arrow and [label], muted, on a row's hover.
  const IdeBackButton({
    super.key,
    required this.label,
    required this.onTap,
    this.expand = false,
  }) : text = null,
       hover = null,
       focusNode = null,
       _compact = false;

  /// The arrow and [text] in one small capsule, lit on hover or focus;
  /// [hover] (else [label]) shows hovered.
  const IdeBackButton.compact({
    super.key,
    required this.label,
    required this.text,
    required this.onTap,
    this.hover,
    this.focusNode,
  }) : expand = false,
       _compact = true;

  final String label;
  final VoidCallback onTap;

  /// As wide as it is let be (a sidebar's row), else as its words.
  final bool expand;

  /// What the compact one reads beside its arrow.
  final String? text;

  /// What the compact one says hovered: [label] with its key, say.
  final String? hover;
  final FocusNode? focusNode;

  final bool _compact;

  /// The arrow's size, as the sidebars' icons.
  static const _iconSize = 15.0;

  @override
  Widget build(BuildContext context) {
    if (_compact) return _Compact(this);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: hovered ? AppColors.hover : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
              children: [
                Icon(
                  Codicons.arrowLeft,
                  size: _iconSize,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 8),
                Flexible(
                  fit: expand ? FlexFit.tight : FlexFit.loose,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.textMuted, fontSize: 13),
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

class _Compact extends StatefulWidget {
  const _Compact(this.button);

  final IdeBackButton button;

  @override
  State<_Compact> createState() => _CompactState();
}

class _CompactState extends State<_Compact> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final button = widget.button;
    return IdeHover(
      message: button.hover ?? button.label,
      child: Semantics(
        button: true,
        label: button.label,
        excludeSemantics: true,
        child: FocusableActionDetector(
          focusNode: button.focusNode,
          mouseCursor: SystemMouseCursors.click,
          onShowHoverHighlight: (on) => setState(() => _hovered = on),
          onShowFocusHighlight: (on) => setState(() => _focused = on),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => button.onTap(),
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: button.onTap,
            child: Container(
              height: 26,
              // The arrow where it sat alone in a 26 wide square.
              padding: const EdgeInsets.only(left: 5.5, right: 8),
              decoration: BoxDecoration(
                color: _hovered || _focused ? AppColors.hover : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Codicons.arrowLeft,
                    size: IdeBackButton._iconSize,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      button.text!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _hovered || _focused
                            ? AppColors.text
                            : AppColors.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
