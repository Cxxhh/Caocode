import 'dart:async';

import 'package:flutter/material.dart';

import 'package:bao_editor/monaco/flutter/diff_editor.dart';
import 'package:bao_editor/monaco/flutter/diff_editor_model.dart';
import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_surface.dart';
import 'package:bao_editor/monaco/flutter/editor_surface_controller.dart';
import 'package:bao_editor/monaco/flutter/language_configuration_assets.dart';
import 'package:bao_editor/textmate/textmate_syntax.dart';

import '../theme/app_theme.dart';
import '../theme/code_font.dart';
import '../theme/workbench_theme.dart' hide ColorScheme;
import 'ide_code_editor.dart' show IdeCodeHighlights;
import 'ide_original_diff.dart';
import 'ide_workspace.dart' show IdeDiffOriginal;

/// A change, [original] against [modified], read only in the IDE's diff
/// editor ([DiffEditor]), as a diff tab of the IDE shows one: side by side
/// where it is wide enough, else the deleted code in the text; both
/// highlighted as the language of [path]. Scrolled to [line] of [modified]
/// (from 1) once compared, else to the first change. Copied, the modified's
/// lines are told [onCopy] (from 1).
class IdeCodeDiff extends StatefulWidget {
  const IdeCodeDiff({
    super.key,
    required this.path,
    required this.original,
    required this.modified,
    this.line,
    this.highlights,
    this.onCopy,
  });

  final String path;
  final String original;
  final String modified;
  final int? line;

  /// Whose TextMate worker highlights it; its own when null.
  final IdeCodeHighlights? highlights;
  final void Function(String text, int start, int end)? onCopy;

  @override
  State<IdeCodeDiff> createState() => IdeCodeDiffState();
}

class IdeCodeDiffState extends State<IdeCodeDiff> {
  final WorkbenchThemeService _themes = WorkbenchThemeService.instance;
  final GlobalKey _modifiedKey = GlobalKey();
  late EditorSurfaceController _modified;
  late IdeDiffOriginal _original;
  late IdeOriginalDiff _diff;
  TextMateDocument? _highlight;
  TextMateSyntax? _ownTextMate;

  /// Bumped as the texts change: an older language pick is dropped.
  int _texts = 0;

  /// Scrolled to [IdeCodeDiff.line] or the first change, once compared.
  bool _revealed = false;

  TextMateSyntax get _textMate =>
      widget.highlights?.syntax ??
      (_ownTextMate ??= TextMateSyntax(themes: _themes));

  @override
  void initState() {
    super.initState();
    _themes.addListener(_changed);
    _open();
  }

