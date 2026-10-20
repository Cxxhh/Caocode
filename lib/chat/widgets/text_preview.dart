import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../base/smooth_scroll.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../side_panel/file_open.dart';
import 'code_citation.dart' show CodeBlockIconButton;

/// Shows [text] whole: what a tag or a row shows shortened (a long paste,
/// lines of a file, a stash). Where the chat's files open (the side panel,
/// the IDE), as a file there named [name] (else [title]; see
/// [FileOpenScope.showText]); else over the window, under [title].
Future<void> showTextPreview(
  BuildContext context, {
  required String title,
  required String text,
  String? name,
}) async {
  if (FileOpenScope.find(context)?.showText(text, name: name ?? title) ??
      false) {
    return;
  }
  return showTextDialog(context, title: title, text: text);
}

/// [text] whole, over the window, under [title]. Selectable, with its
/// lines numbered and a button to copy all of it; Esc, the close button or
/// a click beside it closes it.
Future<void> showTextDialog(
  BuildContext context, {
  required String title,
  required String text,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: context.l10n.commonDismiss,
  barrierColor: const Color(0x80000000),
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) => TextPreview(title: title, text: text),
);

class TextPreview extends StatefulWidget {
  const TextPreview({super.key, required this.title, required this.text});

  final String title;
  final String text;

  @override
  State<TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<TextPreview> {
  late final List<String> _lines = widget.text.split('\n');
  final _scroll = SmoothScrollController();
  bool _copied = false;
  Timer? _copiedTimer;

  /// Characters shown of a line: a paste may be one line of megabytes,
  /// which laid out whole would stall the window. Copying takes it all.
  static const _lineLength = 20000;

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _copy() {
    unawaited(Clipboard.setData(ClipboardData(text: widget.text)));
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final size = MediaQuery.sizeOf(context);
    final style = AppFonts.uiCodeStyle(12.5)
        .copyWith(color: AppColors.text, height: 1.5);
    final numbers = style.copyWith(color: AppColors.textFaint);
    final gutter = '${_lines.length}'.length * 8.0 + 16;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.min(880, size.width - 80),
          maxHeight: math.max(160, size.height * 0.8),
        ),
        child: Container(
          decoration: BoxDecoration(
            color: themeColors['editorWidget.background'],
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: themeColors['editorWidget.border']),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: Focus(
              autofocus: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        CodeBlockIconButton(
                          icon: _copied ? Codicons.check : Codicons.copy,
                          tooltip: l10n.commonCopy,
                          onTap: _copy,
                        ),
                        const SizedBox(width: 2),
                        CodeBlockIconButton(
                          icon: Codicons.close,
                          tooltip: l10n.commonClose,
                          onTap: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    height: 1,
                    color: themeColors['editorWidget.border'],
                  ),
                  Flexible(
                    child: SelectionArea(
                      child: Scrollbar(
                        controller: _scroll,
                        child: ListView.builder(
                          controller: _scroll,
                          // As tall as a few lines; more fill the room it
                          // has, built as they scroll into view.
                          shrinkWrap: _lines.length <= 60,
                          padding: const EdgeInsets.fromLTRB(0, 10, 16, 12),
                          itemCount: _lines.length,
                          itemBuilder: (context, i) {
                            final line = _lines[i];
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SelectionContainer.disabled(
                                  child: SizedBox(
                                    width: gutter,
                                    child: Text(
                                      '${i + 1}',
                                      textAlign: TextAlign.right,
                                      style: numbers,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    line.length > _lineLength
                                        ? '${line.substring(0, _lineLength)}…'
                                        : line,
                                    style: style,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
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
