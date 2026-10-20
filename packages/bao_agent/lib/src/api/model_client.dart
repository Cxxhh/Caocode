import '../util/cancel.dart';

/// One request to the Messages API: its body, and the beta features it
/// needs (`anthropic-beta`).
class ModelRequest {
  const ModelRequest(this.body, {this.betas = const []});

  final Map<String, Object?> body;
  final List<String> betas;

  String get model => body['model'] as String? ?? '';

  ModelRequest copyWith({Map<String, Object?>? body, List<String>? betas}) =>
      ModelRequest(body ?? this.body, betas: betas ?? this.betas);
}

/// A request is about to be sent again after it failed.
class RetryInfo {
  const RetryInfo({
    required this.attempt,
    required this.maxRetries,
    required this.delay,
    this.status,
    this.message,
  });

  final int attempt;
  final int maxRetries;
  final Duration delay;
  final int? status;
  final String? message;
}

/// A request the API refused, or that could not reach it.
class ApiError implements Exception {
  const ApiError(
    this.message, {
    this.status,
    this.type,
    this.retryable = false,
    this.retryAfter,
    this.requestId,
  });

  final String message;
  final int? status;

  /// The API's own name for it: `overloaded_error`,
  /// `invalid_request_error`, …
  final String? type;
  final bool retryable;
  final Duration? retryAfter;
  final String? requestId;

  /// Whether the request is too long for the model's context.
  bool get promptTooLong =>
      status == 400 &&
      (message.contains('prompt is too long') ||
          message.contains('too many tokens') ||
          message.contains('context length') ||
          message.contains('context window'));

  /// Whether the key is missing, wrong or not allowed.
  bool get authentication =>
      status == 401 ||
      status == 403 ||
      type == 'authentication_error' ||
      type == 'permission_error';

  @override
  String toString() =>
      ['API Error', if (status != null) ' $status', ': $message'].join();
}

/// Where requests to the model go: the API, or a stand-in under test.
abstract interface class ModelClient {
  /// The events of [request]'s streamed answer, as the API sends them
  /// (`message_start`, `content_block_delta`, …). A request retried after
  /// it had begun to answer sends `{"type": "stream_restart"}` first: what
  /// came before it is void.
  Stream<Map<String, Object?>> stream(
    ModelRequest request, {
    CancelToken? cancel,
    void Function(RetryInfo info)? onRetry,
  });

  /// Whether this is Anthropic's own API (beta features are only asked of
  /// it).
  bool get firstParty;

  /// The models the API offers and what each can do (`GET /v1/models`);
  /// null when it cannot say.
  Future<List<Map<String, Object?>>?> models();
}
