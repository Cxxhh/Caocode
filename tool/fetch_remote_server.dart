// Takes a remote server build already published at dl.caocode.dev (by
// .github/workflows/remote.yml's server-* tags, or with a release) instead
// of building one: its VERSION and servers.json, all the installers carry.
// An app packaged with them downloads the builds CI made, not ones only
// this machine has. Run from anywhere in the repository:
//
//   dart run tool/fetch_remote_server.dart                the newest
//   dart run tool/fetch_remote_server.dart <VERSION>      that one
//   dart run tool/fetch_remote_server.dart ... --out <dir>
//                                     into <dir> (build/remote-release/)
//
// tool/build_windows.dart and tool/build_macos.dart run it with
// --remote-release [VERSION].
import 'dart:convert';
import 'dart:io';

const _base = 'https://github.com/Cxxhh/Caocode/releases';

Future<void> main(List<String> arguments) async {
  final root = File.fromUri(Platform.script).parent.parent.absolute;
  final at = arguments.indexOf('--out');
  final out = Directory(
    at >= 0 && at + 1 < arguments.length
        ? arguments[at + 1]
        : '${root.path}/build/remote-release',
  );
  final named = [
    for (final (i, argument) in arguments.indexed)
      if (!argument.startsWith('--') && (i == 0 || arguments[i - 1] != '--out'))
        argument,
  ];
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    var version = named.firstOrNull ?? 'latest';
    if (version == 'latest') {
      _step('Finding the newest remote server');
      final latest = await _getJson(
        client,
        Uri.parse('$_base/latest/download/remote-latest.json'),
      );
      version = '${latest['version']}';
      stdout.writeln('  $version (${latest['tag']}, ${latest['commit']})');
    }
    if (version.contains(RegExp(r'[^A-Za-z0-9._+-]'))) {
      _fail('$version is not a remote server version.');
    }

    _step('Taking servers.json of $version');
    final servers = await _getJson(
      client,
      Uri.parse('$_base/download/server-$version/servers.json'),
    );
    if (servers['version'] != version) {
      _fail(
        '$_base/download/server-$version/servers.json is for ${servers['version']}.',
      );
    }
    final files = servers['files'] as Map<String, Object?>;
    for (final MapEntry(key: platform, :value) in files.entries) {
      final file = value as Map<String, Object?>;
      final url = Uri.parse('${file['url']}');
      final request = await client.headUrl(url);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != HttpStatus.ok ||
          response.contentLength != file['size']) {
        _fail(
          '$url is not served as servers.json says '
          '(HTTP ${response.statusCode}, ${response.contentLength} bytes, '
          'not ${file['size']}).',
        );
      }
      stdout.writeln('  $platform: $url');
    }

    // Nothing else there: a build left in it would be taken as this one.
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);
    File('${out.path}/VERSION').writeAsStringSync('$version\n');
    File('${out.path}/servers.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(servers)}\n',
    );
    _step('Done: ${out.path} ($version)');
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, Object?>> _getJson(HttpClient client, Uri url) async {
  final request = await client.getUrl(url);
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != HttpStatus.ok) {
    _fail(
      '$url: HTTP ${response.statusCode}'
      '${response.statusCode == HttpStatus.notFound ? ' (not published)' : ''}.',
    );
  }
  try {
    return jsonDecode(text) as Map<String, Object?>;
  } on Object {
    _fail('$url is not what was published (not a JSON object).');
  }
}

void _step(String message) => stdout.writeln('\n==> $message');

Never _fail(String message) {
  stderr.writeln('\n$message');
  exit(1);
}
