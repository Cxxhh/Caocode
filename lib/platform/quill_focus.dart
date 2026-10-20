import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// Called by a focus listener registered before Quill's own. A dirty
/// editor's focus listener requests the keyboard even on focus loss:
/// two dirty editors can then steal focus back and forth in microtasks,
/// never letting the frame that clears their dirty flags run.
void releaseQuillFocus(GlobalKey<EditorState> editorKey) {
  final state = editorKey.currentState;
  if (state is! QuillRawEditorState ||
      !state.dirty ||
      state.widget.config.readOnly ||
      state.widget.config.focusNode.hasFocus) {
    return;
  }
  // Quill's listener consumes this in its immediate requestKeyboard call.
  state.controller.skipRequestKeyboard = true;
}
