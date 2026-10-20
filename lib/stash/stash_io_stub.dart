import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

ImageProvider stashImageProvider(String path) => NetworkImage(path);

bool stashFileExists(String path) => false;

Future<String?> fetchPageTitle(String url) async => null;

String? pageTitleOf(String html) => null;

Future<String?> gitBranchOf(String folder) async => null;

Future<bool> isGitRepository(String folder) async => false;

Future<String?> readTextFile(String path) async => null;

Future<void> writeTextFile(String path, String text) async {}
Future<Uint8List?> readBytesFile(String path) async => null;

Future<void> installStashSkill(String root) async {}
