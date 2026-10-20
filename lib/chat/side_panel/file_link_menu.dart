import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../../ide/file_views.dart';
import '../../ide/ide_menu.dart';
import '../../l10n/l10n.dart';
import '../../workspace/editor_launcher.dart';
import '../../workspace/window_controls.dart';

/// What a right click on something the chat shows offers in place of the
/// selection's menu: a file it names ([FileLinkMenu]), an image.
abstract interface class ChatItemMenu {
  Future<void> show(BuildContext context, Offset position);
}

/// What a right click on a file the chat names offers, as an editor tab's
/// menu does: open it (in the side panel, in the IDE), copy its path, and on this machine show it in the
/// file manager or open it in its app. An image also shows enlarged
/// ([onPreview]) and copies ([onCopyImage]); one opened outside the app
/// opens there ([opener]: a web page, in the browser).
@immutable
class FileLinkMenu implements ChatItemMenu {
  const FileLinkMenu({
    required this.path,
    required this.root,
    required this.onOpen,
    this.paths,
    this.local = true,
    this.inPanel = false,
    this.onOpenInIde,
    this.onPreview,
    this.onCopyImage,
    this.opener,
  });

  final VoidCallback? onPreview;
  final VoidCallback? onCopyImage;

  /// What opens it outside the app (a web page on this machine, the
  /// browser), its item first.
  final FileOpener? opener;

  /// The file's absolute path, as its host spells it ([paths]).
  final String path;

  /// The project's folder, which the relative path is from.
  final String root;

  /// Opens it where the chat's files open; none where it does not open
  /// there.
  final VoidCallback? onOpen;

  /// Whether [onOpen] opens it in the side panel.
  final bool inPanel;

  /// Opens it in the IDE, where [onOpen] does not.
  final VoidCallback? onOpenInIde;
  final p.Context? paths;

  /// Whether the file is this machine's (not a remote project's).
  final bool local;

  @override
  Future<void> show(BuildContext context, Offset position) {
    final l10n = context.l10n;
    final paths = this.paths ?? p.context;
    return showIdeMenu(
      context,
      position: position,
      entries: ideMenuGroups([
        [
          if (onPreview case final preview?)
            IdeMenuAction(l10n.fileLinkPreview, onSelected: preview),
          if (opener case final opener? when local)
            IdeMenuAction(
              opener.label(context),
              onSelected: () => unawaited(opener.open(path)),
            ),
          if (onOpen case final open?)
            IdeMenuAction(
              inPanel ? l10n.fileLinkOpenInPanel : l10n.fileLinkOpen,
              onSelected: open,
            ),
          if (onOpenInIde case final open?)
            IdeMenuAction(l10n.sidePanelOpenInIde, onSelected: open),
        ],
        [
          if (onCopyImage case final copy?)
            IdeMenuAction(l10n.imageCopy, onSelected: copy),
          IdeMenuAction(
            l10n.tabCopyPath,
            onSelected: () => Clipboard.setData(ClipboardData(text: path)),
          ),
          IdeMenuAction(
            l10n.tabCopyRelativePath,
            onSelected: () => Clipboard.setData(
              ClipboardData(
                text: paths.isWithin(root, path)
                    ? paths.relative(path, from: root)
                    : path,
              ),
            ),
          ),
        ],
        if (local)
          [
            if (WindowControls.canRevealInFileManager)
              IdeMenuAction(
                l10n.revealInFileManager,
                onSelected: () =>
                    unawaited(WindowControls.revealInFileManager(path)),
              ),
            if (WindowControls.canOpenInDefaultApp)
              IdeMenuAction(
                l10n.openInDefaultApp,
                onSelected: () => unawaited(openExternal(path)),
              ),
          ],
      ]),
    );
  }
}

/// A tap on a file's link, which has a [menu] for a right click (found by
/// [fileLinkMenuAt]).
class FileLinkRecognizer extends TapGestureRecognizer {
  FileLinkRecognizer(this.menu);

  final FileLinkMenu menu;
}

/// [child], whose right click offers [menu] (see [fileLinkMenuAt]).
class FileLinkMenuRegion extends StatelessWidget {
  const FileLinkMenuRegion({
    super.key,
    required this.menu,
    required this.child,
  });

  final ChatItemMenu? menu;
  final Widget child;

  @override
  Widget build(BuildContext context) => menu == null
      ? child
      : MetaData(
          metaData: menu,
          behavior: HitTestBehavior.opaque,
          child: child,
        );
}

/// The menu of the file link at [position] (global) in [context]'s view:
/// a link's text, its icon, a step naming a file, or an image; null where
/// there is none. For a selection's right click, which takes it over its
/// own.
ChatItemMenu? fileLinkMenuAt(BuildContext context, Offset position) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(
    result,
    position,
    View.of(context).viewId,
  );
  for (final entry in result.path) {
    switch (entry.target) {
      case TextSpan(recognizer: FileLinkRecognizer(:final menu)):
        return menu;
      case RenderMetaData(metaData: final ChatItemMenu menu):
        return menu;
    }
  }
  return null;
}
