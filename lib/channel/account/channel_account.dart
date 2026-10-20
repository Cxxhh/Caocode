import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/model_provider.dart';
import '../../models/model_providers.dart';
import '../../models/secret_store.dart';
import '../../models/upstream.dart';
import '../../settings/user_settings.dart';
import '../channel_setup.dart';
import 'account_api.dart';
import 'login_window.dart';
import 'newapi_adapter.dart';
import 'sub2api_adapter.dart';

/// Lists the models a key reaches, as Settings → Models does.
typedef AccountModelLister = Future<List<RemoteModel>> Function(
  ModelProvider provider,
  String? key,
);

/// Where the channel build keeps the account: the session in the
/// keychain, the rest (whose account, the key in use) where it likes.
abstract interface class ChannelAccountStore {
  Future<String?> readCredential();

  /// Null forgets it.
  Future<void> writeCredential(String? credential);

  /// What [ChannelAccount] keeps besides: null when nothing.
  Map<String, Object?>? get state;
  set state(Map<String, Object?>? state);

  ChannelEntry? get entry;
  set entry(ChannelEntry? entry);
}

/// Kept for the run only (under test).
class MemoryChannelAccountStore implements ChannelAccountStore {
  String? credential;

  @override
  Map<String, Object?>? state;

  @override
  ChannelEntry? entry;

  @override
  Future<String?> readCredential() async => credential;

  @override
  Future<void> writeCredential(String? credential) async =>
      this.credential = credential;
}

/// The session in [secrets] (the system's keychain), the rest in the app's
/// global storage.
class GlobalChannelAccountStore implements ChannelAccountStore {
  GlobalChannelAccountStore(this.storage, {this._secrets});

  final GlobalStorage storage;
  final SecretStore? _secrets;

  SecretStore get secrets => _secrets ?? SecretStore.instance;

  static const credentialId = 'channel.account.session';
  static const stateKey = 'channel.account';
  static const entryKey = 'channel.entry';

  @override
  Future<String?> readCredential() async {
    try {
      return await secrets.read(credentialId);
    } on SecretStoreException catch (error) {
      debugPrint('Channel session not read: $error');
      return null;
    }
  }

  @override
  Future<void> writeCredential(String? credential) async {
    try {
      if (credential == null) {
        await secrets.delete(credentialId);
      } else {
        await secrets.write(credentialId, credential);
      }
    } on SecretStoreException catch (error) {
      debugPrint('Channel session not kept: $error');
    }
  }

  @override
  Map<String, Object?>? get state => switch (storage.get<Object>(stateKey)) {
    final Map<String, Object?> state => state,
    _ => null,
  };

  @override
  set state(Map<String, Object?>? state) => _set(stateKey, state);

  @override
  ChannelEntry? get entry => switch (storage.get<Object>(entryKey)) {
    {'id': final String id, 'json': final Object? json} && final Map entry => (
      id: id,
      json: json,
      logo: switch (entry['logo']) {
        final String logo => _bytes(logo),
        _ => null,
      },
    ),
    _ => null,
  };

  static Uint8List? _bytes(String base64) {
    try {
      return base64Decode(base64);
    } on FormatException {
      return null;
    }
  }

  @override
  set entry(ChannelEntry? entry) => _set(
    entryKey,
    entry == null
        ? null
        : {
            'id': entry.id,
            'json': entry.json,
            if (entry.logo case final logo?) 'logo': base64Encode(logo),
          },
  );

  void _set(String key, Object? value) => unawaited(
    storage.set(key, value).catchError((Object error) {
      debugPrint('$key not kept: $error');
    }),
  );
}

/// Opens a login window of its own.
typedef LoginWindowOpener = LoginWindow Function();

/// The channel build's account: the user signed in to their channel's
/// site ([site]), their keys there, and the one in use, kept as the app's
/// only upstream ([providerId]).
class ChannelAccount extends ChangeNotifier {
  ChannelAccount({
    required this.site,
    required this.channelName,
    required this.store,
    required this.send,
    required this.listModels,
    ModelProviders Function()? providers,
    LoginWindowOpener? openWindow,
    this.pollInterval = const Duration(seconds: 1),
  }) : _providers = providers ?? (() => ModelProviders.current),
       _openWindow = openWindow ?? ChannelLoginWindow.new;

  /// The app's, once the channel build knows its channel's site.
  static ChannelAccount? current;

  /// The upstream the key in use is kept as.
  static const providerId = 'channel';

  /// The key made for the user when they have none.
  static const keyName = 'Caocode';

