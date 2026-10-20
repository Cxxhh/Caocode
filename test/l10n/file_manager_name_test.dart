import 'package:caocode/l10n/app_localizations_zh.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// The system's file manager is named as each system names it, wherever a
/// string names it (#174).
void main() {
  final zh = AppLocalizationsZh();

  testWidgets('macOS: Finder', (tester) async {
    expect(englishLocalizations.fileManager, 'Finder');
    expect(englishLocalizations.revealInFileManager, 'Reveal in Finder');
    expect(zh.fileManager, '访达');
    expect(zh.revealInFileManager, '在访达中显示');
    expect(zh.browserTraceReveal(zh.fileManager), startsWith('在访达中显示'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Windows: File Explorer', (tester) async {
    expect(englishLocalizations.fileManager, 'File Explorer');
    expect(englishLocalizations.revealInFileManager, 'Reveal in File Explorer');
    expect(zh.fileManager, '文件资源管理器');
    expect(zh.revealInFileManager, '在文件资源管理器中显示');
    expect(zh.browserTraceReveal(zh.fileManager), startsWith('在文件资源管理器中显示'));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('Linux: File Manager', (tester) async {
    expect(englishLocalizations.fileManager, 'File Manager');
    expect(zh.revealInFileManager, '在文件管理器中显示');
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
