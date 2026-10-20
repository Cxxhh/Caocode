import 'package:flutter/foundation.dart';

/// The languages picked for files (Change Language Mode), over what their
/// names and first lines select: by path, for the app's editors alike
/// ([MonacoLanguageAssets.registrationForPath] and
/// `TextMateSyntax.languageIdForPath` ask it first). The app keeps them
/// across runs ([toJson], [load]); editors showing a path follow its
/// changes.
class EditorLanguageOverrides extends ChangeNotifier {
  EditorLanguageOverrides();

  /// The app's.
  static final EditorLanguageOverrides instance = EditorLanguageOverrides();

  /// The language of no language: plain text, whatever the path says.
  static const plainText = 'plaintext';

  final Map<String, String> _byPath = {};

  /// The language picked for [path]; null to go by its name.
  String? of(String path) => _byPath[path];

  /// Picks [languageId] for [path]; null goes by its name again.
  void set(String path, String? languageId) {
    final before = _byPath[path];
    if (languageId == null) {
      _byPath.remove(path);
    } else {
      _byPath[path] = languageId;
    }
    if (before != languageId) notifyListeners();
  }

  /// The picks as kept: path to language id.
  Map<String, String> toJson() => Map.of(_byPath);

  /// The picks [json] kept ([toJson]), in place of those it had.
  void load(Object? json) {
    final picks = <String, String>{
      if (json is Map)
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is String && value.isNotEmpty) key: value,
    };
    if (mapEquals(picks, _byPath)) return;
    _byPath
      ..clear()
      ..addAll(picks);
    notifyListeners();
  }
}