  final ChannelAccountSite site;

  /// The channel's, as the upstream's name.
  final String channelName;
  final ChannelAccountStore store;
  final AccountSend send;
  final AccountModelLister listModels;
  final ModelProviders Function() _providers;
  final LoginWindowOpener _openWindow;

  /// How often the login window is asked whether the user has signed in.
  final Duration pollInterval;

  late final AccountAdapter _adapter = switch (site.type) {
    ChannelAccountType.newApi => NewApiAdapter(
      site: site,
      send: send,
      credential: null,
      onCredential: _keepCredential,
    ),
    ChannelAccountType.sub2api => Sub2ApiAdapter(
      site: site,
      send: send,
      credential: null,
      onCredential: _keepCredential,
    ),
  };

  ModelProviders get providers => _providers();

  bool _loaded = false;
  AccountProfile? _profile;
  List<AccountKey>? _keys;
  AccountKey? _inUse;
  bool _busy = false;
  bool _signingIn = false;
  Object? _error;

  /// Signed in: a session kept.
  bool get signedIn => _adapter.credential != null;

  /// As last read (kept between runs).
  AccountProfile? get profile => _profile;

  /// As last read this run; null till then.
  List<AccountKey>? get keys => _keys;

  /// The key the app calls the models with.
  AccountKey? get inUse => _inUse;

  /// Reading or changing something on the site.
  bool get busy => _busy;

  /// The login window is open.
  bool get signingIn => _signingIn;

  /// What last went wrong, till something goes right.
  Object? get error => _error;

  /// The upstream the key in use is kept as, if it is.
  ModelProvider? get provider => providers.provider(providerId);

