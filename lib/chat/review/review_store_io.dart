import 'dart:io';

import 'package:bao_remote/local.dart';

import '../../platform/data_dir.dart';

export 'package:bao_remote/local.dart' show LocalReviewStore;

/// Not under `flutter test`, where no test should write to the data folder.
bool get reviewSupported => !Platform.environment.containsKey('FLUTTER_TEST');

/// The project's store in the data folder's `checkpoints/`.
Future<ReviewStore?> openReviewStore(String root) async {
  if (!reviewSupported) return null;
  return LocalReviewStore.open(
    root,
    checkpoints: DataDirectory.current.checkpointsDir,
  );
}
