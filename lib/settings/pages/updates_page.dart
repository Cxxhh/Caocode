import 'dart:async';

import 'package:flutter/material.dart';

import '../../ide/ide_button.dart';
import '../../ide/ide_menu.dart';
import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../../update/codex_cli_update.dart';
import '../../update/update_controller.dart';
import '../../update/update_service.dart';
import '../../update/update_settings.dart';
import '../../update/version.dart';
import '../user_settings.dart';
import 'settings_dropdown.dart';
import 'settings_widgets.dart';

/// Settings → Updates: the version running, when it last looked for
/// another, what it found (Restart to Update), `update.mode`, and the new
/// version's notes (this one's, where it is the newest).
class UpdatesSettingsPage extends StatefulWidget {
  const UpdatesSettingsPage({
    super.key,
    this.updates,
    this.settings,
    this.codexUpdates,
  });

  /// None where the build does not update itself (a debug build).
  final UpdateController? updates;

  /// settings.json; none under test, where choices are not kept.
  final UserSettings? settings;

  /// Created once for this page and the project host from which it was opened.
  final CodexCliUpdateService? Function()? codexUpdates;

  static String modeName(BuildContext context, UpdateMode mode) {
    final l10n = context.l10n;
    return switch (mode) {
      UpdateMode.automatic => l10n.updateModeDefault,
      UpdateMode.manual => l10n.updateModeManual,
      UpdateMode.none => l10n.updateModeNone,
    };
  }

  @override
  State<UpdatesSettingsPage> createState() => _UpdatesSettingsPageState();
}

class _UpdatesSettingsPageState extends State<UpdatesSettingsPage> {
  /// Why Restart to Update did not: a [ManualUpdateRequired], or the
  /// error.
  Object? _problem;
  CodexCliUpdateService? _codex;

  @override
  void initState() {
    super.initState();
    _codex = widget.codexUpdates?.call();
    unawaited(_codex?.load());
  }

  @override
  void dispose() {
    _codex?.dispose();
    super.dispose();
  }

  UpdateService? get _service => widget.updates?.service;

  void _write(UpdateMode mode) {
    final settings = widget.settings;
    if (settings == null) return;
    unawaited(
      settings
          .update(
            UpdateMode.settingKey,
            mode == UpdateMode.defaultMode ? null : mode.value,
          )
          .catchError((Object error) {
            // A settings file that does not parse is left as it is; its
            // error is shown.
            debugPrint('${UpdateMode.settingKey} not kept: $error');
          }),
    );
  }

  Future<void> _check() async {
    setState(() => _problem = null);
    await _service?.check(manual: true);
  }

