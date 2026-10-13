@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:bao_remote/files.dart' show IdeFileExistsException;
import 'package:caocode/customize/customization_store.dart';
import 'package:caocode/customize/customizations.dart';
import 'package:caocode/remote/remote_customization_disk.dart';
import 'package:caocode/remote/ssh_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'remote_harness.dart';

/// Customize on a remote host: the customizations its agents read, its
/// own `~/.claude` and its projects', through its server.
void main() {
  late Directory dataDir;
  late Directory temp;
  late String home;
  late String config;
  late String project;
  late SshHost host;
  late CustomizationStore store;

  void write(String path, String text) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('caocode-remote-data-');
    temp = Directory.systemTemp.createTempSync('caocode-remote-custom-');
    final root = temp.resolveSymbolicLinksSync();
    home = p.join(root, 'home');
    config = p.join(home, '.claude');
    project = p.join(root, 'project');
    Directory(project).createSync(recursive: true);
    host = SshHost('dev', connect: MemoryConnector(dataDir.path).call);
    store = CustomizationStore(
      configDir: config,
      homeDir: home,
      disk: RemoteCustomizationDisk(host),
    );
  });
  tearDown(() async {
    host.close();
    temp.deleteSync(recursive: true);
    dataDir.deleteSync(recursive: true);
  });

  test("the host's skills, the user's, synced and its project's", () async {
    write(
      p.join(config, 'skills', 'pdf', 'SKILL.md'),
      '---\nname: pdf\ndescription: Reads PDF files\n---\n',
    );
    write(p.join(config, 'skills', 'synced', 'a', 'web', 'SKILL.md'), 'Web');
    write(p.join(project, '.claude', 'skills', 'ship', 'SKILL.md'), 'Ships');
    // A skill linked in from elsewhere, as installers do.
    write(p.join(home, 'shared', 'lint', 'SKILL.md'), 'Lints');
    Link(
      p.join(config, 'skills', 'lint'),
    ).createSync(p.join(home, 'shared', 'lint'));

    final skills = await store.list(
      CustomizationKind.skills,
      project: project,
    );
    expect([for (final skill in skills) (skill.scope, skill.name)], [
      (CustomizationScope.user, 'lint'),
      (CustomizationScope.user, 'pdf'),
      (CustomizationScope.synced, 'web'),
      (CustomizationScope.project, 'ship'),
    ]);
    expect(skills[1].description, 'Reads PDF files');
  });

  test('made there, folders and all; edited and deleted there', () async {
    final path = await store.create(
      CustomizationKind.subagents,
      CustomizationScope.project,
      'reviewer',
      project: project,
    );
    expect(path, p.join(project, '.claude', 'agents', 'reviewer.md'));
    expect(File(path).existsSync(), isTrue);
    await expectLater(
      store.create(
        CustomizationKind.subagents,
        CustomizationScope.project,
        'reviewer',
        project: project,
      ),
      throwsA(isA<IdeFileExistsException>()),
    );

    await store.write(path, 'Reviews');
    expect(File(path).readAsStringSync(), 'Reviews');
    expect(await store.read(path), 'Reviews');
    expect(await store.exists(path), isTrue);

    final [agent] = await store.list(
      CustomizationKind.subagents,
      project: project,
    );
    await store.delete(agent);
    expect(File(path).existsSync(), isFalse);
  });

  test('its MCP servers, from its ~/.claude.json and the project', () async {
    write(
      p.join(home, '.claude.json'),
      jsonEncode({
        'mcpServers': {
          'docs': {'command': 'docs-server'},
        },
        'projects': {
          project: {
            'mcpServers': {
              'db': {'url': 'http://localhost:5432'},
            },
          },
        },
      }),
    );
    final servers = await store.list(
      CustomizationKind.mcps,
      project: project,
    );
    expect([for (final server in servers) (server.scope, server.name)], [
      (CustomizationScope.user, 'docs'),
      (CustomizationScope.local, 'db'),
    ]);
    expect(store.isLocal, isFalse);
  });
}
