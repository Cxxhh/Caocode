import 'package:bao_editor/monaco/flutter/editor_document_model.dart';
import 'package:bao_editor/monaco/flutter/editor_surface_controller.dart';

import '../settings/jsonc.dart';

/// Formatting the IDE does itself, for the languages it knows well enough
/// to lay out without a language server (none installed, or none at all, as
/// beside the chat): JSON for now, as VS Code's own JSON formatter does.
abstract final class BuiltinFormatting {
  static const _json = {'json', 'jsonc'};

  /// Whether [languageId] is one it formats.
  static bool supports(String? languageId) => _json.contains(languageId);

  /// Formats [controller]'s text as [languageId], with its indentation, as
  /// one undo step keeping the cursors: with [selection], the lines
  /// selected (the caret's when none is). Whether the text changed.
  static bool format(
    EditorSurfaceController controller,
    String? languageId, {
    bool selection = false,
  }) {
    if (!supports(languageId)) return false;
    final snapshot = controller.document.snapshot;
    final text = snapshot.text;
    var start = 0;
    var end = text.length;
    if (selection) {
      final selected = controller.value.selection;
      if (selected.isCollapsed) {
        final line =
            snapshot.positionAtOffset(selected.extentOffset).lineNumber - 1;
        start = snapshot.lineStarts[line];
        end = snapshot.contentEnds[line];
      } else {
        start = selected.start;
        end = selected.end;
      }
    }
    final edits = formatJsonc(
      text,
      start: start,
      end: end,
      options: JsoncFormatting(
        insertSpaces: controller.insertSpaces,
        tabSize: controller.tabSize,
      ),
    );
    return controller.applyEdits([
      for (final edit in edits)
        EditorOffsetEdit(edit.offset, edit.offset + edit.length, edit.content),
    ]);
  }
}
