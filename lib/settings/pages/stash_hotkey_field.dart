import 'dart:async';

import 'package:bao_editor/monaco/flutter/keybinding_entry.dart'
    show KeybindingPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_quick_input.dart' show IdeKeycap;
import '../../keybindings/key_chord.dart';
import '../../l10n/l10n.dart';
import '../../platform/app_platform.dart';
import '../../stash/stash_controller.dart';
import '../../stash/stash_settings.dart';
import '../../theme/app_theme.dart';
import '../user_settings.dart';
import 'settings_widgets.dart';

/// The stash's shortcut, recorded rather than typed: its keys as caps.
/// Clicked, the next keys pressed take its place (with a modifier, a key
/// the system can take from any app); Escape keeps it, Backspace leaves
/// none. While it records, the shortcut is let go, so that pressing it
/// reaches the field, not the panel.
class StashHotkeyField extends StatefulWidget {
  const StashHotkeyField({
    super.key,
    required this.hotkey,
    required this.onChanged,
    this.semanticLabel,
  });

  /// As settings.json keeps it (`ctrl+shift+space`); empty for none.
  final String hotkey;

  /// The keys recorded, as [hotkey] is written; empty for none.
  final ValueChanged<String> onChanged;
  final String? semanticLabel;

  /// [chord] as the shortcut's setting, when the system can take it as
  /// one from any app (macOS's and Windows' hot keys): a modifier and a
  /// letter, digit, mark, function, arrow or Space, Enter or Tab.
  static String? specOf(KeyChord chord, KeybindingPlatform platform) {
    if (!chord.hasModifier) return null;
    final spec = chord.userSettingsLabel(platform);
    final key = spec.substring(spec.lastIndexOf('+', spec.length - 2) + 1);
    return _keys.hasMatch(key) ? spec : null;
  }

  static final _keys = RegExp(
    r"^([a-z0-9]|f([1-9]|1[0-2])|space|enter|tab|left|right|up|down|[-=\[\];'\\,./`])$",
  );

  @override
  State<StashHotkeyField> createState() => _StashHotkeyFieldState();
}

class _StashHotkeyFieldState extends State<StashHotkeyField> {
  final _focus = FocusNode(debugLabel: 'Stash shortcut');
  bool _recording = false;

  /// A key pressed that cannot be the shortcut: said until the next.
  bool _refused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    if (_recording) unawaited(StashController.current?.resumeHotkey());
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _stop();
  }

  void _start() {
    if (_recording) return;
    setState(() {
      _recording = true;
      _refused = false;
    });
    unawaited(StashController.current?.pauseHotkey());
    _focus.requestFocus();
  }

  void _stop() {
    if (!_recording) return;
    setState(() => _recording = false);
    unawaited(StashController.current?.resumeHotkey());
    if (_focus.hasFocus) _focus.unfocus();
  }

  void _take(String spec) {
    _stop();
    if (spec != widget.hotkey) widget.onChanged(spec);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!_recording) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final chord = KeyChord.fromEvent(event);
    // A modifier alone: the rest is still to come.
    if (chord == null) return KeyEventResult.handled;
    if (!chord.hasModifier) {
      if (chord.key == LogicalKeyboardKey.escape) {
        _stop();
        return KeyEventResult.handled;
      }
      if (chord.key == LogicalKeyboardKey.backspace ||
          chord.key == LogicalKeyboardKey.delete) {
        _take('');
        return KeyEventResult.handled;
      }
    }
    final spec = StashHotkeyField.specOf(chord, KeybindingPlatform.current);
    if (spec == null) {
      setState(() => _refused = true);
    } else {
      _take(spec);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = StashSettings.label(widget.hotkey, mac: AppPlatform.isMacOS);
    final Widget shown;
    if (_recording) {
      shown = Text(
        _refused ? l10n.stashHotkeyRefused : l10n.stashHotkeyPress,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: _refused ? AppColors.caution : AppColors.textMuted,
          fontSize: 12,
        ),
      );
    } else if (label.isEmpty) {
      shown = Text(
        l10n.stashHotkeyNone,
        style: TextStyle(color: AppColors.textFaint, fontSize: 12),
      );
    } else {
      shown = IdeKeycap(label);
    }
    return Semantics(
      button: true,
      label: widget.semanticLabel ?? l10n.stashSettingsHotkey,
      value: label,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _key,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _recording ? _stop : _start,
            child: Container(
              width: 180,
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: _recording ? AppColors.accent : AppColors.borderStrong,
                ),
              ),
              child: shown,
            ),
          ),
        ),
      ),
    );
  }
}

/// The stash's shortcut as a settings card: what it does, whether the
/// system gave it, and [StashHotkeyField] to change it, with Clear and
/// Default beside. On the Stash page and the Keyboard Shortcuts page,
/// where shortcuts are looked for.
class StashHotkeyCard extends StatelessWidget {
  const StashHotkeyCard({super.key, required this.settings, this.label});

  /// settings.json; none under test, where choices are not kept.
  final UserSettings? settings;

  /// The row's label; the Stash page's ("Shortcut") when null.
  final String? label;

  void _write(String spec) {
    final settings = this.settings;
    if (settings == null) return;
    unawaited(
      settings
          .update(
            StashSettings.hotkeyKey,
            spec.isEmpty ? null : spec,
          )
          .catchError((Object error) {
            debugPrint('${StashSettings.hotkeyKey} not kept: $error');
          }),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([?settings, ?StashController.current]),
    builder: (context, _) {
      final l10n = context.l10n;
      final hotkey = StashSettings.parse(settings?.values ?? const {}).hotkey;
      final label = StashSettings.label(hotkey, mac: AppPlatform.isMacOS);
      final taken = StashController.current?.hotkeyTaken;
      return SettingsCard(
        children: [
          SettingsRow(
            label: this.label ?? l10n.stashSettingsHotkey,
            description: [
              if (label.isEmpty)
                l10n.stashSettingsHotkeyNone
              else
                l10n.stashSettingsHotkeyCurrent(label),
              if (taken == false && label.isNotEmpty)
                l10n.stashSettingsHotkeyTaken,
              l10n.stashSettingsHotkeyHelp,
            ].join('\n'),
            trailing: SettingsButtons(
              children: [
                StashHotkeyField(
                  hotkey: hotkey,
                  onChanged: _write,
                  semanticLabel: this.label,
                ),
                if (hotkey.isNotEmpty)
                  IdeButton(
                    label: l10n.stashHotkeyClear,
                    secondary: true,
                    onPressed: () => _write(''),
                  ),
                if (hotkey.isEmpty)
                  IdeButton(
                    label: l10n.stashHotkeySuggested(
                      StashSettings.label(
                        StashSettings.suggestedHotkey,
                        mac: AppPlatform.isMacOS,
                      ),
                    ),
                    secondary: true,
                    onPressed: () => _write(StashSettings.suggestedHotkey),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}
