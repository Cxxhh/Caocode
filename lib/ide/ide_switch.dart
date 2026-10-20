import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/workbench_theme.dart' show themeColors;

/// A setting that is on or off: a switch, in the theme's button colors when
/// on. The one switch the app draws, wherever it appears: the settings'
/// rows, a menu's toggles, the MCP servers' panel.
class IdeSwitch extends StatelessWidget {
  const IdeSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.enabled = true,
    this.height = defaultHeight,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String semanticLabel;
  final bool enabled;

  /// How tall it stands: the row's label's height, as the settings' rows
  /// take it (see SettingsText.label), a menu's less.
  final double height;

  /// Beside a 13pt label, as the settings' rows have them.
  static const defaultHeight = 16.0;

  /// What a switch off puts its knob in: `SettingsColors.textSecondary`'s
  /// color, which the settings' rows read (this draws it, that names it).
  static Color get _knobOff {
    final foreground = themeColors['editor.foreground'];
    final strength = themeColors.highContrast ? 0.84 : 0.74;
    return foreground.withValues(alpha: foreground.a * strength);
  }

  @override
  Widget build(BuildContext context) {
    final colors = themeColors;
    // On: `button.background` under a `button.foreground` knob. Off: a faint
    // track under a knob in the descriptions' color.
    final track = value
        ? colors['button.background']
        : AppColors.textFaint.withValues(alpha: 0.45);
    final knob = value ? colors['button.foreground'] : _knobOff;
    final knobSize = height - 4;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: enabled ? () => onChanged(!value) : null,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          onTap: enabled ? () => onChanged(!value) : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              width: (height * 1.75).roundToDouble(),
              height: height,
              padding: const EdgeInsets.all(2),
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(
                color: track,
                borderRadius: BorderRadius.circular(height / 2),
              ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                width: knobSize,
                height: knobSize,
                decoration: BoxDecoration(
                  color: knob,
                  shape: BoxShape.circle,
                  boxShadow: const [
                    BoxShadow(color: Color(0x33000000), blurRadius: 2),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
