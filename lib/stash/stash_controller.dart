import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' show ChangeSource;
import 'package:path/path.dart' as p;

import '../forge/forge_accounts.dart';
import '../kernel/claude_code/claude_haiku.dart' show ClaudeHaikuCancelled;
import '../remote/remote_location.dart';
import '../settings/user_settings.dart' show GlobalStorage;
import '../window/app_windows.dart';
import '../workspace/workspace.dart';
import 'stash_actions.dart' show clarifyStash;
import 'stash_ai.dart';
import 'stash_editor.dart' show StashRefs, stashTextPart, stashTextRewrite;
import 'stash_host.dart';
import 'stash_io_stub.dart' if (dart.library.io) 'stash_io.dart' as io;
import 'stash_markdown.dart';
import 'stash_note.dart';
import 'stash_note_editor.dart';
import 'stash_settings.dart';
import 'stash_skill.dart' show StashSkill;
import 'stash_forge.dart';
import 'stash_store.dart';
import 'stash_threads.dart';

/// Why a stash could not be said clearly ([StashController.clarify]): its
/// text [changed] meanwhile, or the model's [message] (none: no answer
/// that was one).
typedef StashClarifyFailure = ({bool changed, String? message});

/// The app's side of the stash (see docs/stash.md): the shortcut and its
/// panel, which stash it shows, and what goes on in the background (the
/// text in pictures read, titles and projects suggested).
class StashController extends ChangeNotifier {
  StashController({
    required this.store,
    required this.workspace,
    this.windows,
    StashHost? host,
    Map<String, Object?> Function()? settings,
    this.updateSetting,
    this.settingsChanges,
    this.cacheDir,
    this.storage,
    this.installSkill = false,
    this.accounts,
  }) : host = host ?? StashHost.instance,
       _settings = settings ?? (() => const {});

  /// The app's, once main() has made it.
  static StashController? current;

  final StashStore store;
  final Workspace workspace;
  final AppWindows? windows;
  final StashHost host;
  final Map<String, Object?> Function() _settings;
  final Listenable? settingsChanges;

  /// Writes a setting to settings.json; not kept without one.
  final Future<void> Function(String key, Object? value)? updateSetting;

  /// Where the text read out of pictures is kept; not kept without one.
  final String? cacheDir;

  /// Where the stashes' page keeps its layout; not kept without one.
  final GlobalStorage? storage;

  /// The user's accounts on GitHub, GitLab…: the stashes' issues and
  /// pull requests are asked of them ([forge]); none without.
  final ForgeAccounts? accounts;

  /// Whether to write the Stash skill into Claude Code's skills on this
  /// machine (see [StashSkill]): the app's, not a test's.
  final bool installSkill;

  static const detailWidthKey = 'stash.detailWidth';

  /// The width of the stash shown beside the cards, as last dragged; null
  /// for the page's own.
  double? get detailWidth =>
      _detailWidth ?? storage?.get<num>(detailWidthKey)?.toDouble();
  double? _detailWidth;

  set detailWidth(double? width) {
    _detailWidth = width;
    unawaited(
      storage
          ?.set(detailWidthKey, width)
          .catchError((Object error) => debugPrint('$error')),
    );
  }

  static const filtersKey = 'stash.filters';

  /// The Stash page's filters, as last picked (its time, projects and
  /// statuses, by name; see StashView); null for its own.
  Map<String, Object?>? get filters =>
      _filters ?? storage?.get<Map<String, Object?>>(filtersKey);
  Map<String, Object?>? _filters;

  set filters(Map<String, Object?>? filters) {
    _filters = filters;
    unawaited(
      storage
          ?.set(filtersKey, filters)
          .catchError((Object error) => debugPrint('$error')),
    );
  }

  static const welcomedKey = 'stash.welcomed';

  /// Whether the Stash page has said what it is (the first time it shows,
  /// see showStashWelcome); as if it had where nothing is kept (a test).
  bool get welcomed =>
      _welcomed ?? (storage == null || storage!.get<bool>(welcomedKey) == true);
  bool? _welcomed;

  set welcomed(bool welcomed) {
    _welcomed = welcomed;
    unawaited(
      storage
          ?.set(welcomedKey, welcomed)
          .catchError((Object error) => debugPrint('$error')),
    );
  }

  StashSettings get settings => StashSettings.parse(_settings());

