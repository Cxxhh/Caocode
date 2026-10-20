import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../l10n/l10n.dart';
import '../../stash/stash_controller.dart';
import '../../stash/stash_settings.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import '../../workspace/window_controls.dart';
import '../user_settings.dart';
import 'settings_widgets.dart';
import 'stash_hotkey_field.dart';

/// Settings → Stash (docs/stash.md; see [StashSettings] for the keys):
/// the shortcut that shows its panel from any app, and where the stashes
/// are kept.
class StashSettingsPage extends StatefulWidget {
  const StashSettingsPage({super.key, this.settings});

  /// settings.json; none under test, where choices are not kept.
  final UserSettings? settings;

  @override
  State<StashSettingsPage> createState() => _StashSettingsPageState();
}

class _StashSettingsPageState extends State<StashSettingsPage> {
  void _write(String key, Object? value) {
    final settings = widget.settings;
    if (settings == null) return;
    unawaited(
      settings.update(key, value).catchError((Object error) {
        debugPrint('$key not kept: $error');
      }),
    );
  }

  Future<void> _pickDirectory() async {
    final path = await WindowControls.pickDirectory();
    if (path != null) _write(StashSettings.directoryKey, path);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([?settings, ?StashController.current]),
      builder: (context, _) =>
          _page(context, StashSettings.parse(settings?.values ?? const {})),
    );
  }

  Widget _page(BuildContext context, StashSettings current) {
    final l10n = context.l10n;
    final controller = StashController.current;
    final root = controller?.store.root;
    return SettingsPage(
      title: l10n.settingsSectionStash,
      description: l10n.stashSettingsDescription,
      children: [
        StashHotkeyCard(settings: widget.settings),
        SettingsCard(
          children: [
            SettingsRow(
              label: l10n.stashSettingsDirectory,
              description: [
                current.directory ?? root ?? '~/Caocode/Stash',
                if (current.directory != null && current.directory != root)
                  l10n.stashSettingsDirectoryRestart,
              ].join('\n'),
              trailing: SettingsButtons(
                children: [
                  if (root != null)
                    IdeButton(
                      label: l10n.revealInFileManager,
                      secondary: true,
                      onPressed: () => unawaited(openExternal(root)),
                    ),
                  if (WindowControls.canPickDirectory)
                    IdeButton(
                      label: l10n.stashSettingsDirectoryChange,
                      secondary: true,
                      onPressed: () => unawaited(_pickDirectory()),
                    ),
                  if (current.directory != null)
                    IdeButton(
                      label: l10n.stashSettingsDirectoryReset,
                      secondary: true,
                      onPressed: () => _write(StashSettings.directoryKey, null),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
