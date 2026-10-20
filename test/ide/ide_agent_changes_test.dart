import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/chat/chat_models.dart';
import 'package:caocode/chat/chat_session.dart';
import 'package:caocode/chat/review/change_review.dart';
import 'package:caocode/chat/review/review_store.dart';
import 'package:caocode/ide/ide_agent_changes.dart';
import 'package:caocode/kernel/agent_kernel.dart' show KernelContext;
import 'package:caocode/kernel/mock/mock_kernels.dart';

class _NoStore implements ReviewStore {
  @override
  final String root = '/p';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A review whose changes the test sets, to drive the watcher.
class _Review extends ChangeReview {
  _Review() : super(_NoStore());

  List<FileChange> listed = const [];

  void list(List<FileChange> changes) {
    listed = changes;
    notifyListeners();
  }

  @override
  List<FileChange> get changes => listed;

  // Never looks at the store (a no-op), so it never fails.
  @override
  Future<void> refresh() async {}

  @override
  Future<String> Function()? original(String path) =>
      path.endsWith('.dart') ? () async => 'before' : null;
}

void main() {
  late _Review review;
  late ChatSession chat;

  const change = FileChange(path: '/p/a.dart', added: 2, removed: 1);

  // Recorded opens, cleared by each setUp.
  final opened = <(FileChange, Future<String> Function()?)>[];

  /// A session whose review is [review], the watcher over it. [pending] are
  /// the changes already there as it mounts.
  Future<void> setUp(
    WidgetTester tester, {
    bool enabled = true,
    List<FileChange> pending = const [],
  }) async {
    opened.clear();
    review = _Review();
    chat = ChatSession(
      kernel: MockKernels.claudeCode,
      kernelContext: const KernelContext(cwd: '/p'),
      historyCount: 0,
      openReview: (root, {session}) async => review,
    );
    addTearDown(chat.dispose);
    // As a view showing the conversation does: the review opens.
    chat.attach();
    review.list(pending);
    await tester.pumpWidget(
      MaterialApp(
        home: IdeAgentChanges(
          session: chat,
          enabled: enabled,
          open: (change, original) => opened.add((change, original)),
        ),
      ),
    );
    // The review opens (a microtask): a pump flushes it.
    await tester.pump();
  }

  testWidgets('opens each new change once, with its original reader', (
    tester,
  ) async {
    await setUp(tester);
    // Nothing pending at first: nothing opened.
    review.list(const [change]);
    await tester.pump();
    expect(opened, hasLength(1));
    expect(opened.single.$1, change);
    expect(opened.single.$2, isNotNull);
    // The same change reported again: not opened twice.
    review.list(const [change]);
    await tester.pump();
    expect(opened, hasLength(1));
  });

  testWidgets('a change pending as it mounts is not opened', (tester) async {
    await setUp(tester, pending: const [change]);
    expect(opened, isEmpty);
    // A new change is.
    review.list(const [
      change,
      FileChange(path: '/p/b.dart', added: 1, removed: 0),
    ]);
    await tester.pump();
    expect(opened, hasLength(1));
    expect(opened.single.$1.path, '/p/b.dart');
  });

  testWidgets('a change made again after being kept opens anew', (
    tester,
  ) async {
    await setUp(tester);
    review.list(const [change]);
    await tester.pump();
    expect(opened, hasLength(1));
    // Kept: no longer pending.
    review.list(const []);
    await tester.pump();
    // Changed again: opened anew.
    review.list(const [change]);
    await tester.pump();
    expect(opened, hasLength(2));
  });

  testWidgets('with it off, the changes are not opened', (tester) async {
    await setUp(tester, enabled: false);
    review.list(const [change]);
    await tester.pump();
    expect(opened, isEmpty);
  });

  test('the setting is off unless it is true', () {
    expect(IdeAgentChanges.enabledBy(null), isFalse);
    expect(IdeAgentChanges.enabledBy(true), isTrue);
    expect(IdeAgentChanges.enabledBy(false), isFalse);
  });
}
