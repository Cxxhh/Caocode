import 'account_api.dart';

/// Not where there is no dart:io (the web): no channel build there.
Future<AccountResponse> sendToAccountSite(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  Object? json,
}) => Future.error(UnsupportedError('no network here'));
