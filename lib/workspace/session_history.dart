/// One environment's metadata sync; conversations themselves remain lazy.
class SessionHistoryState {
  int pending = 0;
  int received = 0;
  DateTime? updatedAt;
  Object? error;
  bool hasMore = false;
  bool loadingMore = false;
  bool get loading => pending > 0;

  void begin() {
    if (pending++ == 0) {
      received = 0;
      error = null;
      loadingMore = false;
    }
  }
}
