import 'stash_disk.dart';

/// No files on the web: kept while the app runs.
class FileStashDisk extends MemoryStashDisk {
  FileStashDisk([String? root]) : super(root: root ?? '/stash');
}
