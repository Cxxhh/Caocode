import 'dart:async';

import 'package:caocode/ide/ide_list.dart' show IdeListColors;
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/models/model_providers.dart';
import 'package:caocode/stash/stash_ai.dart';
import 'package:caocode/stash/stash_controller.dart';
import 'package:caocode/stash/stash_disk.dart';
import 'package:caocode/stash/stash_host.dart';
import 'package:caocode/stash/stash_note.dart';
import 'package:caocode/stash/stash_note_editor.dart';
import 'package:caocode/stash/stash_store.dart';
import 'package:caocode/sidebar/sidebar.dart' show SidebarIconButton;
import 'package:caocode/stash/stash_thread_view.dart';
import 'package:caocode/stash/stash_view.dart';
import 'package:caocode/chat/chat_session.dart' show ComposerMessage;
import 'package:caocode/theme/app_theme.dart';
import 'package:caocode/theme/codicons.dart';
import 'package:caocode/workspace/workspace.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late StashStore store;
  late StashController controller;
  late ModelProviders models;
  final previous = ModelProviders.current;

  setUp(() {
    store = StashStore(MemoryStashDisk());
    controller = StashController(
      store: store,
      workspace: Workspace.mock(),
      host: StashHost(channel: const MethodChannel('test/stash-view')),
    );
    models = ModelProviders.current = ModelProviders.memory();
  });

  tearDown(() {
    ModelProviders.current = previous;
    controller.dispose();
  });

  group('said clearly in the background', () {
    test('its text replaced in its file once the answer comes, a collected '
        'one a requirement', () async {
      final note = await store.create(body: 'btn hidden\n\n## 需求\n\nold');
      final answer = Completer<String>();
      String? asked;
      controller.clarifier = (controller, id, text, {cancellation}) {
        asked = text;
        return answer.future;
      };
      final clarifying = controller.clarify(note.id);
      expect(controller.clarifying(note.id), isTrue);
      expect(asked, 'btn hidden');
      answer.complete('The button is hidden.');
      await clarifying;
      expect(controller.clarifying(note.id), isFalse);
      expect(controller.clarifyFailure(note.id), isNull);
      final now = store.byId(note.id)!;
      expect(now.body, startsWith('The button is hidden.'));
      expect(now.body, contains('## 需求\n\nold'));
      expect(now.status, StashStatus.requirement);
    });

    test('a failure is kept with its message, until dismissed', () async {
      final note = await store.create(body: 'btn hidden');
      controller.clarifier = (controller, id, text, {cancellation}) async =>
          throw const StashAiException('Not signed in');
      await controller.clarify(note.id);
      expect(controller.clarifyFailure(note.id), (
        changed: false,
        message: 'Not signed in',
      ));
      expect(store.byId(note.id)!.body, 'btn hidden');
      controller.dismissClarifyFailure(note.id);
      expect(controller.clarifyFailure(note.id), isNull);
    });

    test('a text changed meanwhile is not replaced', () async {
      final note = await store.create(body: 'btn hidden');
      controller.clarifier = (controller, id, text, {cancellation}) async {
        await store.update(id, (note) => note.body = 'btn hidden, and more');
        return 'The button is hidden.';
      };
      await controller.clarify(note.id);
      expect(controller.clarifyFailure(note.id)?.changed, isTrue);
      expect(store.byId(note.id)!.body, 'btn hidden, and more');
    });

    test(
      'cancelling stops the request without replacing text or failing',
      () async {
        final note = await store.create(body: 'btn hidden');
        final answer = Completer<String>();
        StashClarifyCancellation? signal;
        controller.clarifier = (controller, id, text, {cancellation}) {
          signal = cancellation;
          return answer.future;
        };
        final pending = controller.clarify(note.id);
        expect(controller.clarifying(note.id), isTrue);
        controller.cancelClarify(note.id);
        expect(signal?.cancelled, isTrue);
        expect(controller.clarifying(note.id), isFalse);
        expect(controller.clarifyFailure(note.id), isNull);
        answer.complete('The button is hidden.');
        await pending;
        expect(store.byId(note.id)!.body, 'btn hidden');
        expect(store.byId(note.id)!.status, StashStatus.collected);
        expect(controller.clarifyFailure(note.id), isNull);
      },
    );

    test('an old answer cannot overwrite an immediate retry', () async {
      final note = await store.create(body: 'btn hidden');
      final old = Completer<String>();
      final latest = Completer<String>();
      var asks = 0;
      controller.clarifier = (controller, id, text, {cancellation}) =>
          ++asks == 1 ? old.future : latest.future;
      final first = controller.clarify(note.id);
      controller.cancelClarify(note.id);
      final second = controller.clarify(note.id);
      expect(asks, 2);
      old.complete('Old reply');
      await first;
      expect(controller.clarifying(note.id), isTrue);
      expect(controller.clarifyFailure(note.id), isNull);
      expect(store.byId(note.id)!.body, 'btn hidden');
      latest.complete('Latest reply');
      await second;
      expect(store.byId(note.id)!.body, 'Latest reply');
      expect(store.byId(note.id)!.status, StashStatus.requirement);
    });

    test('an old error cannot mark a retry as failed', () async {
      final note = await store.create(body: 'btn hidden');
      final old = Completer<String>();
      final latest = Completer<String>();
      var asks = 0;
      controller.clarifier = (controller, id, text, {cancellation}) =>
          ++asks == 1 ? old.future : latest.future;
      final first = controller.clarify(note.id);
      controller.cancelClarify(note.id);
      final second = controller.clarify(note.id);
      old.completeError(const StashAiException('Old error'));
      await first;
      expect(controller.clarifying(note.id), isTrue);
      expect(controller.clarifyFailure(note.id), isNull);
      latest.complete('Latest reply');
      await second;
      expect(controller.clarifyFailure(note.id), isNull);
      expect(store.byId(note.id)!.body, 'Latest reply');
    });
  });

  Future<void> pumpView(
    WidgetTester tester, {
    int? open,
    ValueChanged<AgentThread>? onOpenAgent,
  }) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Material(
          child: StashView(
            controller: controller,
            onClose: () {},
            onOpenAgent: onOpenAgent ?? (_) {},
            initial: open,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('"Clarify" asks for a model first, then goes on in the '
      'background: the card says so, the editor gets the answer, Undo takes '
      'it back; there is no Split', (tester) async {
    final note = await tester.runAsync(() => store.create(body: 'btn hidden'));
    final answer = Completer<String>();
    controller.clarifier = (controller, id, text, {cancellation}) =>
        answer.future;
    await pumpView(tester, open: note!.id);
    expect(find.text('Split'), findsNothing);

    await tester.tap(find.text('Clarify'));
    await tester.pumpAndSettle();
    // None picked yet: the menu that picks one, saying so.
    expect(find.text(englishLocalizations.aiModelFirst), findsOneWidget);
    expect(controller.clarifying(note.id), isFalse);
    await tester.tap(find.text(englishLocalizations.aiModelAuxiliary));
    // Spinning while it goes on: never settled.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(models.actionsModel, ModelProviders.followAuxiliary);
    expect(controller.clarifying(note.id), isTrue);
    expect(find.text('Clarifying…'), findsWidgets);

    answer.complete('The button is hidden.');
    await tester.pumpAndSettle();
    expect(controller.clarifying(note.id), isFalse);
    final editor = StashNoteEditorState.showing(note.id)!;
    expect(editor.markdown, startsWith('The button is hidden.'));
    editor.editor!.widget.controller.undo();
    expect(editor.markdown, startsWith('btn hidden'));

    // Picked: the next one asks no more, and the arrow beside it changes
    // the model.
    controller.clarifier = (controller, id, text, {cancellation}) async =>
        throw const StashAiException('Not signed in');
    await tester.tap(find.text('Clarify'));
    await tester.pumpAndSettle();
    expect(find.text(englishLocalizations.aiModelFirst), findsNothing);
    expect(
      find.text(englishLocalizations.stashExpandFailed('Not signed in')),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(controller.clarifyFailure(note.id), isNotNull);
    await tester.tap(find.text('Dismiss').last);
    await tester.pumpAndSettle();
    expect(
      find.text(englishLocalizations.stashExpandFailed('Not signed in')),
      findsNothing,
    );
    await unmount(tester);
  });

  testWidgets('the detail can stop a clarification in progress', (
    tester,
  ) async {
    final note = await tester.runAsync(() => store.create(body: 'btn hidden'));
    await models.setActionsModel(ModelProviders.followAuxiliary);
    final answer = Completer<String>();
    controller.clarifier = (controller, id, text, {cancellation}) =>
        answer.future;
    await pumpView(tester, open: note!.id);
    await tester.tap(find.text(englishLocalizations.stashExpand));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.clarifying(note.id), isTrue);
    expect(find.text(englishLocalizations.stashCancelClarify), findsOneWidget);

    await tester.tap(find.text(englishLocalizations.stashCancelClarify));
    await tester.pumpAndSettle();
    expect(controller.clarifying(note.id), isFalse);
    expect(find.text(englishLocalizations.stashExpand), findsOneWidget);
    answer.complete('Old reply');
    await tester.pumpAndSettle();
    expect(StashNoteEditorState.showing(note.id)!.markdown, 'btn hidden');
    expect(controller.clarifyFailure(note.id), isNull);
    await unmount(tester);
  });

  testWidgets('New writes a stash here, its text with the keyboard; a '
      'draft left blank gone on with (#147)', (tester) async {
    final newButton = find.byWidgetPredicate(
      (widget) =>
          widget is SidebarIconButton &&
          widget.tooltip == englishLocalizations.stashNewTooltip,
    );
    Future<void> tapNew() async {
      await tester.tap(newButton);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await pumpView(tester);
    await tapNew();
    final draft = store.notes.single;
    expect(draft.isDraft, isTrue);
    expect(tester.widget<StashDetail>(find.byType(StashDetail)).id, draft.id);
    // Typed in at once: the keyboard in its text.
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
      find.descendant(
        of: find.byType(StashNoteEditor),
        matching: find.byElementPredicate((element) => element == focused),
      ),
      findsOneWidget,
    );
    expect(tester.testTextInput.hasAnyClients, isTrue);
    await unmount(tester);

    // Left blank, the next New goes on with it, made no other.
    final blank = (await tester.runAsync(() => store.create()))!;
    await pumpView(tester);
    await tapNew();
    expect(store.notes, hasLength(2));
    expect(tester.widget<StashDetail>(find.byType(StashDetail)).id, blank.id);
    await unmount(tester);

    // Of the project the page shows alone, still a draft.
    final id = (await tester.runAsync(
      () => controller.draft(project: '/p/app'),
    ))!;
    expect(id, blank.id);
    expect(store.byId(id)!.project, '/p/app');
    expect(store.byId(id)!.isDraft, isTrue);
  });

  testWidgets('the line between the cards and the stash drags, the width '
      'kept; a double click puts it back', (tester) async {
    final note = await tester.runAsync(() => store.create(body: 'something'));
    await pumpView(tester, open: note!.id);
    final sash = find.byKey(const ValueKey('stash-sash'));
    final before = tester.getTopLeft(sash).dx;
    await tester.drag(sash, const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(sash).dx, closeTo(before - 150, 1));
    final kept = controller.detailWidth;
    expect(kept, isNotNull);

    // The cards keep their least.
    await tester.drag(sash, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(sash).dx, greaterThanOrEqualTo(320));

    await tester.tap(sash);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(sash);
    await tester.pumpAndSettle();
    expect(controller.detailWidth, isNull);
    expect(tester.getTopLeft(sash).dx, closeTo(before, 1));
    await unmount(tester);
  });

  testWidgets('cards by their number, the newest first; those done hidden '
      'at first; statuses and projects picked several at once', (tester) async {
    final ids = (await tester.runAsync(() async {
      final ids = <int>[];
      for (final (title, project) in [
        ('Alpha', null),
        ('Beta', '~/code/caocode'),
        ('Gamma', '~/code/cursor-docs'),
      ]) {
        final note = await store.create(body: '$title\n\nmore');
        // Not collected: none to be merged, which would ask the AI.
        await store.update(note.id, (note) {
          note.status = title == 'Alpha'
              ? StashStatus.done
              : StashStatus.requirement;
          note.project = project;
        });
        ids.add(note.id);
      }
      // Beta written last: still after Gamma, by its number.
      await store.update(ids[1], (note) => note.body = 'Beta\n\nagain');
      return ids;
    }))!;
    await pumpView(tester);
    Finder card(String title) => find.descendant(
      of: find.byWidgetPredicate((widget) => widget is Draggable),
      matching: find.text(title),
    );
    expect(card('Alpha'), findsNothing);
    final gamma = tester.getTopLeft(card('Gamma'));
    final beta = tester.getTopLeft(card('Beta'));
    expect(
      gamma.dy < beta.dy || (gamma.dy == beta.dy && gamma.dx < beta.dx),
      isTrue,
    );

    // Done checked too, the menu left open.
    await tester.tap(find.text('Not done'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Done').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(card('Alpha'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Any status'), findsOneWidget);

    await tester.tap(find.text('Any project'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('caocode').last);
    await tester.pump();
    await tester.tap(find.text('cursor-docs').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('2 projects'), findsOneWidget);
    expect(card('Alpha'), findsNothing);
    expect(card('Beta'), findsOneWidget);

    // Kept for the next time the page shows.
    await unmount(tester);
    await pumpView(tester);
    expect(find.text('2 projects'), findsOneWidget);
    expect(find.text('Any status'), findsOneWidget);
    expect(card('Alpha'), findsNothing);
    expect(card('Beta'), findsOneWidget);

    // Shown from elsewhere: the filters let it be seen, those picked kept.
    tester.state<StashViewState>(find.byType(StashView)).show(ids[0]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(card('Alpha'), findsOneWidget);
    expect(find.text('Any project'), findsOneWidget);
    expect(controller.filters?['projects'], hasLength(2));
    await unmount(tester);
  });

  testWidgets('the card shown is drawn as the explorer\'s selected file; '
      'another shown, the other cards are left as they were', (tester) async {
    final ids = await tester.runAsync(
      () async => [
        for (final title in ['First', 'Second', 'Third'])
          (await store.create(body: '$title\n\nmore')).id,
      ],
    );
    // Not collected: none to be merged, which would ask the AI.
    await tester.runAsync(() async {
      for (final id in ids!) {
        await store.update(id, (note) => note.status = StashStatus.requirement);
      }
    });
    await pumpView(tester, open: ids![0]);
    Finder card(String title) => find.descendant(
      of: find.byWidgetPredicate((widget) => widget is Draggable),
      matching: find.text(title),
    );
    Color? fill(String title) =>
        (tester
                    .widget<Container>(
                      find
                          .ancestor(
                            of: card(title),
                            matching: find.byWidgetPredicate(
                              (widget) =>
                                  widget is Container &&
                                  widget.decoration is BoxDecoration,
                            ),
                          )
                          .last,
                    )
                    .decoration!
                as BoxDecoration)
            .color;
    expect(fill('First'), IdeListColors.activeSelection);
    expect(fill('Second'), isNot(IdeListColors.activeSelection));
    final third = tester.element(card('Third')).widget;

    await tester.tap(card('Second'));
    await tester.pumpAndSettle();
    expect(fill('Second'), IdeListColors.activeSelection);
    expect(fill('First'), isNot(IdeListColors.activeSelection));
    expect(StashNoteEditorState.showing(ids[1]), isNotNull);
    // Not built anew.
    expect(identical(tester.element(card('Third')).widget, third), isTrue);
    await unmount(tester);
  });

  testWidgets('the card shows the conversation it was last worked on in, '
      'what its agent said; the detail lists them all, a click away', (
    tester,
  ) async {
    // Its agents' kernels started in the test's time.
    controller.dispose();
    controller = StashController(
      store: store,
      workspace: Workspace.mock(),
      host: StashHost(channel: const MethodChannel('test/stash-view')),
    );
    final thread = controller.workspace.threads.first;
    thread.session.send(const ComposerMessage(text: 'Retry the uploads'));
    for (var i = 0; i < 50 && thread.id == null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final session = thread.id!;
    thread.session.stop();
    await tester.pump(const Duration(seconds: 1));
    final note = (await tester.runAsync(
      () => store.create(body: 'Uploads fail\nThey should retry on 503'),
    ))!;
    await tester.runAsync(
      () => store.update(note.id, (note) {
        note.status = StashStatus.implementing;
        note.threads.addAll([
          const StashThreadLink(
            session: 'gone',
            project: '/elsewhere/app',
            title: 'An old one',
            said: 'Looked into it.',
          ),
          StashThreadLink(
            session: session,
            project: thread.project.path,
            said: 'Uploads retry three times now.',
            at: DateTime(2026, 10, 15, 9),
          ),
        ]);
      }, touch: false),
    );
    AgentThread? opened;
    await pumpView(tester, onOpenAgent: (thread) => opened = thread);

    final chip = find.byType(StashThreadChip);
    expect(chip, findsOneWidget);
    Finder inChip(String text) =>
        find.descendant(of: chip, matching: find.text(text));
    expect(inChip(thread.title), findsOneWidget);
    expect(inChip('Uploads retry three times now.'), findsOneWidget);
    expect(inChip('+1'), findsOneWidget);
    // In place of its text (its title stays).
    expect(find.text('Uploads fail'), findsOneWidget);
    expect(find.text('They should retry on 503'), findsNothing);
    // A click on it is the card's: the stash opens, not the conversation.
    await tester.tap(chip);
    expect(opened, isNull);
    // Sliding in.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final list = find.byType(StashThreadList);
    Finder inList(String text) =>
        find.descendant(of: list, matching: find.text(text));
    expect(inList('Conversations'), findsOneWidget);
    expect(inList('An old one'), findsOneWidget);
    expect(inList('Looked into it.'), findsOneWidget);
    // Not listed any more: nothing to open.
    await tester.tap(inList('An old one'));
    expect(opened, isNull);
    await tester.tap(inList('Uploads retry three times now.'));
    expect(opened, thread);
    await unmount(tester);
  });

  testWidgets('a stash\'s file shows as the Stash page shows it', (
    tester,
  ) async {
    final note = await tester.runAsync(
      () => store.create(body: 'see the sidebar'),
    );
    final view = stashFileView(controller);
    final path = '${store.root}/${note!.id}.md';
    expect(view.matches(path), isTrue);
    expect(view.matches('${store.root}/99.md'), isFalse);
    expect(view.matches('${store.root}/${note.id}/a.png'), isFalse);
    expect(view.matches('/elsewhere/${note.id}.md'), isFalse);

    tester.view.physicalSize = const Size(700, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Material(
          child: Builder(builder: (context) => view.build(context, path)),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(StashDetail), findsOneWidget);
    expect(find.text('Clarify'), findsOneWidget);
    // In a tab: closed with it, no button of its own.
    expect(find.byIcon(Codicons.close), findsNothing);
    expect(StashNoteEditorState.showing(note.id)?.markdown, 'see the sidebar');
    await unmount(tester);
  });

  testWidgets('with the sidebar hidden on macOS, the toggle is clear of the '
      'traffic lights, before the title', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        home: Material(
          child: StashView(
            controller: controller,
            onClose: () {},
            onOpenAgent: (_) {},
            leading: const SidebarIconButton(
              icon: Codicons.layoutSidebarLeftOff,
              tooltip: 'Show sidebar',
              onTap: _noop,
            ),
            titleBarInset: AppMetrics.trafficLightsWidth + 8,
          ),
        ),
      ),
    );
    await tester.pump();
    final toggle = tester.getRect(find.byIcon(Codicons.layoutSidebarLeftOff));
    final title = tester.getRect(find.text(englishLocalizations.stashTitle));
    expect(toggle.left, greaterThanOrEqualTo(AppMetrics.trafficLightsWidth));
    expect(toggle.right, lessThanOrEqualTo(title.left));
    await unmount(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}

void _noop() {}
