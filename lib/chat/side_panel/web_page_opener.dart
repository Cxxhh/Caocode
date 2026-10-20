import 'package:path/path.dart' as p;

import '../../ide/file_views.dart';
import '../../l10n/l10n.dart';
import '../../workspace/editor_launcher.dart';

/// A web page on this machine: a chat's link to it opens in the browser,
/// where it shows as it is meant to.
final webPageOpener = FileOpener(
  id: 'webPage',
  matches: (path) =>
      const {'.html', '.htm'}.contains(p.extension(path).toLowerCase()),
  label: (context) => context.l10n.fileLinkOpenInBrowser,
  open: openExternal,
);
