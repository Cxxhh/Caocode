import 'dart:io';

import 'package:caocode/kernel/codex/codex_config_file.dart';
import 'package:caocode/kernel/codex/codex_provider_config.dart';
import 'package:caocode/kernel/codex/codex_providers.dart';
import 'package:caocode/models/secret_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const gateway = '''
model_provider = "gateway"
model = "gateway-model"
model_reasoning_effort = "high"

[model_providers.gateway]
name = "Gateway"
base_url = "https://gateway.example/v1"
wire_api = "responses"
requires_openai_auth = true
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'switching preserves global source, multiline text and other providers',
    () {
      const globals = '''
# User settings
approval_policy = "on-request" # my choice
instructions = """
model = "keep this text"
[model_providers.custom]
this is a string, not a provider
"""

[mcp_servers."my.server"]
command = "node"
args = [
  "tools.js", # keep comment
]

[projects."/home/me/project"]
trust_level = "trusted"

[model_providers.other]
name = "other"
base_url = "https://other.example/v1"
''';
      final source =
          'model = "old"\nmodel_provider = "custom"\n'
          '$globals\n[model_providers.custom]\nname = "old"\n'
          'base_url = "https://old.example/v1"\n';
      final applied = CodexProviderConfig(gateway)
          .applyTo(source, apiKey: 'test-provider-key');
      expect(applied, contains(globals));
      final result = CodexProviderConfig(applied);
      expect(result.model, 'gateway-model');
      expect(result.providerId, 'custom');
      expect(result.table['requires_openai_auth'], false);
      expect(result.apiKey, 'test-provider-key');
      expect(result.values['mcp_servers']['my.server']['args'], ['tools.js']);
      expect(result.values['model_providers']['other']['name'], 'other');
      expect(result.values['model_providers'].length, 2);
    },
  );

  test('dotted keys and CRLF retain their global configuration', () {
    const source =
        'model = "old"\r\nmodel_providers.custom.name = "old"\r\n'
        'model_providers.custom.base_url = "https://old.example/v1"\r\n'
        'mcp_servers.test.command = "node" # untouched\r\n';
    final applied = CodexProviderConfig(gateway).applyTo(source);
    expect(
      applied,
      contains('mcp_servers.test.command = "node" # untouched\r\n'),
    );
    expect(applied.replaceAll('\r\n', ''), isNot(contains('\n')));
    expect(CodexProviderConfig(applied).baseUrl, 'https://gateway.example/v1');
  });

  test('inline provider tables can switch back to the official provider', () {
    const source =
        'model_provider = "custom"\nmodel = "old"\n'
        'model_providers = {custom = {name = "old", base_url = "http://localhost:1234"}, '
        'other = {name = "other"}}\n';
    final custom = CodexProviderConfig(gateway).applyTo(source);
    expect(
      CodexProviderConfig(custom).values['model_providers']['other']['name'],
      'other',
    );
    final official = CodexProvider.presets.first.parsed.applyTo(custom);
    final parsed = CodexProviderConfig(official);
    expect(parsed.providerId, 'openai');
    expect(parsed.values['model_providers'].containsKey('custom'), false);
    expect(parsed.model, isNull);
  });

  test(
    'selected profile retains global fields and inherits the new provider',
    () {
      const source = '''
profile = "work"
[profiles.work]
model = "profile-model"
model_provider = "profile-provider"
approval_policy = "on-request"
[profiles.other]
model = "other-model"
''';
      final applied = CodexProviderConfig(gateway).applyTo(source);
      final config = CodexProviderConfig(applied);
      expect(config.model, 'gateway-model');
      expect(config.providerId, 'custom');
      expect(
        config.values['profiles']['work']['approval_policy'],
        'on-request',
      );
      expect(config.values['profiles']['other']['model'], 'other-model');
    },
  );

  test(
    'switching drops only outgoing compatibility values still owned by it',
    () {
      final outgoing = CodexProviderConfig('$gateway\n');
      final withWindow = CodexProviderConfig(
        'model_context_window = 100000\n$gateway',
      );
      final live = withWindow.applyTo('web_search = "cached"\n');
      final restored = CodexProvider.presets.first.parsed.applyTo(
        live,
        outgoing: withWindow,
      );
      expect(
        CodexProviderConfig(restored).values
            .containsKey('model_context_window'),
        false,
      );
      expect(CodexProviderConfig(restored).values['web_search'], 'cached');
      final changed = live.replaceFirst('100000', '200000');
      final retained = CodexProvider.presets.first.parsed.applyTo(
        changed,
        outgoing: withWindow,
      );
      expect(
        CodexProviderConfig(retained).values['model_context_window'],
        200000,
      );
      expect(
        outgoing.matches(outgoing.applyTo('web_search = "cached"\n')),
        true,
      );
    },
  );

  test('inline profiles and nested model overrides switch without changing tools', () {
    const source =
        'profile = "work"\n'
        'profiles = {work = {model = "old", model_provider = "old", approval_policy = "never", '
        'model_providers = {custom = {name = "old", base_url = "https://old.example/v1"}}}}\n'
        'agents = {default_subagent_model = "old", default_subagent_reasoning_effort = "low", max_threads = 4}\n'
        '[memories]\nextract_model = "old"\nconsolidation_model = "old"\nuse_memories = true\n';
    final applied = CodexProviderConfig(gateway).applyTo(source);
    final config = CodexProviderConfig(applied);
    expect(config.model, 'gateway-model');
    expect(config.baseUrl, 'https://gateway.example/v1');
    expect(config.values['profiles']['work']['approval_policy'], 'never');
    expect(config.values['agents'], {'max_threads': 4});
    expect(config.values['memories'], {'use_memories': true});
  });

  test('command authentication is kept without incompatible auth flags', () {
    final command = CodexProviderConfig(
      '${gateway.replaceFirst('requires_openai_auth = true', '')}'
      '[model_providers.gateway.auth]\ncommand = "get-token"\n',
    );
    final applied = command.projected();
    expect(applied.table['auth']['command'], 'get-token');
    expect(applied.table.containsKey('requires_openai_auth'), false);
    final keyed = command.projected(apiKey: 'override-key');
    expect(keyed.table.containsKey('auth'), false);
    expect(keyed.table['requires_openai_auth'], false);
  });

  test(
    'provider secrets are separated from settings and imported key fragments',
    () async {
      final secrets = MemorySecretStore();
      final providers = CodexProviders.memory(secrets: secrets);
      addTearDown(providers.dispose);
      final config = '$gateway\nexperimental_bearer_token = "fragment-key"\n';
      final provider = await providers.save(
        CodexProvider(id: 'test', name: 'Test', config: config),
        apiKey: '',
      );
      expect(await providers.key('test'), 'fragment-key');
      expect(provider.config, isNot(contains('fragment-key')));
      expect(provider.config, isNot(contains('experimental_bearer_token')));
      expect(
        provider.parsed.matches(
          provider.parsed.applyTo(''),
          apiKey: 'fragment-key',
        ),
        false,
      );
      await providers.remove('test');
      expect(await providers.key('test'), isNull);
    },
  );

  test(
    'invalid TOML errors do not echo credentials and reject global fragments',
    () {
      expect(
        () => CodexProviderConfig('password = "secret-key"\n[broken'),
        throwsA(predicate((Object error) => !'$error'.contains('secret-key'))),
      );
      expect(
        () =>
            CodexProviderConfig('approval_policy = "never"\n$gateway')
                .validate(),
        throwsFormatException,
      );
      expect(
        () =>
            CodexProviderConfig(gateway.replaceFirst('responses', 'chat'))
                .validate(),
        throwsFormatException,
      );
    },
  );

  group('configuration files', () {
    late Directory directory;
    late CodexConfigFile file;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'caocode-codex-config-',
      );
      file = CodexConfigFile.at(p.join(directory.path, 'config.toml'));
    });
    tearDown(() => directory.delete(recursive: true));

    test(
      'backs up configuration, retains auth.json, and creates private files',
      () async {
        final original = '# my tools\n[mcp_servers.test]\ncommand = "node"\n';
        await File(file.path).writeAsString(original);
        final auth = File(p.join(directory.path, 'auth.json'));
        await auth.writeAsString('{"tokens":{"id_token":"test-login"}}');
        final authBefore = await auth.readAsString();
        await file.activate(
          CodexProviderConfig(gateway),
          apiKey: 'test-provider-key',
        );
        expect(await File('${file.path}.caocode.bak').readAsString(), original);
        expect(await auth.readAsString(), authBefore);
        expect((await File(file.path).stat()).mode & 0x1ff, 0x180);
        expect(
          CodexProviderConfig(await file.read()).apiKey,
          'test-provider-key',
        );
        await file.activate(CodexProvider.presets.first.parsed);
        expect(CodexProviderConfig(await file.read()).official, true);
        expect(await auth.readAsString(), authBefore);
      },
    );

    test('malformed configuration is left untouched', () async {
      await File(file.path).writeAsString('[invalid');
      await expectLater(
        file.activate(CodexProviderConfig(gateway)),
        throwsFormatException,
      );
      expect(await file.read(), '[invalid');
      expect(await File('${file.path}.caocode.bak').exists(), false);
    });

    test(
      'opening missing config creates once without replacing existing contents',
      () async {
        await Future.wait([file.ensureExists(), file.ensureExists()]);
        final before = await file.read();
        await file.ensureExists();
        expect(await file.read(), before);
        expect(before, contains('Codex configuration'));
      },
    );
  });

  test('config resolution follows CODEX_HOME and a custom file', () async {
    final file = await CodexConfigFile.resolve(
      environment: {'HOME': '/home/test', 'CODEX_HOME': '/tmp/codex-home'},
      windows: false,
    );
    expect(file.path, '/tmp/codex-home/config.toml');
    final custom = await CodexConfigFile.resolve(
      configPath: '~/custom/config.toml',
      environment: {'HOME': '/home/test'},
      windows: false,
    );
    expect(custom.serverHome, '/home/test/custom');
    await expectLater(
      CodexConfigFile.resolve(
        configPath: 'relative/config.toml',
        environment: {'HOME': '/home/test'},
        windows: false,
      ),
      throwsFormatException,
    );
  });

  test(
    'Windows WSL resolves the distribution home and maps it for Fast IDE',
    () async {
      final file = await CodexConfigFile.resolve(
        cwd: r'\\wsl.localhost\Ubuntu\home\test\project',
        environment: {'USERPROFILE': r'C:\Users\test'},
        windows: true,
        wslHome: (distribution) async {
          expect(distribution, 'Ubuntu');
          return '/home/test/.codex';
        },
      );
      expect(file.path, '//wsl.localhost/Ubuntu/home/test/.codex/config.toml');
      expect(file.serverHome, '/home/test/.codex');
      final custom = await CodexConfigFile.resolve(
        cwd: r'\\wsl.localhost\Ubuntu\home\test\project',
        configPath: '/home/test/custom/config.toml',
        windows: true,
        environment: {},
        wslHome: (_) async => '/home/test/.codex',
      );
      expect(
        custom.path,
        '//wsl.localhost/Ubuntu/home/test/custom/config.toml',
      );
      expect(custom.serverHome, '/home/test/custom');
    },
  );
}
