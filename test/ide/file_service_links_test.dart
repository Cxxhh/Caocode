@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:caocode/ide/file_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// This machine's files: a symbolic link listed as what it leads to, as
/// VS Code's explorer shows it.
void main() {
  late Directory project;
  late Directory outside;
  late IdeFileService files;

  setUp(() {
    project = Directory.systemTemp.createTempSync('caocode-links-');
    outside = Directory.systemTemp.createTempSync('caocode-links-outside-');
    files = IdeFileService(project.path);
  });
  tearDown(() {
    project.deleteSync(recursive: true);
    outside.deleteSync(recursive: true);
  });

  String at(String name) => p.join(project.path, name);

  test('a link to a folder is a folder, to a file a file', () async {
    Directory(p.join(outside.path, 'data')).createSync();
    File(p.join(outside.path, 'data', 'a.txt')).writeAsStringSync('a');
    File(p.join(outside.path, 'notes.txt')).writeAsStringSync('n');
    Link(at('data')).createSync(p.join(outside.path, 'data'));
    Link(at('notes.txt')).createSync(p.join(outside.path, 'notes.txt'));
    Link(at('gone')).createSync(p.join(outside.path, 'nowhere'));

    final listed = {
      for (final file in await files.list(project.path))
        file.name: file.isDirectory,
    };
    expect(listed, {'data': true, 'gone': false, 'notes.txt': false});
    expect([for (final f in await files.list(at('data'))) f.name], ['a.txt']);
  });
}
