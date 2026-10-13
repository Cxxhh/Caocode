import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../platform/data_dir.dart';
import 'featured_upstreams.dart';

/// See [FeaturedUpstream.loader]: the list at [FeaturedUpstream.feed],
/// through the app's proxy, as every [HttpClient], kept in the cache with
/// its logos, which are got again when the list changes. Where caocode.dev
/// does not answer, the list kept last time; none before the first.
Future<List<FeaturedUpstream>> fetchFeaturedUpstreams({
  Uri? feed,
  String? cacheDir,
}) async {
  feed ??= FeaturedUpstream.feed;
  final dir = Directory(
    cacheDir ?? p.join(DataDirectory.current.cacheDir, 'featured'),
  );
  final kept = File(p.join(dir.path, 'upstreams.json'));
  List<FeaturedUpstream> parse(String text) =>
      FeaturedUpstream.parseList(text, logoDirectory: dir.path);

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final bytes = await _get(client, feed, _maxList);
    if (bytes == null) return await _read(kept, parse);
    final text = utf8.decode(bytes, allowMalformed: true);
    final list = parse(text);
    if (await _readText(kept) != text) {
      await dir.create(recursive: true);
      await Future.wait([
        for (final upstream in list)
          if (upstream.logo case final logo?)
            _download(client, feed.resolve(p.basename(logo)), logo),
      ]);
      await writeFileAtomically(kept, text);
    }
    return list;
  } on Object {
    return _read(kept, parse);
  } finally {
    client.close(force: true);
  }
}

/// See [FeaturedUpstream.keptLoader]: the list [fetchFeaturedUpstreams]
/// kept last time, its logos with it; none before the first.
Future<List<FeaturedUpstream>> readFeaturedUpstreams({String? cacheDir}) {
  final dir = cacheDir ?? p.join(DataDirectory.current.cacheDir, 'featured');
  return _read(
    File(p.join(dir, 'upstreams.json')),
    (text) => FeaturedUpstream.parseList(text, logoDirectory: dir),
  );
}

const _maxList = 512 * 1024;
const _maxLogo = 512 * 1024;
const _timeout = Duration(seconds: 8);

Future<String?> _readText(File file) async {
  try {
    return await file.readAsString();
  } on FileSystemException {
    return null;
  }
}

Future<List<FeaturedUpstream>> _read(
  File file,
  List<FeaturedUpstream> Function(String) parse,
) async => switch (await _readText(file)) {
  final text? => parse(text),
  null => const [],
};

/// [url]'s body, when it answers 200 with at most [max] bytes.
Future<Uint8List?> _get(HttpClient client, Uri url, int max) async {
  final request = await client.getUrl(url).timeout(_timeout);
  final response = await request.close().timeout(_timeout);
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    return null;
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response.timeout(_timeout)) {
    builder.add(chunk);
    if (builder.length > max) return null;
  }
  return builder.takeBytes();
}

/// [url] to [path]; one that cannot be got is left as it was (the card
/// shows the site's first letter while there is none).
Future<void> _download(HttpClient client, Uri url, String path) async {
  try {
    final bytes = await _get(client, url, _maxLogo);
    if (bytes != null) await File(path).writeAsBytes(bytes, flush: true);
  } on Object {
    // Kept as it was.
  }
}
