import 'dart:async';

import 'package:flutter/foundation.dart';

import '../forge/forge_accounts.dart';
import '../forge/forge_api.dart';
import '../forge/forge_io_stub.dart'
    if (dart.library.io) '../forge/forge_io.dart'
    as io;
import '../forge/forge_ref.dart';
import '../remote/remote_location.dart';
import '../workspace/workspace.dart';
import 'stash_note.dart';
import 'stash_store.dart';

/// The stashes' issues and pull requests (docs/stash.md): linked from
/// their text (a link pasted, an issue imported) and from their
/// conversations (see StashThreads); how each is now, asked of its forge
/// as the user (see [ForgeAccounts]) and kept with the link for when it
/// cannot be; what that asks of the user (an issue closed: is the stash
/// done? the stash done: say so on the issue?); and what the user then
/// writes there, only once they confirm it.
class StashForge extends ChangeNotifier {
  StashForge({
    required this.store,
    required this.workspace,
    required this.accounts,
    DateTime Function()? clock,
    Future<List<String>> Function(String folder)? remotes,
  }) : _clock = clock ?? DateTime.now,
       _remotes = remotes ?? io.gitRemoteUrls;

  /// The app's, once main() has made it.
  static StashForge? current;

  final StashStore store;
  final Workspace workspace;
  final ForgeAccounts accounts;
  final DateTime Function() _clock;
  final Future<List<String>> Function(String folder) _remotes;

  bool _started = false;
  bool _disposed = false;
  Timer? _timer;

  /// How often what is linked is asked again while the app runs.
  static const refreshEvery = Duration(minutes: 5);

  /// How long an answer is taken as current.
  static const fresh = Duration(seconds: 60);