  bool _started = false;

  /// Starts: the stashes read, the shortcut taken, the panel made (hidden)
  /// a little after, for it to show at once.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    host.onPressed = pressed;
    windows?.stashCloseRequested = () => unawaited(hide());
    settingsChanges?.addListener(_settingsChanged);
    store.addListener(_storeChanged);
    await store.load();
    threads.start();
    forge?.start();
    if (installSkill && store.root.isNotEmpty) {
      unawaited(io.installStashSkill(store.root));
    }
    await _takeHotkey();
    Timer(const Duration(seconds: 2), () => unawaited(windows?.startStash()));
    _storeChanged();
  }

  String? _hotkey;

  /// Whether the system gave the shortcut; null where there is none.
  bool? get hotkeyTaken => _hotkeyTaken;
  bool? _hotkeyTaken;

  Future<void> _takeHotkey() async {
    final hotkey = settings.hotkey;
    if (hotkey == _hotkey) return;
    _hotkey = hotkey;
    // None: the one held let go, nothing to have been given.
    final taken = await host.setHotkey(hotkey);
    _hotkeyTaken = hotkey.isEmpty ? null : taken;
    notifyListeners();
  }

  void _settingsChanged() => unawaited(_takeHotkey());

  /// Lets the shortcut go while a new one is recorded: pressed, it would
  /// show the panel rather than reach the recorder. [resumeHotkey] takes
  /// it (or the one recorded) again.
  Future<void> pauseHotkey() async {
    _hotkey = null;
    await host.setHotkey('');
  }

  Future<void> resumeHotkey() => _takeHotkey();

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    for (final cancellation in _clarifying.values) {
      cancellation.cancel();
    }
    _clarifying.clear();
    threads.dispose();
    if (accounts != null) forge?.dispose();
    settingsChanges?.removeListener(_settingsChanged);
    store.removeListener(_storeChanged);
    if (identical(host.onPressed, pressed)) host.onPressed = null;
    windows?.stashCloseRequested = null;
    for (final timer in _suggesting.values) {
      timer.cancel();
    }
    _suggesting.clear();
    super.dispose();
  }

  // --- The panel ---------------------------------------------------------------

  /// Whether the panel shows.
  bool get shown => windows?.stashShown ?? false;

  /// The stash the panel shows; null for a new one nothing was written in
  /// yet (it is made with the first thing written: see [ensureNote]).
  int? get editing => _editing;
  int? _editing;

  /// Where the panel was asked for (Caocode itself or not).
  StashCapture _capture = StashCapture.none;

  /// Counts the panel's showings: each is a new start for it (its text
  /// read again, the caret at the end).
  int get presentation => _presentation;
  int _presentation = 0;

  /// Shows [id]'s stash on the stashes' page (the main window's
  /// workbench sets it).
  void Function(int id)? showPage;

  /// Set by the panel: writes what it has, before it hides.
  Future<void> Function()? onHiding;

  /// The shortcut: shows the panel with a new stash, hides it when it is
  /// what the keyboard is in, or gives it the keyboard back (another app
  /// clicked meanwhile), as it was.
  void pressed(StashCapture capture) {
    if (!shown) {
      unawaited(present(capture));
    } else if (capture.panelInFront ?? true) {
      unawaited(hide());
    } else {
      unawaited(windows?.showStash());
    }
  }

  /// Shows the panel, with a new stash: the draft there is (a stash still
  /// blank), else one made at once.
  Future<void> present([StashCapture capture = StashCapture.none]) async {
    final windows = this.windows;
    if (windows == null) return;
    await store.load();
    _capture = capture;
    if (_draft() case final draft?) {
      _editing = draft.id;
    } else {
      _editing = null;
      await ensureNote();
    }
    _presentation++;
    notifyListeners();
    await windows.showStash();
  }

  /// The panel goes on with [id]'s stash in place of the one it shows
  /// (picked among them all, beside it).
  Future<void> edit(int id) async {
    if (id == _editing) return;
    await onHiding?.call();
    final edited = _editing;
    // A blank one stays, a draft.
    if (edited != null) _suggestSoon(edited);
    _capture = StashCapture.none;
    _editing = store.byId(id)?.id;
    _presentation++;
    notifyListeners();
  }

  /// Whether the panel shows every stash beside the one written in.
  bool get showAll => _showAll ?? settings.showAll;
  bool? _showAll;

  set showAll(bool value) {
    _showAll = value;
    notifyListeners();
    unawaited(
      updateSetting?.call(StashSettings.showAllKey, value ? true : null),
    );
  }

  /// Whether the panel stays over other apps' windows.
  bool get pinned => _pinned ?? settings.pinned;
  bool? _pinned;

  set pinned(bool value) {
    _pinned = value;
    notifyListeners();
    unawaited(
      updateSetting?.call(StashSettings.pinnedKey, value ? true : null),
    );
  }

  /// How the panel's list of all orders them.
  StashSort get sort => _sort ?? settings.sort;
  StashSort? _sort;

  set sort(StashSort value) {
    _sort = value;
    notifyListeners();
    unawaited(
      updateSetting?.call(
        StashSettings.sortKey,
        value == StashSort.updated ? null : value.name,
      ),
    );
  }

  /// Shows the panel with [id]'s stash (from the stash's page).
  Future<void> open(int id) async {
    final windows = this.windows;
    if (windows == null) return;
    _capture = StashCapture.none;
    _editing = id;
    _presentation++;
    notifyListeners();
    await windows.showStash();
  }

  /// Hides the panel, at once: what it has written is kept as it goes; a
  /// stash left blank stays the draft the panel shows next.
  Future<void> hide() async {
    final writing = onHiding?.call();
    final edited = _editing;
    await windows?.hideStash();
    await writing;
    if (edited != null) _suggestSoon(edited);
  }

  /// The stash made and never written in (see [StashNote.isDraft]), the
  /// newest if there are more: what "New" and the shortcut go on with
  /// rather than making another.
  StashNote? _draft() {
    for (final note in store.notes) {
      if (note.isDraft) return note;
    }
    return null;
  }

  /// The panel goes on with a new stash, made at once.
  Future<void> startNew() async {
    await onHiding?.call();
    final edited = _editing;
    // Still blank: it is a new one already (gone and made again, the panel
    // would blink).
    if (edited != null && store.byId(edited)?.isDraft == true) return;
    // The draft there is, else one made.
    final note =
        _draft() ?? await store.create(source: await sourceOf(_capture));
    // The panel to it at once, in one change.
    _editing = note.id;
    _presentation++;
    notifyListeners();
    if (edited != null) _suggestSoon(edited);
  }

  /// A new stash to write in on the Stash page, beside the cards: the
  /// draft there is, else one made; of [project], if given. Its id.
  Future<int> draft({String? project}) async {
    await store.load();
    final id =
        _draft()?.id ?? (await store.create(source: StashSource.none)).id;
    if (project != null) {
      // Not written in for this: still the draft, if left blank.
      await store.update(id, (note) => note.project = project, touch: false);
    }
    return id;
  }

  /// The stash the panel shows, made (with [body]) if it was not yet.
  Future<int> ensureNote({String body = ''}) async {
    if (_editing case final id? when store.byId(id) != null) return id;
    // Asked again while it is being made: the same one.
    return _creating ??= () async {
      try {
        final note = await store.create(
          body: body,
          // Of no project until one is picked: where it was written is
          // in its source.
          source: await sourceOf(_capture),
        );
        _editing = note.id;
        notifyListeners();
        return note.id;
      } finally {
        _creating = null;
      }
    }();
  }

  Future<int>? _creating;

  /// Where a stash made now comes from: Caocode's project, branch and
  /// conversation when it was jotted down there; nothing otherwise.
  Future<StashSource> sourceOf(StashCapture capture) async {
    if (!capture.inApp) return StashSource.none;
    final thread = workspace.current;
    final project = thread?.project.path;
    return StashSource(
      project: project,
      branch: project == null || RemoteLocation.hostOf(project) != null
          ? null
          : await io.gitBranchOf(project),
      thread: thread?.id,
    );
  }

  // --- Said clearly ------------------------------------------------------------

  /// What says a stash's text clearly: [clarifyStash], but in tests.
  @visibleForTesting
  Future<String> Function(
    StashController controller,
    int id,
    String text, {
    StashClarifyCancellation? cancellation,
  })
  clarifier = clarifyStash;

  final Map<int, StashClarifyCancellation> _clarifying = {};
  final Map<int, StashClarifyFailure> _clarifyFailures = {};

  /// Whether [id]'s stash is being said clearly ([clarify]).
  bool clarifying(int id) => _clarifying.containsKey(id);

  /// Why [id]'s stash could not be said clearly, the last time it was
  /// asked to be; null when it was, or was not asked.
  StashClarifyFailure? clarifyFailure(int id) => _clarifyFailures[id];

  void dismissClarifyFailure(int id) {
    if (_clarifyFailures.remove(id) != null) notifyListeners();
  }

  /// Stops [id]'s current clarification; a new one may start at once.
  void cancelClarify(int id) {
    final cancellation = _clarifying.remove(id);
    if (cancellation == null) return;
    cancellation.cancel();
    if (!_disposed) notifyListeners();
  }

  /// Says [id]'s stash clearly (see [clarifyStash]), in the background,
  /// whatever shows meanwhile: its text replaced once the answer comes, in
  /// the editor showing it if one does (Undo takes it back), else in its
  /// file; a collected one is a requirement then. [clarifying] while it
  /// goes on; [clarifyFailure] after, where it failed (no answer, or the
  /// text changed meanwhile).
  Future<void> clarify(int id) async {
    if (_disposed || _clarifying.containsKey(id)) return;
    final note = store.byId(id);
    if (note == null) return;
    final asked = switch (StashNoteEditorState.showing(id)?.editor) {
      final editor? => editor.textPart,
      null => stashTextPart(stashDocument(note.body), store.absolute),
    };
    if (asked == null) return;
    final cancellation = StashClarifyCancellation();
    bool current() => identical(_clarifying[id], cancellation);
    _clarifying[id] = cancellation;
    _clarifyFailures.remove(id);
    notifyListeners();
    try {
      final reply = await clarifier(
        this,
        id,
        asked.text,
        cancellation: cancellation,
      );
      if (!current()) return;
      if (!await _rewrite(id, asked.text, reply)) {
        if (current()) {
          _clarifyFailures[id] = (changed: true, message: null);
        }
      } else if (current()) {
        await store.update(id, (note) {
          if (note.status == StashStatus.collected) {
            note.status = StashStatus.requirement;
          }
        });
      }
    } on StashAiException catch (error) {
      if (current()) {
        _clarifyFailures[id] = (changed: false, message: error.message);
      }
    } on ClaudeHaikuCancelled {
      // Cancelled requests do not leave a failure to dismiss.
    } finally {
      if (current()) {
        _clarifying.remove(id);
        if (!_disposed) notifyListeners();
      }
    }
  }

  /// [id]'s text, given to a model as [asked], [reply] in its place;
  /// whether it was (not when it changed meanwhile).
  Future<bool> _rewrite(int id, String asked, String reply) async {
    if (StashNoteEditorState.showing(id) case final shown?) {
      if (!(shown.editor?.rewrite(asked, reply) ?? false)) return false;
      await shown.flush();
      return true;
    }
    final note = store.byId(id);
    if (note == null) return false;
    final document = stashDocument(note.body);
    final rewritten = stashTextRewrite(document, asked, reply, store.absolute);
    if (rewritten == null) return false;
    document.compose(rewritten.change, ChangeSource.local);
    final body = stashDeltaToMarkdown(document.toDelta());
    await store.update(id, (note) => note.body = body);
    return true;
  }

  // --- Carried out in conversations ---------------------------------------------

  /// The conversations the stashes are carried out in.
  late final StashThreads threads = StashThreads(
    store: store,
    workspace: workspace,
    forgeKindOf: accounts?.kindOf,
  );

  /// The stashes' issues and pull requests; none without [accounts].
  late final StashForge? forge = switch (accounts) {
    final accounts? => StashForge(
      store: store,
      workspace: workspace,
      accounts: accounts,
    ),
    null => null,
  };

  /// What `[[`, `@` and `#` offer in a stash's text, links followed by
  /// [open].
  StashRefs refs(void Function(String href) open) => StashRefs(
    stashes: () => [
      for (final note in store.notes)
        if (note.id != _editing) (id: note.id, title: note.displayTitle),
    ],
    projects: () => [
      for (final project in workspace.projects)
        (name: project.name, path: project.path),
    ],
    open: open,
  );

  // --- In the background --------------------------------------------------------

  void _storeChanged() {
    if (!store.loaded) return;
    unawaited(_readPictures());
  }

  // The text in pictures, read once each (and kept in the cache).

  final Set<String> _reading = {};
  bool _readingPictures = false;

  Future<void> _readPictures() async {
    if (_readingPictures) return;
    _readingPictures = true;
    try {
      var found = true;
      while (found) {
        found = false;
        for (final note in store.notes) {
          for (final src in note.images) {
            if (src.startsWith('http://') || src.startsWith('https://')) {
              continue;
            }
            final path = store.absolute(src);
            if (store.pictureText.containsKey(path) || !_reading.add(path)) {
              continue;
            }
            found = true;
            store.pictureRead(path, await _pictureText(path) ?? '');
          }
        }
      }
    } finally {
      _readingPictures = false;
    }
  }

  Future<String?> _pictureText(String path) async {
    final cache = cacheDir;
    final kept = cache == null
        ? null
        : p.join(cache, 'stash-ocr', '${sha1.convert(utf8.encode(path))}.txt');
    if (kept != null) {
      if (await io.readTextFile(kept) case final text?) return text;
    }
    final text = await host.recognizeText(path);
    if (text != null && kept != null) await io.writeTextFile(kept, text);
    return text;
  }

  // Titles and projects, suggested a little after a stash is written.

  /// What each stash's text was when it was last titled.
  final Map<int, String> _titledAt = {};
  final Map<int, Timer> _suggesting = {};

  void _suggestSoon(int id) {
    _suggesting.remove(id)?.cancel();
    _suggesting[id] = Timer(const Duration(seconds: 3), () {
      _suggesting.remove(id);
      unawaited(suggestFor(id));
    });
  }

  /// A title for [id]'s stash if it has none (or its text changed much
  /// since it was given one by the model), and a project if none was set.
  Future<void> suggestFor(int id) async {
    final note = store.byId(id);
    if (note == null || note.isBlank) return;
    final text = plainText(note.original).trim();
    // Too little to sum up: its first line is its title.
    if (text.runes.length < 24) return;
    final titled = _titledAt[id];
    final stale =
        note.title.isEmpty ||
        (titled != null &&
            (titled.length - text.length).abs() > text.length / 2);
    if (stale) {
      _titledAt[id] = text;
      final title = await stashTitle(note);
      if (title != null) {
        await store.update(id, (note) => note.title = title, touch: false);
      }
    }
    if (note.project == null && note.suggestedProject == null) {
      final projects = [
        for (final project in workspace.projects)
          if (RemoteLocation.hostOf(project.path) == null) project.path,
      ];
      final names = {
        for (final project in workspace.projects) project.path: project.name,
      };
      final suggested = await suggestStashProject(
        note,
        projects,
        (path) => names[path] ?? p.basename(path),
      );
      if (suggested != null) {
        await store.update(
          id,
          (note) => note.suggestedProject = suggested,
          touch: false,
        );
      }
    }
  }

  /// Takes [id]'s suggested project, or turns it down (it is not asked
  /// about again).
  Future<void> answerProject(int id, {required bool accept}) =>
      store.update(id, (note) {
        if (accept) note.project = note.suggestedProject;
        note.suggestedProject = '';
      }, touch: false);

  // Merges, suggested as the stash's page opens (once an hour at most).

  /// Groups of stashes about the same thing, to merge.
  List<List<int>> get mergeSuggestions => [
    for (final group in _merges)
      if (!_dismissedMerges.contains(group.join(',')) &&
          group.every((id) => store.byId(id) != null))
        group,
  ];
  List<List<int>> _merges = const [];
  final Set<String> _dismissedMerges = {};
  DateTime? _mergesAsked;

  void dismissMerge(List<int> group) {
    _dismissedMerges.add(group.join(','));
    notifyListeners();
  }

  Future<void> suggestMerges() async {
    final now = DateTime.now();
    if (_mergesAsked case final asked?
        when now.difference(asked) < const Duration(hours: 1)) {
      return;
    }
    _mergesAsked = now;
    final recent = store.notes
        .where(
          (note) =>
              note.status == StashStatus.collected &&
              !note.isBlank &&
              now.difference(note.updated) < const Duration(days: 30),
        )
        .toList();
    if (recent.length < 2) return;
    final groups = await suggestStashMerges(recent);
    if (groups == null) return;
    _merges = groups;
    notifyListeners();
  }
}
