import 'channel_setup.dart';

/// Not where there is no dart:io (the web): there is no setup there.
Future<ChannelAttribution?> lookUpChannel(Uri url) =>
    Future.error(UnsupportedError('no network here'));

Future<ChannelEntry?> channelEntry(String id) =>
    Future.error(UnsupportedError('no network here'));