  /// What was kept: the session and whose it is. Once.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final state = store.state;
    // Another site's (the channel's moved): not this one's to use.
    if (state != null && state['site'] != '${site.url}') {
      store.state = null;
      await store.writeCredential(null);
      notifyListeners();
      return;
    }
    _adapter.credential = await store.readCredential();
    if (state != null) {
      _profile = AccountProfile.fromJson(state['profile']);
      _inUse = _keyFromJson(state['key']);
    }
    notifyListeners();
  }

  void _keepCredential(String? credential) {
    unawaited(store.writeCredential(credential));
    if (credential == null) _signedOut();
  }

  /// Forgets all but the site: signed out (here, or by it).
  void _signedOut() {
    _profile = null;
    _keys = null;
    _inUse = null;
    store.state = null;
    notifyListeners();
  }

  void _save() {
    store.state = {
      'site': '${site.url}',
      'profile': ?_profile?.toJson(),
      'key': ?_keyToJson(_inUse),
    };
  }

  static Map<String, Object?>? _keyToJson(AccountKey? key) => key == null
      ? null
      : {
          'id': key.id,
          'name': key.name,
          'masked': key.masked,
          'platform': key.platform,
        };

  static AccountKey? _keyFromJson(Object? json) => switch (json) {
    {
      'id': final String id,
      'name': final String name,
      'masked': final String masked,
    } =>
      AccountKey(
        id: id,
        name: name,
        masked: masked,
        platform: json['platform'] as String?,
      ),
    _ => null,
  };

  /// Opens the login window on the site and waits for the user to sign in
  /// there (or close it): whether they did. Once signed in, their account
  /// is read, and a key put to use: the one in use before, else their
  /// first, else one made for them.
  Future<bool> signIn({required String title}) async {
    if (_signingIn) return false;
    _signingIn = true;
    _error = null;
    notifyListeners();
    final window = _openWindow();
    try {
      await window.open(_adapter.loginUrl, title: title);
      var closed = false;
      unawaited(window.closed.then((_) => closed = true));
      String? credential;
      while (!closed && credential == null) {
        await Future.any([Future<void>.delayed(pollInterval), window.closed]);
        if (closed) break;
        try {
          credential = await _adapter.signedIn(window);
        } on Object {
          // A page between two, say: asked again in a moment.
        }
      }
      if (credential == null) return false;
      unawaited(window.close().catchError((Object _) {}));
      _adapter.renewed(credential);
      _save();
      await settle();
      return signedIn;
    } on Object catch (error) {
      _error = error;
      unawaited(window.close().catchError((Object _) {}));
      return false;
    } finally {
      _signingIn = false;
      notifyListeners();
    }
  }

  /// The account read, and a key in use: the one before if it is still
  /// there, else the first, else one made.
  Future<void> settle() async {
    await refresh();
    if (!signedIn) return;
    final keys = _keys ?? const [];
    final kept = keys.where((key) => key.id == _inUse?.id).firstOrNull;
    if (kept != null && provider != null) return;
    final key = kept ?? keys.firstOrNull ?? await create(keyName);
    if (key != null) await use(key);
  }

  /// Reads the account and its keys again.
  Future<void> refresh() => _run(() async {
    final profile = await _adapter.profile();
    final keys = await _adapter.keys();
    _profile = profile;
    _keys = keys;
    if (_inUse case final inUse?) {
      _inUse = keys.where((key) => key.id == inUse.id).firstOrNull ?? inUse;
    }
    _save();
  });

  /// The groups a key may be made in; none when they could not be read
  /// (what went wrong kept, as [error]).
  Future<List<AccountGroup>> groups() async {
    try {
      return await _adapter.groups();
    } on AccountSignedOut {
      return const [];
    } on Object catch (error) {
      _error = error;
      notifyListeners();
      return const [];
    }
  }

  /// Makes a key named [name], in [group] (one the site picks, without):
  /// the one made; null when it could not be.
  Future<AccountKey?> create(String name, {AccountGroup? group}) async {
    AccountKey? made;
    await _run(() async {
      made = await _adapter.create(name, group: group);
      _keys = await _adapter.keys();
    });
    return made;
  }

  /// Calls the models with [key]: kept as the app's upstream, the models
  /// it reaches listed, new conversations' model one of them.
  Future<void> use(AccountKey key) => _run(() async {
    final providers = this.providers;
    final whole = await _adapter.reveal(key);
    final protocol = _adapter.protocolFor(key);
    final before = provider;
    var upstream = (before ?? ModelProvider(id: providerId, name: channelName))
        .copyWith(
          name: channelName,
          protocol: protocol,
          baseUrl: '${site.apiUrl}',
          enabled: true,
        );
    final listed = await listModels(upstream, whole);
    upstream = upstream.copyWith(
      models: mergeModelList(
        before?.protocol == protocol ? before!.models : const [],
        listed,
        enable: {
          for (final model in listed)
            if (!(model.kind ?? guessModelKind(model.id)).generatesImages)
              model.id,
        },
      ),
    );
    final main = _defaultOf(upstream, providers.defaultModel);
    if (main != null) {
      upstream = upstream.copyWith(
        roles: upstream.roles.copyWith('main', main),
      );
    }
    await providers.setKey(providerId, whole);
    await providers.save(upstream);
    // The channel's models only, not Claude Code's as set up here.
    if (!providers.builtinHidden) await providers.setBuiltinHidden(true);
    if (main != null && parseModelRef(providers.defaultModel)?.model != main) {
      await providers.setDefaultModel(modelRef(providerId, main));
    }
    _inUse = key;
    _save();
  });

  /// New conversations' model of [upstream]'s: the one before if it still
  /// has it, else a Sonnet, else a Claude, else its first.
  static String? _defaultOf(ModelProvider upstream, String? before) {
    final models = upstream.enabledModels;
    if (models.isEmpty) return null;
    final kept = parseModelRef(before);
    if (kept != null &&
        kept.provider == providerId &&
        models.any((model) => model.id == kept.model)) {
      return kept.model;
    }
    bool named(ProviderModel model, String word) =>
        model.id.toLowerCase().contains(word);
    return (models.where((m) => named(m, 'sonnet')).firstOrNull ??
            models.where((m) => named(m, 'claude')).firstOrNull ??
            models.first)
        .id;
  }

  /// The models the key in use reaches.
  List<ProviderModel> get models => provider?.enabledModels ?? const [];

  /// New conversations' model, of [models].
  String? get defaultModel => switch (parseModelRef(providers.defaultModel)) {
    (provider: providerId, :final model) => model,
    _ => null,
  };

  Future<void> setDefaultModel(String model) async {
    await providers.setDefaultModel(modelRef(providerId, model));
    if (provider case final upstream?) {
      await providers.save(
        upstream.copyWith(roles: upstream.roles.copyWith('main', model)),
      );
    }
    notifyListeners();
  }

  /// Signs out, on the site too: the key in use no longer called.
  Future<void> signOut() async {
    _busy = true;
    notifyListeners();
    try {
      await _adapter.signOut();
      await providers.remove(providerId);
    } finally {
      _busy = false;
      _signedOut();
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    _busy = true;
    notifyListeners();
    try {
      await work();
      _error = null;
    } on AccountSignedOut {
      // Forgotten by [AccountAdapter.forget] already.
      _error = null;
    } on Object catch (error) {
      _error = error;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }
}