  Future<void> _restart() async {
    setState(() => _problem = null);
    final problem = await widget.updates?.restartToUpdate();
    if (mounted) setState(() => _problem = problem);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([?settings, ?_service, ?_codex]),
      builder: (context, _) => _page(
        context,
        _service?.mode ?? UpdateMode.parse(settings?[UpdateMode.settingKey]),
      ),
    );
  }

  Widget _page(BuildContext context, UpdateMode mode) {
    final l10n = context.l10n;
    final service = _service;
    final busy =
        service?.status == UpdateStatus.checking ||
        service?.status == UpdateStatus.downloading;
    final modeName = UpdatesSettingsPage.modeName(context, mode);
    // The new version's, or this one's where it is the newest.
    final noted = service?.release?.manifest ?? service?.installed;
    final notes = noted?.notesFor(l10n.localeName);
    return SettingsPage(
      title: l10n.updatesSettingsTitle,
      description: l10n.updatesSettingsDescription,
      children: [
        SettingsCard(
          children: [
            SettingsRow(
              label: l10n.updateCurrentVersion,
              description: [
                (service?.current ?? currentAppVersion).display,
                switch (service?.lastChecked) {
                  final time? => l10n.updateLastChecked(_format(context, time)),
                  null when service != null => l10n.updateNeverChecked,
                  null => l10n.updateUnsupported,
                },
              ].join(' · '),
              trailing: IdeButton(
                label: l10n.updateCheckNow,
                icon: Codicons.refresh,
                secondary: true,
                onPressed: service == null || busy || mode == UpdateMode.none
                    ? null
                    : () => unawaited(_check()),
              ),
            ),
            ?(service == null ? null : _status(context, service)),
          ],
        ),
        SettingsCard(
          children: [
            SettingsRow(
              label: l10n.updateMode,
              description: l10n.updateModeDescription,
              trailing: SettingsDropdown(
                current: modeName,
                semanticLabel: l10n.updateModeLabel(modeName),
                entries: () => [
                  for (final choice in UpdateMode.values)
                    IdeMenuAction(
                      UpdatesSettingsPage.modeName(context, choice),
                      checked: choice == mode,
                      onSelected: () => _write(choice),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (_codex case final cli?) _codexCard(context, cli),
        if (notes != null)
          SettingsGroup(
            title: l10n.updateReleaseNotesFor(noted!.version.display),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                child: SelectableText(notes, style: SettingsText.description),
              ),
            ],
          ),
      ],
    );
  }

  Widget _codexCard(BuildContext context, CodexCliUpdateService cli) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String text(String chinese, String english) => zh ? chinese : english;
    final installed = cli.installation;
    final version = cli.latest?.marketing;
    final status = switch (cli.status) {
      CodexCliUpdateStatus.idle => text(
        '点击检查更新以获取最新版本。',
        'Check for the latest version.',
      ),
      CodexCliUpdateStatus.loading => text(
        '正在读取 CLI 版本…',
        'Reading CLI version…',
      ),
      CodexCliUpdateStatus.checking => text('正在检查更新…', 'Checking for updates…'),
      CodexCliUpdateStatus.available => text(
        '发现新版本 $version',
        'Version $version is available',
      ),
      CodexCliUpdateStatus.upToDate => text(
        '当前已是最新版本。',
        'Codex CLI is up to date.',
      ),
      CodexCliUpdateStatus.updating => text(
        '正在更新 Codex CLI…',
        'Updating Codex CLI…',
      ),
      CodexCliUpdateStatus.updated => text(
        '更新完成。新版本将在新会话中生效；已有会话请重启应用后继续。',
        'Updated. New sessions use the new version. Restart the app to continue existing sessions with it.',
      ),
      CodexCliUpdateStatus.failed => text(
        '操作失败：${cli.error}',
        'Operation failed: ${cli.error}',
      ),
    };
    return SettingsGroup(
      title: 'Codex CLI',
      children: [
        SettingsCard(
          children: [
            SettingsRow(
              label: text('当前版本', 'Current version'),
              description: installed == null
                  ? status
                  : '${installed.version.marketing} · ${installed.host}',
              below: [
                if (installed != null) ...[
                  SelectableText(installed.path, style: SettingsText.path),
                  Text(status, style: SettingsText.description),
                  if (!installed.canUpdate)
                    Text(
                      text(
                        '此安装不支持自动更新，请使用原安装方式升级。',
                        'Use the original installation method to update this CLI.',
                      ),
                      style: SettingsText.description,
                    ),
                ],
              ],
              trailing: Wrap(
                spacing: 6,
                runSpacing: 6,
                alignment: WrapAlignment.end,
                children: [
                  IdeButton(
                    key: const ValueKey('codex-cli-check'),
                    label: context.l10n.updateCheckNow,
                    icon: Codicons.refresh,
                    secondary: true,
                    onPressed: cli.busy ? null : () => unawaited(cli.check()),
                  ),
                  IdeButton(
                    key: const ValueKey('codex-cli-update'),
                    label: text('更新 Codex CLI', 'Update Codex CLI'),
                    onPressed: cli.canUpdate
                        ? () => unawaited(cli.update())
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// [time] as the app's language writes a date and time.
  static String _format(BuildContext context, DateTime time) {
    final material = MaterialLocalizations.of(context);
    return '${material.formatMediumDate(time)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(time))}';
  }

  /// What the last check found, with Restart to Update when it found a
  /// version; null before any.
  Widget? _status(BuildContext context, UpdateService service) {
    final l10n = context.l10n;
    final release = service.release;
    final version = release?.version.display ?? '';
    final label = switch (service.status) {
      UpdateStatus.idle => null,
      UpdateStatus.checking => l10n.updateChecking,
      UpdateStatus.upToDate => l10n.updateUpToDate,
      UpdateStatus.available => l10n.updateAvailable(version),
      UpdateStatus.downloading => switch (service.progress) {
        final progress? => l10n.updateDownloadingProgress(
          version,
          (progress * 100).floor(),
        ),
        null => l10n.updateDownloading(version),
      },
      UpdateStatus.ready => l10n.updateReady(version),
      UpdateStatus.failed when release == null => l10n.updateCheckFailed(
        '${service.error}',
      ),
      UpdateStatus.failed => l10n.updateFailed('${service.error}'),
    };
    if (label == null) return null;
    final problem = _problem;
    final details = [
      if (release != null && service.isMandatory(release))
        l10n.updateMandatory(version)
      else if (release != null &&
          service.skippedVersion == '${release.version}')
        l10n.updateSkippedNote,
      if (problem is ManualUpdateRequired)
        l10n.updateManual(problem.reason)
      else if (problem != null)
        l10n.updateFailed('$problem'),
    ];
    return SettingsRow(
      label: label,
      description: details.isEmpty ? null : details.join('\n'),
      trailing: release == null
          ? null
          : SettingsButtons(
              children: [
                if (problem is ManualUpdateRequired)
                  IdeButton(
                    label: l10n.updateOpenDownloadPage,
                    secondary: true,
                    onPressed: () => unawaited(
                      widget.updates!.openUrl(
                        ManualUpdateRequired.downloadPage,
                      ),
                    ),
                  ),
                IdeButton(
                  label: l10n.updateRestartNow,
                  onPressed: service.status == UpdateStatus.downloading
                      ? null
                      : () => unawaited(_restart()),
                ),
              ],
            ),
    );
  }
}
