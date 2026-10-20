import 'dart:typed_data';

/// A file's content as the store keeps it: its mode (`100644`, `100755`,
/// `120000` for a symbolic link) and the hash of its bytes.
class ReviewBlob {
  const ReviewBlob(this.mode, this.oid);

  final String mode;
  final String oid;

  bool get isLink => mode == '120000';

  /// The same text (or link): an executable bit alone does not count.
  bool sameContent(ReviewBlob? other) =>
      other != null && other.oid == oid && other.isLink == isLink;

  List<String> toJson() => [mode, oid];

  static ReviewBlob? fromJson(Object? json) => switch (json) {
    [final String mode, final String oid] => ReviewBlob(mode, oid),
    _ => null,
  };

  @override
  bool operator ==(Object other) =>
      other is ReviewBlob && other.mode == mode && other.oid == oid;

  @override
  int get hashCode => Object.hash(mode, oid);

  @override
  String toString() => 'ReviewBlob($mode $oid)';
}

/// Why a project's changes cannot be reviewed.
class ReviewUnavailable implements Exception {
  const ReviewUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What a conversation keeps to review its agent's edits: the files as
/// they were before it edited them, and as it left them, each session in
/// a folder of its own (in the data folder's `checkpoints/`, never in the
/// project), gone with [forget]. Paths are relative to [root], with `/`.
abstract interface class ReviewStore {
  /// The project's directory.
  String get root;

  /// Whether anything is at [path].
  Future<bool> exists(String path);

  /// What is at [path] now; null when nothing (or a folder) is. Not kept:
  /// to tell whether it changed.
  Future<ReviewBlob?> current(String path);

  /// What is at [path] now, kept for [session]; null when nothing (or a
  /// folder) is.
  Future<ReviewBlob?> take(String session, String path);

  /// Keeps [bytes] for [session] as a blob of [mode].
  Future<ReviewBlob> store(
    String session,
    Uint8List bytes, {
    required String mode,
  });

  /// What [session] kept as [blob].
  Future<Uint8List> read(String session, ReviewBlob blob);

  /// Puts [blob] (of [session]) at [path]; null deletes the file (and the
  /// folders it leaves empty).
  Future<void> restore(String session, String path, ReviewBlob? blob);

  /// The file at [path] with the change from [from] to [to] (of
  /// [session]) carried over to it, merged as Git merges; null where they
  /// conflict or cannot be merged (a binary file, no Git).
  Future<Uint8List?> merge(
    String session,
    String path,
    ReviewBlob from,
    ReviewBlob to,
  );

  Future<void> write(String path, Uint8List bytes);

  /// Lines added and removed per path from its blob in [bases] (of
  /// [session]; null where there was no file) to what is there now; null
  /// for a binary file.
  Future<Map<String, ({int added, int removed})?>> lineCounts(
    String session,
    Map<String, ReviewBlob?> bases,
  );

  /// What [save] kept for [session]; null when nothing.
  Future<String?> load(String session);

  /// Keeps [data] for [session], and with it [blobs]: the others it kept
  /// go.
  Future<void> save(
    String session,
    String data, {
    required Iterable<ReviewBlob> blobs,
  });

  /// Drops all [session] kept.
  Future<void> forget(String session);
}
