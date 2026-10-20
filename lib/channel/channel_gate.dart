import 'dart:async';

import 'package:flutter/foundation.dart';

import 'account/channel_account.dart';
import 'channel_setup.dart';

/// Where the channel build is before it can be used.
enum ChannelStage {
  /// Its first start's setup ([ChannelSetup]) not done.
  setup,

  /// Set up: reading what its channel's site lists.
  finding,

  /// The site could not be read, nor was it before.
  offline,

  /// Not a channel the site lists (or not one at all: the user did not
  /// come from one), or one without an account site: not to be used, but
  /// asked of the browser once more ([ChannelGate.confirmAgain]).
  unavailable,

  /// The user is to sign in to the channel's account site.
  signIn,

  /// Signed in.
  ready,
}

/// Reads a channel's entry from the site: null for one not listed; throws
/// when the site could not be read.
typedef ChannelEntryFetch = Future<ChannelEntry?> Function(String id);

/// The channel build's way in: set up ([setup], while it is not), its
/// channel's account site read from the site (kept, for when it cannot be
/// read), and the user signed in there ([account]). Every window shows the
/// welcome till it is [ChannelStage.ready], and again once signed out.
class ChannelGate extends ChangeNotifier {
  ChannelGate({
    required ChannelSetup? setup,
    required this.setupStore,
    required this.accountStore,
    required this.fetch,
    required this.makeAccount,
    this.makeSetupAgain,
  }) : _setup = setup {
    setup?.addListener(_setupChanged);
  }

  /// The app's, in the channel build.
  static ChannelGate? current;

  /// The first start's, while not done; null once it was (another run).
  /// Or the one asking again ([confirmAgain]).
  ChannelSetup? get setup => _setup;
  ChannelSetup? _setup;
  final ChannelSetupStore setupStore;
  final ChannelAccountStore accountStore;
  final ChannelEntryFetch fetch;

  /// The account on [ChannelShown]'s site, not yet loaded.
  final ChannelAccount Function(ChannelShown channel) makeAccount;

  /// A setup to ask the browser once more with ([ChannelSetup.again]).
  final ChannelSetup Function()? makeSetupAgain;

  ChannelShown? _channel;
  ChannelAccount? _account;
  bool _finding = false;
  bool _offline = false;
  bool _found = false;
  bool _asked = false;
  String? _language;

  /// The channel as the site lists it, once read.
  ChannelShown? get channel => _channel;

  /// The account on its site, once there is one.
  ChannelAccount? get account => _account;

  bool get _setUp => _setup?.done ?? setupStore.state == ChannelSetup.doneState;

  ChannelStage get stage {
    if (!_setUp) return ChannelStage.setup;
    if (_account case final account?) {
      return account.signedIn && account.provider != null
          ? ChannelStage.ready
          : ChannelStage.signIn;
    }
    if (_finding || !_found) {
      return _offline ? ChannelStage.offline : ChannelStage.finding;
    }
    return ChannelStage.unavailable;
  }

  bool get ready => stage == ChannelStage.ready;

  void _setupChanged() {
    if (_setUp && _language != null) unawaited(find(_language!));
    notifyListeners();
  }

  /// Reads the channel's entry, in [language] (`zh`, `en`), once set up:
  /// what was kept, at once (done then), then the site's ([fetched]), kept
  /// in its place.
  Future<void> find(String language) async {
    _language = language;
    if (!_setUp || _finding || _asked) return;
    _asked = true;
    final told = setupStore.attribution;
    final id = told?.source == 'channel' ? told?.value : null;
    if (id == null) {
      _found = true;
      notifyListeners();
      return;
    }
    _finding = true;
    _offline = false;
    notifyListeners();
    if (accountStore.entry case final kept? when kept.id == id) {
      await _take(kept, language);
    }
    fetched = _fetch(id, language);
  }

  /// [find] once more: the site not read, or the channel not listed, the
  /// last time.
  Future<void> retry() async {
    if (_finding) return;
    _asked = false;
    await find(_language ?? 'en');
  }

  /// [ChannelStage.unavailable]: asks the browser where the user came from
  /// once more, as the setup did. They might have come by another channel
  /// since, whose download replaces the one before (the site keeps the
  /// latest in their browser). The setup's stage till it answers, then the
  /// channel it says.
  void confirmAgain() {
    final make = makeSetupAgain;
    if (make == null || stage != ChannelStage.unavailable) return;
    _setup?.removeListener(_setupChanged);
    _setup = make()..addListener(_setupChanged);
    _asked = false;
    _found = false;
    notifyListeners();
  }

  /// The site's entry read, after [find]: done once it is (or could not
  /// be).
  Future<void> fetched = Future.value();

  Future<void> _fetch(String id, String language) async {
    try {
      final entry = await fetch(id);
      accountStore.entry = entry;
      if (entry == null) {
        _drop();
      } else {
        await _take(entry, language);
      }
      _found = true;
    } on Object catch (error) {
      debugPrint('Channel $id not read: $error');
      // What was kept, if anything.
      _offline = _channel == null;
      _found = _channel != null;
    } finally {
      _finding = false;
      notifyListeners();
    }
  }

  /// [entry] as the channel; its account, on a site of its own.
  Future<void> _take(ChannelEntry entry, String language) async {
    final info = ChannelInfo.parse(entry.json, language);
    if (info == null) return _drop();
    _channel = (info: info, logo: entry.logo);
    final site = info.account;
    if (site == null) return _dropAccount();
    if (_account?.site.url == site.url && _account?.site.type == site.type) {
      return;
    }
    _dropAccount();
    final account = makeAccount(_channel!);
    _account = account..addListener(notifyListeners);
    ChannelAccount.current = account;
    _found = true;
    notifyListeners();
    await account.load();
  }

  void _drop() {
    _channel = null;
    _dropAccount();
  }

  void _dropAccount() {
    final account = _account;
    if (account == null) return;
    account.removeListener(notifyListeners);
    if (ChannelAccount.current == account) ChannelAccount.current = null;
    _account = null;
  }

  @override
  void dispose() {
    _setup?.removeListener(_setupChanged);
    _dropAccount();
    super.dispose();
  }
}
