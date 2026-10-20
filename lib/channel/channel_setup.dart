import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/user_settings.dart';

/// Where the user came to caocode.dev from, as the site kept it in their
/// browser: a channel's id from the address (`channel`), the site linking
/// there (`referrer`), neither (`direct`); `none` when the browser the
/// setup opened had nothing kept.
@immutable
class ChannelAttribution {
  const ChannelAttribution(this.source, this.value);

  static const sources = ['channel', 'referrer', 'direct', 'none'];

  // Letters of any script, digits, . _ -: a channel's id as the site takes
  // it, or a host.
  static final _value = RegExp(r'^[\p{L}\p{N}._-]{1,128}$', unicode: true);

  final String source;

  /// The channel's id or the site's host, lower case; null for direct and
  /// none.
  final String? value;

  /// [source] and [value] as the server takes them; null when malformed.
  static ChannelAttribution? of(Object? source, Object? value) {
    if (source is! String || !sources.contains(source)) return null;
    if (source == 'channel' || source == 'referrer') {
      if (value is! String || !_value.hasMatch(value)) return null;
      return ChannelAttribution(source, value.toLowerCase());
    }
    if (value != null && value != '') return null;
    return ChannelAttribution(source, null);
  }

  static ChannelAttribution? fromJson(Object? json) => switch (json) {
    {'source': final source, 'value': final value} => of(source, value),
    {'source': final source} => of(source, null),
    _ => null,
  };

  Map<String, Object?> toJson() => {'source': source, 'value': value};

  @override
  bool operator ==(Object other) =>
      other is ChannelAttribution &&
      other.source == source &&
      other.value == value;

  @override
  int get hashCode => Object.hash(source, value);

  @override
  String toString() => value == null ? source : '$source:$value';
}

/// A channel the site lists (site/channels.json), as the app shows it once
/// set up: its name, its logo, the account site it signs in to, and the
/// welcome it may have.
@immutable
class ChannelInfo {
  const ChannelInfo({
    required this.name,
    this.logo,
    this.account,
    this.welcome,
  });

  final String name;

  /// Where the logo is on the site (`/channels/…`), if it has one.
  final String? logo;

  /// The site its users sign in to; without one, the channel build cannot
  /// be used by its users.
  final ChannelAccountSite? account;
  final ChannelWelcome? welcome;

  // As the site takes it (site.js): one of channels/, no way out of it.
  static final _logo = RegExp(r'^/channels/[\w.-]+$');

  /// The channel's entry in channels.json, in [language] (`zh`, `en`; the
  /// English where there is no other); null with no name.
  static ChannelInfo? parse(Object? entry, String language) {
    if (entry is! Map) return null;
    String? text(Object? texts) => switch (texts) {
      final Map<Object?, Object?> texts => switch (texts[language] ??
          texts['en']) {
        final String text when text.trim().isNotEmpty => text.trim(),
        _ => null,
      },
      _ => null,
    };
    final name = text(entry['name']);
    if (name == null) return null;
    return ChannelInfo(
      name: name,
      logo: switch (entry['logo']) {
        final String logo when _logo.hasMatch(logo) => logo,
        _ => null,
      },
      account: ChannelAccountSite.parse(entry['account']),
      welcome: switch (entry['welcome']) {
        final Map<Object?, Object?> welcome => ChannelWelcome.parse(
          welcome,
          text,
        ),
        _ => null,
      },
    );
  }
}

/// A channel as the welcome shows it: what the site lists, and its logo's
/// bytes (SVG or a picture), if it could be had.
typedef ChannelShown = ({ChannelInfo info, Uint8List? logo});

/// A channel's entry in channels.json as read (its logo's bytes with it):
/// kept, for when the site cannot be reached.
typedef ChannelEntry = ({String id, Object? json, Uint8List? logo});

/// The panels a channel's account site can run.
enum ChannelAccountType {
  /// new-api (github.com/QuantumNous/new-api), as of v1.0.
  newApi('newapi'),

  /// sub2api (github.com/Wei-Shaw/sub2api).
  sub2api('sub2api');

  const ChannelAccountType(this.id);

  /// As channels.json has it.
  final String id;
}

/// The site a channel's users sign in to (channels.json's `account`): its
/// panel, [url], where they sign in and their keys are; and where the
/// keys' models are served, [apiUrl], the panel's unless it says, and how
/// ([protocol]: `anthropic`, `openai-chat`, `openai-responses`), the
/// key's group's way where the panel tells (sub2api), else Anthropic's.
@immutable
class ChannelAccountSite {
  const ChannelAccountSite({
    required this.type,
    required this.url,
    Uri? apiUrl,
    this.protocol,
  }) : apiUrl = apiUrl ?? url;

  final ChannelAccountType type;

  /// HTTPS, its origin only.
  final Uri url;
  final Uri apiUrl;

