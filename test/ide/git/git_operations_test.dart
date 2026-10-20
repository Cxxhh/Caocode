import 'package:caocode/ide/git/git_repository.dart';
import 'package:caocode/ide/git/git_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_git.dart';

/// The Git operations of #39 (fetch, pull, push) and #65 (unstage on a Git
/// without `restore`), against the fake Git's commands.
void main() {
  late FakeGit git;
  late IdeGitService service;

  setUp(() async {
    git = FakeGit('/project');
    git.status =
        '## main...origin/main [ahead 1]\x00'
        'M  lib/staged.dart\x00'
        ' M lib/a.dart\x00';
    service = IdeGitService(git.root, runner: git.run);
    await service.repositoryRoot();
  });

  group('#65 unstaging on an old Git', () {
    test('a Git with restore uses it', () async {
      git.version = 'git version 2.39.2 (Apple Git-143)';
      await service.unstage(['/project/lib/a.dart']);
      expect(git.callsTo('restore').single, [
        'restore',
        '--staged',
        '--',
        'lib/a.dart',
      ]);
      expect(git.callsTo('reset'), isEmpty);
    });

    test('a Git before 2.23 uses reset HEAD --', () async {
      git.version = 'git version 2.17.1';
      await service.unstage(['/project/lib/a.dart']);
      expect(git.callsTo('reset').single, [
        'reset',
        '-q',
        'HEAD',
        '--',
        'lib/a.dart',
      ]);
      expect(git.callsTo('restore'), isEmpty);
    });

    test('before the first commit it removes from the index either way',
        () async {
      git.version = 'git version 2.17.1';
      await service.unstage(null, unborn: true);
      expect(git.callsTo('rm').single, ['rm', '--cached', '-r', '-q', '--', '.']);
      expect(git.callsTo('reset'), isEmpty);
    });

    test('the version is read once', () async {
      await service.unstage(['/project/lib/a.dart']);
      await service.unstage(['/project/lib/a.dart']);
      expect(git.callsTo('--version'), hasLength(1));
    });

    test('an unknown version takes the newer command', () async {
      git.version = 'git version unknown';
      await service.unstage(['/project/lib/a.dart']);
      expect(git.callsTo('restore'), hasLength(1));
    });
  });

  test('parseGitVersion reads the major and minor', () {
    expect(parseGitVersion('git version 2.23.0.windows.1'), (2, 23));
    expect(parseGitVersion('git version 2.39.2 (Apple Git-143)'), (2, 39));
    expect(parseGitVersion('nonsense'), isNull);
  });

  group('#39 fetch, pull and push', () {
    test('fetch of one remote, and of all of them', () async {
      await service.fetch(remote: 'origin');
      expect(git.callsTo('fetch').single, ['fetch', 'origin', '--tags']);


      await service.fetch();
      expect(git.callsTo('fetch').last, ['fetch', '--all', '--tags']);
    });

    test('the repository fetches, pulls and pushes its upstream', () async {
      final repository = IdeGitRepository(
        IdeGitService(git.root, runner: git.run),
        refreshDelay: Duration.zero,
      );
      addTearDown(repository.dispose);
      await repository.refresh();

      await repository.fetch();
      expect(git.callsTo('fetch').last, ['fetch', '--all', '--tags']);

      await repository.pull();
      expect(git.callsTo('pull').single, ['pull', '--tags', 'origin', 'main']);

      await repository.push();
      expect(git.callsTo('push').single, ['push', 'origin', 'main:main']);
    });

    test('pull and push without an upstream fail with a message', () async {
      git.status = '## feature/x\x00 M lib/a.dart\x00';
      final repository = IdeGitRepository(
        IdeGitService(git.root, runner: git.run),
        refreshDelay: Duration.zero,
      );
      addTearDown(repository.dispose);
      await repository.refresh();

      await expectLater(repository.pull(), throwsA(isA<IdeGitException>()));
      await expectLater(repository.push(), throwsA(isA<IdeGitException>()));
      expect(git.callsTo('pull'), isEmpty);
      expect(git.callsTo('push'), isEmpty);
    });
  });
}
