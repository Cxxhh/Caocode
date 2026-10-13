import 'package:caocode/l10n/app_localizations.dart';
import 'package:caocode/update/version.dart';
import 'package:caocode/workspace/window_header/about_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final language in ['zh', 'en']) {
    testWidgets(
      'About shows Caocode, Codex and the public version ($language)',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(language),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showAboutCaocode(context),
                  child: const Text('About'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('About'));
        await tester.pumpAndSettle();
        expect(find.text('Caocode'), findsOneWidget);
        expect(find.text(currentAppVersion.display), findsOneWidget);
        expect(find.textContaining('Codex CLI'), findsOneWidget);
        expect(find.textContaining('Claude Code'), findsNothing);
      },
    );
  }
}