  /// As channels.json has it; null to go by the key.
  final String? protocol;

  static const protocols = ['anthropic', 'openai-chat', 'openai-responses'];

  static ChannelAccountSite? parse(Object? json) {
    if (json is! Map) return null;
    final type = ChannelAccountType.values
        .where((type) => type.id == json['type'])
        .firstOrNull;
    Uri? https(Object? value) => switch (value) {
      final String text => switch (Uri.tryParse(text.trim())) {
        final Uri uri when uri.scheme == 'https' && uri.host.isNotEmpty => uri,
        _ => null,
      },
      _ => null,
    };
    final url = https(json['url']);
    if (type == null || url == null) return null;
    final protocol = json['protocol'];
    return ChannelAccountSite(
      type: type,
      url: Uri(scheme: url.scheme, host: url.host, port: url.port),
      apiUrl: https(json['apiUrl']),
      protocol: protocols.contains(protocol) ? protocol as String : null,
    );
  }
}

/// The words a channel's welcome says once set up (channels.json's
/// `welcome`): a title, a text, and its button's label, Sign In unless it
/// says otherwise.
@immutable
class ChannelWelcome {
  const ChannelWelcome({required this.title, required this.text, this.button});

  final String title;
  final String text;

  /// The button's label; null for Sign In.
  final String? button;

  static ChannelWelcome? parse(
    Map<Object?, Object?> welcome,
    String? Function(Object? texts) text,
  ) {
    final title = text(welcome['title']);
    final body = text(welcome['text']);
    if (title == null || body == null) return null;
    return ChannelWelcome(
      title: title,
      text: body,
      button: text(welcome['button']),
    );
  }
}

/// What the setup keeps across runs (the app's global storage).
abstract interface class ChannelSetupStore {
  /// `pending` from the channel build's first start, `done` once set up;
  /// null for another build's install.
  String? get state;
  set state(String? state);

  /// Where the user came from, once set up.
  ChannelAttribution? get attribution;
  set attribution(ChannelAttribution? attribution);
}

/// Kept for the run only (under test).
class MemoryChannelSetupStore implements ChannelSetupStore {
  @override
  String? state;

  @override
  ChannelAttribution? attribution;
}

/// In the app's global storage (state/storage.json); what was set read
/// back as set, the file written after.
class GlobalChannelSetupStore implements ChannelSetupStore {
  GlobalChannelSetupStore(this.storage);

  final GlobalStorage storage;

  static const stateKey = 'channel.setup';
  static const attributionKey = 'channel.attribution';

  String? _state;
  ChannelAttribution? _attribution;

  @override
  String? get state => _state ?? storage.get<String>(stateKey);

  @override
  set state(String? state) => _set(stateKey, _state = state);

  @override
  ChannelAttribution? get attribution =>
      _attribution ??
      ChannelAttribution.fromJson(storage.get<Object>(attributionKey));

  @override
  set attribution(ChannelAttribution? attribution) =>
      _set(attributionKey, (_attribution = attribution)?.toJson());

  void _set(String key, Object? value) => unawaited(
    storage.set(key, value).catchError((Object error) {
      debugPrint('$key not kept: $error');
    }),
  );
}

/// What the stats server kept for an install ([ChannelSetup.lookUpUrl]):
/// null while it has none. Throws when it could not be asked (offline).
typedef ChannelLookUp = Future<ChannelAttribution?> Function(Uri url);

/// What a pasted or opened `caocode://activate` link came to.
enum ChannelLinkResult {
  accepted,

  /// Not such a link, or not one the page made.
  invalid,

  /// Made for another install (another computer's, a reinstall's).
  otherInstall,
}

/// The channel build's first start: one build for every channel, which
/// asks where its user came from of the browser they downloaded it in. It
/// opens caocode.dev/activate with the install's id; the page sends the
/// stats server what the site kept in that browser, and the app, asking
/// there, is set up. Should the app not hear of it, the page hands it a
/// `caocode://activate?…` link, opened or pasted.
///
/// It cannot be put off: the welcome stays till it is done. Pending is
/// kept, so that a quit, or an update to another build, does not skip it;
/// done, it never shows again. [current] is null for another build, and
/// once done.
class ChannelSetup extends ChangeNotifier {
  ChannelSetup({
    required this.store,
    required this.installId,
    required this.lookUp,
    required this.open,
    this.again,
    this.pollInterval = const Duration(seconds: 3),
    this.offlineAfter = 2,
  }) : _done = again == null && store.state == doneState;

  /// Made with `--dart-define=CAOCODE_CHANNEL=true`: the build the site
  /// gives a visitor who came by a channel.
  static const channelBuild = bool.fromEnvironment('CAOCODE_CHANNEL');

  static const pendingState = 'pending';
  static const doneState = 'done';

