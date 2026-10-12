import '../kernel/kernel_types.dart';

/// What the agent waits on the user for, as JSON for a paired phone, and
/// the phone's answer back.
abstract final class InteractionCodec {
  static Map<String, Object?> encode(InteractionRequest request) =>
      switch (request) {
        QuestionRequest(:final questions) => {
          't': 'question',
          'id': request.id,
          'title': request.title,
          'questions': [
            for (final question in questions)
              {
                'prompt': question.prompt,
                if (question.header.isNotEmpty) 'header': question.header,
                'options': [
                  for (final option in question.options)
                    {
                      'label': option.label,
                      if (option.description.isNotEmpty)
                        'description': option.description,
                    },
                ],
                if (question.allowMultiple) 'multiple': true,
                if (question.allowOther) 'other': question.otherLabel ?? '',
              },
          ],
        },
        ApprovalRequest() => {
          't': 'approval',
          'id': request.id,
          'title': request.title,
          'tool': request.toolName,
          'reason': ?request.reason,
          'always': ?request.alwaysAllowLabel,
          if (request.preview case final preview?)
            'preview': switch (preview) {
              CommandPreview(:final command, :final description) => {
                't': 'command',
                'command': command,
                'description': ?description,
              },
              DiffPreview(:final path, :final lines) => {
                't': 'diff',
                'path': path,
                'lines': [
                  for (final line in lines)
                    [line.type.index, line.lineNumber, line.text],
                ],
              },
              TextPreview(:final text) => {'t': 'text', 'text': text},
            },
        },
        PlanReviewRequest() => {
          't': 'plan',
          'id': request.id,
          'title': request.title,
          'plan': request.plan,
          'approve': request.approveLabel,
        },
      };

  /// The phone's answer; null when it does not say one.
  static InteractionAnswer? decodeAnswer(Object? json) => switch (json) {
    {'t': 'question', 'skipped': true} => const QuestionAnswer(
      [],
      skipped: true,
    ),
    {'t': 'question', 'picks': final List picks} => QuestionAnswer([
      for (final pick in picks) [if (pick is List) ...pick.whereType<String>()],
    ]),
    {'t': 'approval', 'decision': final String decision} =>
      switch (ApprovalDecision.values.asNameMap()[decision]) {
        final decision? => ApprovalAnswer(
          decision,
          message: json['message'] as String?,
        ),
        null => null,
      },
    {'t': 'plan', 'decision': final String decision} => switch (PlanDecision
        .values
        .asNameMap()[decision]) {
      final decision? => PlanAnswer(
        decision,
        feedback: json['feedback'] as String?,
      ),
      null => null,
    },
    _ => null,
  };
}
