import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'featured_upstreams_stub.dart'
    if (dart.library.io) 'featured_upstreams_io.dart';

/// An upstream Settings → Models shows a card of, free of charge, for
/// adding the one-click import (see docs/upstream-import.md): listed in
/// site/featured/upstreams.json, by a pull request after its issue, and
/// read from caocode.dev ([feed]): shown as soon as the site is deployed,
/// with no release of the app.
@immutable
class FeaturedUpstream {
  const FeaturedUpstream({
    required this.id,
    required this.name,
    required this.url,
    this.logo,
    this.description = const {},
    this.hosts = const [],
  });

  /// Null for an entry without an id, a name or an http(s) [url]. Its
  /// logo, a file's name beside the list, is in [logoDirectory].
  static FeaturedUpstream? fromJson(Object? json, {String logoDirectory = ''}) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final url = Uri.tryParse('${json['url']}');
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    if (url == null || !(url.isScheme('https') || url.isScheme('http'))) {
      return null;
    }
    return FeaturedUpstream(
      id: id,
      name: name,
      url: url,
      logo: switch (json['logo']) {
        final String logo when isLogoName(logo) => '$logoDirectory/$logo',
        _ => null,
      },
      description: {
        if (json['description'] case final Map map)
          for (final MapEntry(:key, :value) in map.entries)
            if (key is String && value is String) key: value,
      },
      hosts: [
        if (json['hosts'] case final List hosts)
          for (final host in hosts)
            if (host is String && host.isNotEmpty) host.toLowerCase(),
      ],
    );
  }

  final String id;
  final String name;

  /// Where its card goes: its site, the promotion's parameters in it if it
  /// has them.
  final Uri url;

  /// Its logo's file (SVG or PNG), downloaded beside the list; its name's
  /// first letter when null.
  final String? logo;

  /// A line about it, by language code (`en`, `zh`).
  final Map<String, String> description;

  /// The hosts its base URLs are at, by which an import is known to be
  /// its.
  final List<String> hosts;

  /// [description] in [languageCode], else in English, else any.
  String? describe(String languageCode) =>
      description[languageCode] ??
      description['en'] ??
      description.values.firstOrNull;

  /// The list, its logos beside it.
  static final feed = Uri.parse(
    'https://raw.githubusercontent.com/Cxxhh/Caocode/main/site/featured/upstreams.json',
  );

  /// A logo's name: a file beside the list, never a path.
  static bool isLogoName(String name) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(name) &&
      !name.contains('..');

  /// Those listed in [json] (the list's text), in its order, their logos
  /// in [logoDirectory].
  static List<FeaturedUpstream> parseList(
    String json, {
    String logoDirectory = '',
  }) {
    final Object? data;
    try {
      data = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    final list = data is Map ? data['upstreams'] : null;
    if (list is! List) return const [];
    return [
      for (final entry in list) ?fromJson(entry, logoDirectory: logoDirectory),
    ];
  }

  /// How [load] gets the list: [feed], or what it got last time where it
  /// does not answer. Tests set their own.
  @visibleForTesting
  static Future<List<FeaturedUpstream>> Function() loader =
      fetchFeaturedUpstreams;

  /// How [load] gets the list kept last time, to show while [loader]
  /// gets it again. Tests set their own.
  @visibleForTesting
  static Future<List<FeaturedUpstream>> Function() keptLoader =
      readFeaturedUpstreams;

  static Future<List<FeaturedUpstream>>? _loaded;

  /// Those listed as [load] got them last, or [readKept]: for what shows
  /// them as they are, an upstream's icon at one's host, say.
  static final ValueNotifier<List<FeaturedUpstream>> known = ValueNotifier(
    const [],
  );

  /// [known], from the list kept last time, while there are none: at the
  /// app's start, with no asking caocode.dev.
  static Future<void> readKept() async {
    if (known.value.isNotEmpty) return;
    try {
      final kept = await keptLoader();
      if (known.value.isEmpty) known.value = kept;
    } on Object {
      // None.
    }
  }

  /// The one of [known] [host] is at; null for none.
  static FeaturedUpstream? knownAt(String host) => at(host, known.value);

  /// Those the app lists, asked again on every call, at once those it got
  /// last time (in this run, else kept from the last), the new list as
  /// soon as it answers; where there are none yet, the new list. None
  /// where none could be got.
  static Future<List<FeaturedUpstream>> load() {
    final last = _loaded;
    final fresh = loader().catchError((Object _) => const <FeaturedUpstream>[]);
    unawaited(
      fresh.then((list) {
        _loaded = Future.value(list);
        known.value = list;
      }),
    );
    final kept = (last ?? keptLoader()).catchError(
      (Object _) => const <FeaturedUpstream>[],
    );
    return _loaded = kept.then((list) {
      if (list.isEmpty) return fresh;
      if (known.value.isEmpty) known.value = list;
      return list;
    });
  }

  @visibleForTesting
  static void forget() {
    _loaded = null;
    known.value = const [];
  }

  /// The one of [upstreams] [host] is at; null for none.
  static FeaturedUpstream? at(String host, List<FeaturedUpstream> upstreams) {
    final lower = host.toLowerCase();
    return upstreams.where((u) => u.hosts.contains(lower)).firstOrNull;
  }
}
