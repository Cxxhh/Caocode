import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../ide/ide_button.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../tips/star_prompt.dart' show StarPrompt;
import '../../update/version.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import '../../workspace/window_header/about_dialog.dart' show aboutIconAsset;
import 'settings_widgets.dart';

/// Settings → About: what Caocode is, which build this is, and where it
/// is made in the open: its repository (a star there helps others find
/// it), its site, its changelog, and where to tell of a problem.
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  static final website = Uri.parse('https://caocode.dev');
  static final issues = StarPrompt.repository.replace(
    path: '${StarPrompt.repository.path}/issues',
  );

  void _open(Uri url) => unawaited(openExternal('$url'));

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final changelog = website.replace(
      path: zh ? '/zh/changelog' : '/changelog',
    );
    final repository = StarPrompt.repository;
    return SettingsPage(
      title: l10n.settingsSectionAbout,
      lead: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Image.asset(
              aboutIconAsset,
              width: 44,
              height: 44,
              filterQuality: FilterQuality.medium,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        'Caocode',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l10n.aboutVersion(
                          currentAppVersion.display,
                          currentAppVersion.build,
                        ),
                        style: TextStyle(
                          color: AppColors.textFaint,
                          fontSize: 12,
                          fontFamily: AppFonts.mono,
                          fontFamilyFallback: AppFonts.monoFallbacks,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(l10n.aboutDescription, style: SettingsText.lead),
                  const SizedBox(height: 6),
                  Text(
                    l10n.starPromptDetail,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      children: [
        SettingsCard(
          children: [
            SettingsRow(
              label: 'GitHub',
              description: l10n.aboutRepository(
                '${repository.host}${repository.path}',
              ),
              trailing: IdeButton(
                label: l10n.starPromptStar,
                icon: Codicons.star,
                onPressed: () => _open(repository),
              ),
            ),
            SettingsRow(
              label: l10n.aboutWebsite,
              description: website.host,
              trailing: IdeButton(
                label: l10n.aboutOpen,
                secondary: true,
                onPressed: () => _open(website),
              ),
            ),
            SettingsRow(
              label: l10n.aboutChangelog,
              description: l10n.aboutChangelogDetail,
              trailing: IdeButton(
                label: l10n.aboutOpen,
                secondary: true,
                onPressed: () => _open(changelog),
              ),
            ),
            SettingsRow(
              label: l10n.aboutFeedback,
              description: l10n.aboutFeedbackDetail,
              trailing: IdeButton(
                label: l10n.aboutOpen,
                secondary: true,
                onPressed: () => _open(issues),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
