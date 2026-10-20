import 'forge_api.dart';

class IoForgeHttp implements ForgeHttp {
  @override
  Future<ForgeResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? json,
    Map<String, String>? form,
  }) async => throw const ForgeException('No network here.');
}

Future<List<String>> gitRemoteUrls(String folder) async => const [];
