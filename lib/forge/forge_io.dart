import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'forge_api.dart';

/// [ForgeHttp] with dart:io's client (through the app's proxy, as every
/// client is: see NetworkProxyOverrides).
class IoForgeHttp implements ForgeHttp {
  IoForgeHttp()
    : _client = HttpClient()
        ..userAgent = 'Caocode'
        ..connectionTimeout = const Duration(seconds: 15);

  final HttpClient _client;

  @override
  Future<ForgeResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? json,
    Map<String, String>? form,
  }) async {
    try {
      final request = await _client.openUrl(method, url);
      headers.forEach(request.headers.set);
      if (form != null) {
        request.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: 'utf-8',
        );
        request.write(Uri(queryParameters: form).query);
      } else if (json != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(json));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 30));
      return ForgeResponse(response.statusCode, body);
    } on TimeoutException {
      throw ForgeException('$url did not answer.');
    } on IOException catch (error) {
      throw ForgeException('$error');
    }
  }
}

/// The URLs of the Git remotes of the repository [folder] is in, `origin`
/// first; none for none (or no Git).
Future<List<String>> gitRemoteUrls(String folder) async {
  try {
    final result = await Process.run('git', [
      'config',
      '--get-regexp',
      r'^remote\..*\.url$',
    ], workingDirectory: folder).timeout(const Duration(seconds: 5));
    if (result.exitCode != 0) return const [];
    final remotes = <(String, String)>[
      for (final line in const LineSplitter().convert('${result.stdout}'))
        if (RegExp(r'^remote\.(.+)\.url\s+(.+)$').firstMatch(line)
            case final match?)
          (match[1]!, match[2]!.trim()),
    ];
    remotes.sort((a, b) => a.$1 == 'origin' ? -1 : (b.$1 == 'origin' ? 1 : 0));
    return [for (final (_, url) in remotes) url];
  } on Object {
    return const [];
  }
}