  @override
  void didUpdateWidget(IdeCodeDiff oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.original != widget.original ||
        oldWidget.modified != widget.modified ||
        oldWidget.path != widget.path) {
      _close();
      _open();
    } else if (oldWidget.line != widget.line) {
      _revealed = false;
      _reveal();
    }
  }

  @override
  void dispose() {
    _texts++;
    _themes.removeListener(_changed);
    _close();
    _ownTextMate?.dispose();
    super.dispose();
  }

  void _open() {
    final texts = ++_texts;
    _revealed = false;
    _modified = EditorSurfaceController(
      document: EditorDocumentModel(widget.modified),
    )..onCopy = widget.onCopy;
    _original = IdeDiffOriginal(() async => widget.original)
      ..text.value = widget.original;
    _diff = IdeOriginalDiff(_original, _modified.document, onChanged: _changed);
    _diff.model.addListener(_compared);
    unawaited(_pickLanguage(texts));
  }

  void _close() {
    _highlight?.removeListener(_changed);
    _highlight?.dispose();
    _highlight = null;
    _diff.model.removeListener(_compared);
    _diff.dispose();
    _original.dispose();
    final document = _modified.document;
    _modified.dispose();
    document.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _compared() {
    _changed();
    _reveal();
  }

  Future<void> _pickLanguage(int texts) async {
    final path = widget.path;
    final text = widget.modified;
    final end = text.indexOf('\n');
    final firstLine = (end < 0 ? text : text.substring(0, end)).replaceFirst(
      '﻿',
      '',
    );
    try {
      final configuration = await languageConfigurationForPath(
        path,
        firstLine: firstLine,
      );
      if (!mounted || texts != _texts) return;
      if (configuration != null) {
        _modified.languageConfiguration = configuration;
      }
      final languageId = await _textMate.languageIdForPath(
        path,
        firstLine: firstLine,
      );
      if (!mounted || texts != _texts || languageId == null) return;
      _highlight = _textMate.open(languageId, _modified.document.snapshot)
        ?..addListener(_changed);
      _diff.highlight(_textMate, languageId);
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) => _viewChanged());
    } on Object {
      // Plain text, then.
    }
  }

  EditorSurfaceView? get _view => switch (_modifiedKey.currentState) {
    final EditorSurfaceView view => view,
    _ => null,
  };

  /// The lines on screen go to the TextMate worker first.
  void _viewChanged() {
    if (!mounted) return;
    if (_view?.visibleLineRange case final range?) {
      _highlight?.setViewport(range.first, range.last);
    }
  }

  /// A few lines over [IdeCodeDiff.line], else the first change, once the
  /// texts are compared and laid out.
  void _reveal() {
    final mappings = _diff.model.mappings;
    if (_revealed || mappings == null) return;
    _revealed = true;
    final snapshot = _modified.document.snapshot;
    final line =
        widget.line ??
        (mappings.isEmpty ? null : mappings.first.modified.startLineNumber);
    if (line == null) return;
    final at = (line - 1).clamp(0, snapshot.lineCount - 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final offset = snapshot.lineStarts[at];
      _view?.revealRange(offset, offset, center: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = _themes.colors;
    final theme = EditorViewTheme.fromColors(colors.get);
    final type = getThemeTypeSelector(_themes.colorTheme.type);
    final style = AppFonts.codeStyle(13)
        .copyWith(color: colors['editor.foreground'], height: 1.45);
    return CodeTextScale(
      child: DiffEditor(
        key: ObjectKey(_diff),
        model: _diff.model,
        style: style,
        theme: theme,
        colors: DiffEditorColors.from(colors.get),
        dark:
            type == ThemeTypeSelector.vsDark ||
            type == ThemeTypeSelector.hcBlack,
        originalStyledLines: _diff.textMate?.styledLines,
        border: colors.get('diffEditor.border'),
        sashHover: colors.get('sash.hoverBorder'),
        original: (context, side) {
          final controller = _diff.controller;
          if (controller == null) return const SizedBox.expand();
          return EditorSurface(
            key: ObjectKey(controller),
            controller: controller,
            readOnly: true,
            backgroundColor: colors['editor.background'],
            selectionColor: colors['editor.selectionBackground'],
            caretColor: colors['editorCursor.foreground'],
            theme: theme,
            styledLines: _diff.textMate?.styledLines,
            decorations: side.decorations,
            viewZones: side.zones,
            scrollPosition: side.scrollPosition,
            glyphMargin: side.sideBySide,
            folding: false,
            showMinimap: false,
            style: style,
          );
        },
        modified: (context, side) => EditorSurface(
          key: _modifiedKey,
          controller: _modified,
          readOnly: true,
          backgroundColor: colors['editor.background'],
          selectionColor: colors['editor.selectionBackground'],
          caretColor: colors['editorCursor.foreground'],
          theme: theme,
          styledLines: _highlight?.styledLines,
          decorations: side.decorations,
          viewZones: side.zones,
          scrollPosition: side.scrollPosition,
          folding: false,
          showMinimap: false,
          onViewChanged: _viewChanged,
          style: style,
        ),
      ),
    );
  }
}
