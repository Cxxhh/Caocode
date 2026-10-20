import '../chat/chat_models.dart' show ImageAttachment;
import 'claude_code/claude_haiku.dart';
import 'codex/ask_codex.dart';
import 'kernel_registry.dart';

/// Small application requests follow the active application kernel. Claude's
/// adapter remains available to its callers and regression tests.
Future<String> askAuxiliary(
  String system,
  String prompt, {
  Future<void>? cancel,
  String? model,
  bool exact = false,
  String? location,
  List<({String name, ImageAttachment image})> images = const [],
  ClaudeHaikuTools? tools,
}) async {
  if (KernelRegistry.all.firstOrNull?.id != 'codex') {
    return askClaudeHaiku(
      system,
      prompt,
      cancel: cancel,
      model: model,
      exact: exact,
      location: location,
      images: images,
      tools: tools,
    );
  }
  try {
    return await askCodex(
      system,
      prompt,
      cancel: cancel,
      location: location ?? tools?.directory ?? tools?.readable.firstOrNull,
      images: images,
      readable: tools?.readable ?? const [],
    );
  } on CodexCancelled {
    throw const ClaudeHaikuCancelled();
  }
}
