import 'dart:async';

/// Thrown where work stops because it was cancelled.
class Cancelled implements Exception {
  const Cancelled([this.reason = 'cancelled']);

  final String reason;

  @override
  String toString() => 'Cancelled: $reason';
}

/// Says when work is to stop: a turn interrupted, a task stopped. A child
/// is cancelled with its parent, not the other way round.
class CancelToken {
  CancelToken([CancelToken? parent]) {
    parent?.whenCancelled.then((_) => cancel(parent.reason));
  }

  final Completer<void> _done = Completer<void>();
  String _reason = 'cancelled';

  bool get isCancelled => _done.isCompleted;

  String get reason => _reason;

  /// Completes once cancelled.
  Future<void> get whenCancelled => _done.future;

  void cancel([String reason = 'cancelled']) {
    if (_done.isCompleted) return;
    _reason = reason;
    _done.complete();
  }

  /// Throws [Cancelled] if cancelled.
  void check() {
    if (isCancelled) throw Cancelled(_reason);
  }

  /// [future], or [Cancelled] as soon as this is cancelled.
  Future<T> guard<T>(Future<T> future) {
    if (isCancelled) return Future.error(Cancelled(_reason));
    final result = Completer<T>();
    future.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    whenCancelled.then((_) {
      if (!result.isCompleted) result.completeError(Cancelled(_reason));
    });
    return result.future;
  }
}