  void start() {
    if (_started) return;
    _started = true;
    store.addListener(_storeChanged);
    accounts.addListener(_accountsChanged);
    _timer = Timer.periodic(refreshEvery, (_) => unawaited(refresh()));
    _storeChanged();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_started) {
      store.removeListener(_storeChanged);
      accounts.removeListener(_accountsChanged);
    }
    super.dispose();
  }

  /// [url]'s issue or pull request, if it is one (on a host known).
  ForgeRef? refOf(String url) => ForgeRef.parse(url, kindOf: accounts.kindOf);

  /// [url]'s issue or pull request as last asked this run; null before.
  ForgeItem? itemOf(String url) => _items[url];
  final Map<String, ForgeItem> _items = {};

  /// Why [url] could not be asked last time, if it could not.
  ForgeException? failureOf(String url) => _failures[url];
  final Map<String, ForgeException> _failures = {};

  /// When each link was last asked.
  final Map<String, DateTime> _asked = {};

  /// Whether [url]'s forge has an account to ask it with.
  bool canAsk(String url) => switch (refOf(url)) {
    final ref? => accounts.apiOf(ref) != null,
    null => false,
  };

  // --- Linked from the text ------------------------------------------------------

  bool _collecting = false;

  void _storeChanged() {
    if (_disposed || !store.loaded || _collecting) return;
    unawaited(_collect());
  }

  void _accountsChanged() {
    _failures.clear();
    _asked.clear();
    notifyListeners();
    unawaited(_collect());
  }

  /// Links each stash to the issues and pull requests its text links to,
  /// then asks those not asked lately.
  Future<void> _collect() async {
    _collecting = true;
    try {
      final adding = <int, List<String>>{};
      for (final note in store.notes) {
        for (final ref in ForgeRef.allIn(note.body, kindOf: accounts.kindOf)) {
          final url = ref.url.toString();
          if (note.issueOf(url) == null) (adding[note.id] ??= []).add(url);
        }
      }
      if (adding.isNotEmpty) {
        // What an agent wrote meanwhile, read before it is written over.
        await store.reload();
        for (final MapEntry(key: id, value: urls) in adding.entries) {
          final note = store.byId(id);
          if (note == null) continue;
          for (final url in urls) {
            if (note.issueOf(url) == null) {
              note.issues.add(StashIssueLink(url: url));
            }
          }
          await store.save(note, touch: false);
        }
      }
    } finally {
      _collecting = false;
    }
    await refresh();
  }

  // --- How they are now ----------------------------------------------------------

  Future<void>? _refreshing;

  /// Asks the forges how the linked issues and pull requests are now: of
  /// stashes not done, and of those done that are still open (to ask the
  /// user about them); each at most once in [fresh] unless [force]d.
  Future<void> refresh({bool force = false}) => force
      ? _refresh(true)
      : _refreshing ??= _refresh(false).whenComplete(() => _refreshing = null);

  /// Asks [id]'s stash's again, now (shown, it should be current).
  Future<void> refreshNote(int id) async {
    final note = store.byId(id);
    if (note == null) return;
    await _ask([for (final link in note.issues) link.url], force: false);
  }

  Future<void> _refresh(bool force) => _ask([
    for (final note in store.notes)
      for (final link in note.issues)
        if (note.status != StashStatus.done ||
            !link.answered &&
                (link.state != 'closed' && link.state != 'merged'))
          link.url,
  ], force: force);

  Future<void> _ask(List<String> urls, {required bool force}) async {
    final now = _clock();
    final asking = {
      for (final url in urls)
        if (force || !(_asked[url]?.isAfter(now.subtract(fresh)) ?? false)) url,
    };
    final answers = <String, ForgeItem>{};
    await Future.wait([
      for (final url in asking)
        if (refOf(url) case final ref?)
          if (accounts.apiOf(ref) case final api?)
            api
                .item(ref)
                .then((item) {
                  answers[url] = item;
                  _failures.remove(url);
                })
                .catchError((Object error) {
                  _failures[url] = error is ForgeException
                      ? error
                      : ForgeException('$error');
                })
                .whenComplete(() => _asked[url] = now),
    ]);
    if (_disposed) return;
    _items.addAll(answers);
    notifyListeners();
    await _keep(answers);
  }

  /// Keeps what [answers] say with the links (their title, state and
  /// checks), for when they cannot be asked.
  Future<void> _keep(Map<String, ForgeItem> answers) async {
    if (answers.isEmpty) return;
    bool differs(StashIssueLink link, ForgeItem item) =>
        link.title != item.title ||
        link.state != item.state.name ||
        link.checks != item.checks?.name;
    if (!store.notes.any(
      (note) => note.issues.any(
        (link) => switch (answers[link.url]) {
          final item? => differs(link, item),
          null => false,
        },
      ),
    )) {
      return;
    }
    await store.reload();
    for (final note in store.notes) {
      var changed = false;
      for (final (i, link) in note.issues.indexed) {
        final item = answers[link.url];
        if (item == null || !differs(link, item)) continue;
        note.issues[i] = StashIssueLink(
          url: link.url,
          title: item.title,
          state: item.state.name,
          checks: item.checks?.name,
          session: link.session,
          // A state that changed asks anew.
          answered: link.state == item.state.name && link.answered,
        );
        changed = true;
      }
      if (changed) await store.save(note, touch: false);
    }
  }

  /// [link]'s state: as just asked, else as kept.
  ForgeState? stateOf(StashIssueLink link) =>
      _items[link.url]?.state ?? ForgeState.parse(link.state);

  // --- What they ask of the user -------------------------------------------------

  /// [note]'s issues closed while it is not done: is it?
  List<StashIssueLink> closedIssues(StashNote note) => [
    if (note.status != StashStatus.done)
      for (final link in note.issues)
        if (!link.answered &&
            refOf(link.url)?.kind == ForgeItemKind.issue &&
            stateOf(link) == ForgeState.closed)
          link,
  ];

  /// [note]'s issues still open though it is done: say so there?
  List<StashIssueLink> openIssues(StashNote note) => [
    if (note.status == StashStatus.done)
      for (final link in note.issues)
        if (!link.answered &&
            refOf(link.url)?.kind == ForgeItemKind.issue &&
            (stateOf(link)?.isOpen ?? false) &&
            canAsk(link.url))
          link,
  ];

  /// What [links] of [id]'s stash asked was answered (or set aside).
  Future<void> answer(int id, Iterable<String> links) async {
    final urls = links.toSet();
    await store.reload();
    await store.update(id, (note) {
      for (final (i, link) in note.issues.indexed) {
        if (urls.contains(link.url)) {
          note.issues[i] = link.copyWith(answered: true);
        }
      }
    }, touch: false);
  }

  /// Unlinks [url] from [id]'s stash (its link in the text stays, and
  /// would link it again: taken out of the text too).
  Future<void> unlink(int id, String url) async {
    await store.reload();
    await store.update(id, (note) {
      note.issues.removeWhere((link) => link.url == url);
    }, touch: false);
  }

  // --- Written there, once confirmed ---------------------------------------------

  /// Comments [text] on [url]'s issue or pull request (when not empty),
  /// then closes it when [close] (an issue); as the user, who confirmed
  /// it. Throws [ForgeException].
  Future<void> write(
    int id,
    String url, {
    String text = '',
    bool close = false,
  }) async {
    final ref = refOf(url);
    final api = ref == null ? null : accounts.apiOf(ref);
    if (ref == null || api == null) {
      throw const ForgeException('Not signed in.', status: 401);
    }
    if (text.trim().isNotEmpty) await api.comment(ref, text.trim());
    if (close && ref.kind == ForgeItemKind.issue) await api.close(ref);
    // As it is now first: a state changed asks anew, but this one the user
    // just answered.
    await _ask([url], force: true);
    await answer(id, [url]);
  }

  /// What should not go out in [text] before the user says so: paths on
  /// this machine, and what looks like a secret (an API key, a token, a
  /// private key).
  static List<String> sensitive(String text) => [
    for (final pattern in _sensitive)
      for (final match in pattern.allMatches(text)) match[0]!,
  ];

  static final _sensitive = [
    RegExp(
      r'(?:/Users|/home)/[^\s`"'
      ')]+',
    ),
    RegExp(
      r'[A-Za-z]:\\Users\\[^\s`"'
      ')]+',
    ),
    RegExp(r'\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}'),
    RegExp(r'\b(?:ghp|gho|ghu|ghs|ghr|github_pat|glpat)[-_][A-Za-z0-9_]{16,}'),
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
  ];

  // --- Imported ------------------------------------------------------------------

  /// The repositories the projects are of (by their Git remotes, on hosts
  /// known), each with its project; those with an account first.
  Future<List<({ForgeRepo repo, Project project})>> repositories() async {
    final found = <ForgeRepo, Project>{};
    for (final project in workspace.projects) {
      if (RemoteLocation.isRemote(project.path)) continue;
      for (final remote in await _remotes(project.path)) {
        final repo = ForgeRepo.fromRemote(remote, kindOf: accounts.kindOf);
        if (repo != null) found.putIfAbsent(repo, () => project);
      }
    }
    final list = [
      for (final MapEntry(key: repo, value: project) in found.entries)
        (repo: repo, project: project),
    ];
    list.sort((a, b) {
      final signed =
          (accounts.accountFor(b.repo.host) != null ? 1 : 0) -
          (accounts.accountFor(a.repo.host) != null ? 1 : 0);
      return signed != 0 ? signed : a.repo.path.compareTo(b.repo.path);
    });
    return list;
  }

  /// The stash [url]'s issue is in, if one is.
  StashNote? stashOf(String url) {
    for (final note in store.notes) {
      if (note.issueOf(url) != null) return note;
    }
    return null;
  }

  /// A stash for each of [items] not in one yet, about [project]: its
  /// title the issue's, its text a card of it and its description. The
  /// stashes, those already there among them.
  Future<List<StashNote>> import(
    List<ForgeItem> items, {
    String? project,
  }) async {
    final notes = <StashNote>[];
    for (final item in items) {
      final url = item.ref.url.toString();
      if (stashOf(url) case final known?) {
        notes.add(known);
        continue;
      }
      final body = [
        '[${_escape(item.ref.fullTag)} ${_escape(item.title)}]($url "card")',
        if (item.body.trim().isNotEmpty) item.body.trim(),
      ].join('\n\n');
      final note = await store.create(body: body, project: project);
      await store.update(note.id, (note) {
        note.title = item.title;
        note.issues.add(
          StashIssueLink(url: url, title: item.title, state: item.state.name),
        );
      }, touch: false);
      _items[url] = item;
      _asked[url] = _clock();
      notes.add(store.byId(note.id)!);
    }
    notifyListeners();
    return notes;
  }

  static String _escape(String text) =>
      text.replaceAll('[', r'\[').replaceAll(']', r'\]');
}
