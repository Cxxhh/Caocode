import 'dart:io';

import 'package:bao_agent/src/config/settings.dart';
import 'package:bao_agent/src/permissions/decision.dart';
import 'package:bao_agent/src/permissions/rules.dart';
import 'package:bao_agent/src/permissions/shell_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShellCommand', () {
    test('split at operators outside quotes', () {
      final parsed = ShellCommand.parse(
        'cd src && npm test || echo "a && b"; ls | wc -l & true\nfalse',
      );
      expect(parsed.commands, [
        'cd src',
        'npm test',
        'echo "a && b"',
        'ls',
        'wc -l',
        'true',
        'false',
      ]);
      expect(parsed.hasSubstitution, isFalse);
      expect(parsed.unbalanced, isFalse);
    });

    test('substitutions, redirects, open quotes, comments', () {
      expect(ShellCommand.parse(r'echo $(whoami)').hasSubstitution, isTrue);
      expect(ShellCommand.parse('echo `id`').hasSubstitution, isTrue);
      expect(
        ShellCommand.parse('diff <(ls a) <(ls b)').hasSubstitution,
        isTrue,
      );
      expect(ShellCommand.parse(r"echo '$(not)'").hasSubstitution, isFalse);
      final redirected = ShellCommand.parse('ls > out.txt 2>/dev/null >> log');
      expect(redirected.redirects, ['out.txt', '/dev/null', 'log']);
      expect(redirected.redirectsOnlyToNull, isFalse);
      expect(ShellCommand.parse('ls 2>/dev/null').redirectsOnlyToNull, isTrue);
      expect(ShellCommand.parse('ls 2>&1').redirects, isEmpty);
      expect(ShellCommand.parse('echo "open').unbalanced, isTrue);
      expect(ShellCommand.parse('ls # && rm -rf /').commands, ['ls']);
      expect(ShellCommand.parse('echo a\\\nb').commands, ['echo ab']);
    });

    test('a heredoc is input: its lines are not commands', () {
      final commit = ShellCommand.parse(
        "git commit -F - <<'MSG'\nFix it; rm -rf /\n\n"
        'Co-Authored-By: A <a@b.c>\nMSG\ngit status',
      );
      expect(commit.commands, ["git commit -F - <<'MSG'", 'git status']);
      expect(commit.redirects, isEmpty);
      expect(commit.hasSubstitution, isFalse);
      // Unquoted, it is expanded: a substitution in it runs.
      expect(
        ShellCommand.parse('cat <<END\n\$(whoami)\nEND').hasSubstitution,
        isTrue,
      );
      expect(
        ShellCommand.parse("cat <<'END'\n\$(whoami)\nEND").hasSubstitution,
        isFalse,
      );
      final written = ShellCommand.parse(
        'cat <<-END > out.txt\n\tx\n\tEND\nls',
      );
      expect(written.commands, ['cat <<-END > out.txt', 'ls']);
      expect(written.redirects, ['out.txt']);
      expect(ShellCommand.parse("cat <<< 'a b'\nls").commands, [
        "cat <<< 'a b'",
        'ls',
      ]);
    });

    test(
      'words: quotes taken off, assignments before the program left out',
      () {
        expect(ShellCommand.tokenize(r'''grep -r "a b" 'c d' e\ f'''), [
          'grep',
          '-r',
          'a b',
          'c d',
          'e f',
        ]);
        expect(
          ShellCommand.parse('FOO=1 BAR="x y" npm run build').words.single,
          ['npm', 'run', 'build'],
        );
      },
    );

    test('the prefix a rule is made of', () {
      expect(ShellCommand.prefix('git commit -m "x"'), 'git commit');
      expect(ShellCommand.prefix('npm run build -- --prod'), 'npm run build');
      expect(ShellCommand.prefix('python3 -m pytest -q'), 'python3 -m pytest');
      expect(ShellCommand.prefix('git --no-pager log'), 'git');
      expect(ShellCommand.prefix('NODE_ENV=x node app.js'), 'node');
      expect(ShellCommand.prefix('make'), 'make');
    });

    test('what only reads', () {
      for (final command in [
        'ls -la',
        'cat a | grep b | head -5',
        'git status && git log --oneline -5',
        'git -C sub diff HEAD~1',
        'git branch',
        'git branch --list "feat/*"',
        'git remote -v',
        'git config --get user.name',
        'git stash list',
        'find . -name "*.dart"',
        'sed -n 1,5p file',
        'npm ls',
        'gh pr view 12',
        'docker ps',
        'command -v flutter',
        'xargs cat',
        'printenv PATH',
        'ls 2>/dev/null',
      ]) {
        expect(isReadOnlyCommand(command), isTrue, reason: command);
      }
      for (final command in [
        'rm a',
        'git commit -m x',
        'git branch new-one',
        'git branch -D old',
        'git config user.name x',
        'git stash',
        'git tag v1',
        'find . -delete',
        'find . -exec rm {} \\;',
        'sed -i s/a/b/ f',
        'sed -ni p f',
        'sort -o out in',
        'ls > out.txt',
        r'echo $(rm x)',
        'env rm x',
        'npm install',
        'xargs rm',
        'echo "unbalanced',
        '',
      ]) {
        expect(isReadOnlyCommand(command), isFalse, reason: command);
      }
    });

    test('what is dangerous', () {
      bool dangerous(String command) =>
          ShellCommand.parse(command).words
              .any((w) => isDangerousWords(w, home: '/Users/me'));
      for (final command in [
        'rm -rf /',
        'rm -rf ~',
        'rm -fr /Users/me',
        r'rm -r $HOME',
        'rm -rf *',
        'rm -rf .',
        'sudo ls',
        'dd if=/dev/zero of=/dev/disk2',
        'mkfs.ext4 /dev/sda1',
        'cd x && rm -rf /*',
      ]) {
        expect(dangerous(command), isTrue, reason: command);
      }
      for (final command in [
        'rm -rf build',
        'rm file',
        'dd if=a of=b',
        'ls /',
      ]) {
        expect(dangerous(command), isFalse, reason: command);
      }
    });
  });

  group('rules', () {
    PermissionRule rule(String text, [String behavior = 'allow']) =>
        PermissionRule.parse(SourcedRule(text, behavior, SettingsSource.user));

    test('parsed: the tool, its content, aliases', () {
      final bash = rule('Bash(npm run test:*)');
      expect(bash.tool, 'Bash');
      expect(bash.content, 'npm run test:*');
      expect(bash.wholeTool, isFalse);
      expect(rule('Bash(*)').wholeTool, isTrue);
      expect(rule('Bash()').wholeTool, isTrue);
      expect(rule('WebFetch').wholeTool, isTrue);
      expect(rule('Task(Explore)').isFor('Agent'), isTrue);
      expect(rule('mcp__github').isFor('mcp__github__create_issue'), isTrue);
      expect(rule('mcp__github__*').isFor('mcp__github__create_issue'), isTrue);
      expect(
        rule('mcp__github__x').isFor('mcp__github__create_issue'),
        isFalse,
      );
      expect(rule('mcp__git').isFor('mcp__github__create_issue'), isFalse);
    });

    test('Bash rules: prefixes, wildcards, assignments', () {
      expect(
        bashRuleMatches('npm run test:*', 'npm run test -- --watch'),
        isTrue,
      );
      expect(bashRuleMatches('npm run test:*', 'npm run test'), isTrue);
      expect(bashRuleMatches('npm run test:*', 'npm run testing'), isFalse);
      expect(bashRuleMatches('git log *', 'git log --oneline'), isTrue);
      expect(bashRuleMatches('git log *', 'git log'), isTrue);
      expect(bashRuleMatches('ls', 'ls'), isTrue);
      expect(bashRuleMatches('ls', 'ls -la'), isFalse);
      expect(bashRuleMatches('* --version', 'node --version'), isTrue);
      expect(bashRuleMatches('npm test:*', 'CI=1 npm test'), isTrue);
    });

    test('path rules: from the root, home, settings folder, anywhere', () {
      bool matches(String content, String path, {String? root}) =>
          pathRuleMatches(
            content,
            path: path,
            cwd: '/work/app',
            home: '/home/me',
            root: root,
          );
      expect(matches('//etc/hosts', '/etc/hosts'), isTrue);
      expect(matches('~/.ssh/**', '/home/me/.ssh/id_rsa'), isTrue);
      expect(matches('/secrets/**', '/conf/secrets/a', root: '/conf'), isTrue);
      expect(matches('/secrets/**', '/work/app/secrets/a'), isTrue);
      expect(matches('.env', '/work/app/deep/.env'), isTrue);
      expect(matches('./.env', '/work/app/deep/.env'), isFalse);
      expect(matches('./.env', '/work/app/.env'), isTrue);
      expect(matches('src/**/*.ts', '/work/app/src/a/b.ts'), isTrue);
      expect(matches('src/**/*.ts', '/work/app/lib/b.ts'), isFalse);
      expect(matches('build/', '/work/app/x/build/out.js'), isTrue);
      expect(matches('//tmp/x', '/tmp/x/inner/file'), isTrue);
      expect(matches('', '/a'), isFalse);
      expect(matches('//c/Users/me/**', 'C:/Users/me/a.txt'), isTrue);
      if (Platform.isMacOS) {
        expect(matches('//ETC/hosts', '/etc/hosts'), isTrue);
      }
    });

    test('domains and plain values', () {
      expect(
        domainRuleMatches('domain:example.com', 'https://example.com/a'),
        isTrue,
      );
      expect(
        domainRuleMatches('domain:example.com', 'https://docs.example.com/a'),
        isFalse,
      );
      expect(
        domainRuleMatches('domain:*.example.com', 'https://docs.example.com/a'),
        isTrue,
      );
      expect(
        domainRuleMatches('domain:*.example.com', 'https://example.com/a'),
        isTrue,
      );
      expect(domainRuleMatches('example.com', 'https://example.com'), isFalse);
      expect(domainRuleMatches('domain:x.com', 'not a url'), isFalse);
      expect(plainRuleMatches('Explore', 'Explore'), isTrue);
      expect(plainRuleMatches('pdf:*', 'pdf:fill'), isTrue);
      expect(plainRuleMatches('re*', 'review'), isTrue);
      expect(plainRuleMatches('re*', 'are'), isFalse);
    });

    test('a folder as a rule', () {
      expect(folderRule('Read', '/Users/me/x/'), 'Read(//Users/me/x/**)');
      expect(folderRule('Edit', r'C:\Users\me'), 'Edit(//c/Users/me/**)');
    });

    test('decisions as the protocol has them', () {
      expect(
        ruleString({'toolName': 'Bash', 'ruleContent': 'ls:*'}),
        'Bash(ls:*)',
      );
      expect(ruleString({'toolName': 'WebFetch'}), 'WebFetch');
      final suggestion = addRulesSuggestion(['Bash(npm test:*)', 'Read']);
      expect(suggestion['type'], 'addRules');
      expect(suggestion['rules'], [
        {'toolName': 'Bash', 'ruleContent': 'npm test:*'},
        {'toolName': 'Read'},
      ]);
      expect(addDirectoriesSuggestion(['/x'])['directories'], ['/x']);
      expect(setModeSuggestion('acceptEdits')['mode'], 'acceptEdits');
    });
  });
}
