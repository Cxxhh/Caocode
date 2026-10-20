import 'dart:async';

import 'package:flutter/foundation.dart';

/// The calls of `generate_image` waiting on the user to pick the image
/// model (no default picked, none named), by their tool use's id: their
/// steps ask (see image_steps.dart). And the model each was made with, once
/// picked, for the step to offer it as the default.
///
/// A step asks from the moment it shows, before its call has come to the
/// app's tools (the agent's message streams in first): what is answered
/// meanwhile is kept, for the call to take as it comes.
class ImagePicks extends ChangeNotifier {
  static final instance = ImagePicks();

  final Map<String, Completer<String?>> _waiting = {};
  final Map<String, String> _picked = {};
  final Set<String> _declined = {};

  /// Whether call [id] waits on the user.
  bool waiting(String? id) => id != null && _waiting.containsKey(id);

  /// Whether call [id] was answered: picked, or declined.
  bool answered(String? id) =>
      id != null && (_picked.containsKey(id) || _declined.contains(id));

  /// The model (a model ref) call [id] was made with, as picked.
  String? picked(String? id) => id == null ? null : _picked[id];

  /// Waits for the user to pick call [id]'s model: its ref, or null when
  /// they declined, or the call was given up ([cancelled]). At once when
  /// they already answered.
  Future<String?> ask(String id, {Future<void>? cancelled}) {
    if (_picked[id] case final model?) return Future.value(model);
    if (_declined.contains(id)) return Future.value();
    final waiting = _waiting[id] ??= Completer<String?>();
    unawaited(cancelled?.then((_) => _finish(id, null)));
    notifyListeners();
    return waiting.future;
  }

  /// Makes call [id] with [model] (a model ref), now or as it comes.
  void pick(String id, String model) {
    _picked[id] = model;
    if (!_finish(id, model)) notifyListeners();
  }

  /// Gives call [id] up: the user would not make it.
  void decline(String id) {
    _declined.add(id);
    if (!_finish(id, null)) notifyListeners();
  }

  /// Answers call [id]'s wait, if it waits.
  bool _finish(String id, String? model) {
    final waiting = _waiting.remove(id);
    if (waiting == null) return false;
    waiting.complete(model);
    notifyListeners();
    return true;
  }
}