  static const pageUrl = 'https://caocode.dev/activate';
  static const zhPageUrl = 'https://caocode.dev/zh/activate';
  static const lookUpBase = 'https://stats.caocode.dev/v1/attribution/';

  /// The app's, while it is to be set up (main.dart sets it).
  static ChannelSetup? current;

  /// Pending from the channel build's first start ([channelBuild]), and
  /// till done: what the app reports as its edition (the stats tell the
  /// builds apart), `channel` for good once it was.
  static String editionOf(ChannelSetupStore store) =>
      store.state == null ? 'standard' : 'channel';

  /// Marks the channel build's first start pending; whether there is a
  /// setup to do.
  static bool begin(ChannelSetupStore store, {bool build = channelBuild}) {
    if (build && store.state == null) store.state = pendingState;
    return store.state == pendingState;
  }

  final ChannelSetupStore store;

  /// The install's id, the telemetry's (made here if it has none yet).
  final String installId;
  final ChannelLookUp lookUp;

  /// Set up once already, asking the browser once more ([ChannelGate.
  /// confirmAgain]): the id made for the asking, which the page's answer
  /// comes with, and replaces what was kept (an answer without it, the
  /// one before, not taken).
  final String? again;

  /// Opens a page in the user's browser.
  final Future<bool> Function(Uri url) open;

  /// Between the questions to the stats server while the page is open.
  final Duration pollInterval;

  /// The questions in a row not getting through before [offline].
  final int offlineAfter;

  bool _done;
  bool _opened = false;
  bool _offline = false;
  int _failures = 0;
  Timer? _poll;
  bool _asking = false;
  bool _disposed = false;

  bool get done => _done;

  /// Whether the page was opened: the app waits for it.
  bool get waiting => _opened && !_done;

  /// Whether the stats server could not be reached, lately: the network.
  bool get offline => _offline && !_done;

  /// Where the user came from, once [done].
  ChannelAttribution? get attribution => store.attribution;

  /// Once [done] and its welcome closed ([start]): what comes after it
  /// (the welcome to setting a model up) waits for this.
  Future<void> get started => _started.future;
  final _started = Completer<void>();

  /// Get Started, once [done].
  void start() {
    if (_done && !_started.isCompleted) _started.complete();
  }

  Uri get lookUpUrl =>
      Uri.parse('$lookUpBase$installId${again == null ? '' : '?again=$again'}');

  /// The page, in Chinese for a Chinese app (its English one sends a
  /// Chinese browser there too).
  Uri page({required bool zh}) => Uri.parse(
    '${zh ? zhPageUrl : pageUrl}#i=$installId'
    '${again == null ? '' : '&again=$again'}',
  );

  /// Asked once as the welcome shows: done already, in a run before
  /// (quit while the page sent it).
  Future<void> check() => _ask();

  /// Opens the page in the user's browser, and waits for it: asking the
  /// stats server every [pollInterval]. Again, the page again.
  Future<void> openPage({required bool zh}) async {
    if (_done) return;
    _opened = true;
    _failures = 0;
    _offline = false;
    _notify();
    _poll ??= Timer.periodic(pollInterval, (_) => unawaited(_ask()));
    final opened = await open(page(zh: zh));
    if (!opened) debugPrint('channel setup: the page did not open');
  }

  Future<void> _ask() async {
    if (_done || _asking || _disposed) return;
    _asking = true;
    try {
      final told = await lookUp(lookUpUrl);
      _failures = 0;
      _offline = false;
      if (told != null) {
        _finish(told);
      } else {
        _notify();
      }
    } on Object catch (error) {
      debugPrint('channel setup: not asked: $error');
      _failures++;
      if (_opened && _failures >= offlineAfter && !_offline) {
        _offline = true;
        _notify();
      }
    } finally {
      _asking = false;
    }
  }

  /// Whether [link] is the page's (`caocode://activate…`), not another
  /// `caocode://` link.
  static bool isLink(String link) => switch (Uri.tryParse(link.trim())) {
    Uri(scheme: 'caocode', host: 'activate') => true,
    _ => false,
  };

  /// A `caocode://activate?i=…&s=…&c=…` link, as the page hands it over
  /// (opened, or pasted): set up with what it says, which the telemetry
  /// reports (the server might not have heard of it).
  ChannelLinkResult acceptLink(String link) {
    if (!isLink(link)) return ChannelLinkResult.invalid;
    final query = Uri.parse(link.trim()).queryParameters;
    final told = ChannelAttribution.of(query['s'], query['c']);
    if (told == null) return ChannelLinkResult.invalid;
    if (query['i'] != installId) return ChannelLinkResult.otherInstall;
    if (!_done) _finish(told);
    return ChannelLinkResult.accepted;
  }

  void _finish(ChannelAttribution told) {
    _done = true;
    _poll?.cancel();
    _poll = null;
    store
      ..attribution = told
      ..state = doneState;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }
}
