import 'dart:convert';
import 'dart:io';

import 'package:caocode/kernel/codex/cc_switch_providers.dart';
import 'package:caocode/kernel/codex/cc_switch_providers_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

const config = '''
model_provider = "gateway"
model = "gateway-model"
[model_providers.gateway]
name = "Gateway"
base_url = "https://gateway.example/v1"
wire_api = "responses"
requires_openai_auth = true
''';

Map<String, Object?> row(String id, {String? token, String? text}) => {
  'id': id,
  'name': 'Provider $id',
  'settings_config': jsonEncode({
    'config': text ?? config,
    'auth': {'OPENAI_API_KEY': token ?? 'ccs-test-token'},
  }),
  'meta': '{"apiFormat":"openai_responses"}',
  'is_current': 1,
};

void main() {
  test('projects only provider fields and keeps credentials out of config', () {
    final snapshot = CcSwitchSnapshot.fromRows('/ccs.db', [
      row('one', text: '$config\n[mcp_servers.files]\ncommand = "node"\n'),
    ]);
    final entry = snapshot.providers.single;
    expect(entry.current, isTrue);
    expect(entry.apiKey, 'ccs-test-token');
    expect(entry.provider.config, isNot(contains('ccs-test-token')));
    expect(entry.provider.parsed.values, isNot(contains('mcp_servers')));
    expect(entry.provider.parsed.table['requires_openai_auth'], false);
    expect(entry.provider.parsed.providerId, 'custom');
    expect(
      entry.provider.id,
      CcSwitchSnapshot.fromRows('/ccs.db', [
        row('one'),
      ]).providers.single.provider.id,
    );
    expect(
      entry.provider.id,
      isNot(
        CcSwitchSnapshot.fromRows('/other.db', [
          row('one'),
        ]).providers.single.provider.id,
      ),
    );
  });

  test(
    'bad rows, proxy formats and managed accounts do not hide valid rows',
    () {
      final snapshot = CcSwitchSnapshot.fromRows('/ccs.db', [
        {...row('broken'), 'settings_config': '{"private":"do-not-leak'},
        row('toml', text: 'secret = "do-not-leak"\n[broken'),
        {...row('chat'), 'meta': '{"apiFormat":"openai_chat"}'},
        {
          ...row('oauth'),
          'meta': '{"authBinding":{"source":"managed_account"}}',
        },
        row('valid'),
      ]);
      expect(snapshot.providers.single.provider.name, 'Provider valid');
      expect(snapshot.warnings, hasLength(4));
      expect(snapshot.warnings.join(), isNot(contains('do-not-leak')));
    },
  );

  test('explicit credentials override the auth JSON value', () {
    final snapshot = CcSwitchSnapshot.fromRows('/ccs.db', [
      row('one', text: '${config}experimental_bearer_token = "inline-token"\n'),
    ]);
    expect(snapshot.providers.single.apiKey, 'inline-token');
    expect(
      snapshot.providers.single.provider.config,
      isNot(contains('inline-token')),
    );
  });

  test('paths use the app host, accept tilde and reject relative paths', () {
    expect(
      ccSwitchDatabasePath(
        null,
        environment: {'HOME': '/home/test'},
        windows: false,
      ),
      '/home/test/.cc-switch/cc-switch.db',
    );
    expect(
      ccSwitchDatabasePath(
        '~/ccs/db.sqlite',
        environment: {'USERPROFILE': r'C:\Users\test'},
        windows: true,
      ),
      r'C:\Users\test\ccs\db.sqlite',
    );
    expect(
      ccSwitchDatabasePath(
        r'\\wsl.localhost\Ubuntu\home\test\cc-switch.db',
        windows: true,
      ),
      r'\\wsl.localhost\Ubuntu\home\test\cc-switch.db',
    );
    expect(() => ccSwitchDatabasePath('cc-switch.db'), throwsFormatException);
  });

  group('read-only database', () {
    late Directory directory;
    late String path;
    late Database database;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('caocode-cc-switch-');
      path = p.join(directory.path, 'cc-switch.db');
      database = sqlite3.open(path);
      database.execute('''CREATE TABLE providers (
        id TEXT, app_type TEXT, name TEXT, settings_config TEXT,
        meta TEXT DEFAULT '{}', is_current INTEGER DEFAULT 0,
        sort_index INTEGER, created_at INTEGER,
        PRIMARY KEY (id, app_type))''');
    });
    tearDown(() async {
      database.close();
      await directory.delete(recursive: true);
    });
    void insert(String id, {String app = 'codex', int order = 0}) {
      final values = row(id);
      database.execute(
        'INSERT INTO providers (id, app_type, name, settings_config, meta, is_current, sort_index) VALUES (?, ?, ?, ?, ?, 1, ?)',
        [
          id,
          app,
          values['name'],
          values['settings_config'],
          values['meta'],
          order,
        ],
      );
    }

    test(
      'reads only Codex providers in CCS order without changing the database',
      () async {
        insert('other', app: 'claude');
        insert('later', order: 5);
        insert('first');
        final before = await File(path).readAsBytes();
        final snapshot = await CcSwitchSnapshot.read(path);
        expect(snapshot.providers.map((p) => p.provider.name), [
          'Provider first',
          'Provider later',
        ]);
        expect(await File(path).readAsBytes(), before);
      },
    );

    test(
      'refresh reads committed WAL additions, updates, keys and deletions',
      () async {
        database.execute('PRAGMA journal_mode = WAL');
        insert('one');
        final first = await CcSwitchSnapshot.read(path);
        expect(first.providers.single.apiKey, 'ccs-test-token');
        database.execute(
          'UPDATE providers SET settings_config = ? WHERE id = ?',
          [row('one', token: 'rotated-token')['settings_config'], 'one'],
        );
        insert('two');
        final refreshed = await CcSwitchSnapshot.read(path);
        expect(refreshed.providers, hasLength(2));
        expect(refreshed.providers.first.apiKey, 'rotated-token');
        database.execute('DELETE FROM providers WHERE id = ?', ['one']);
        expect(
          (await CcSwitchSnapshot.read(path)).providers.single.provider.name,
          'Provider two',
        );
      },
    );

    test(
      'missing and incompatible files fail without creating a database',
      () async {
        final missing = p.join(directory.path, 'missing.db');
        await expectLater(
          CcSwitchSnapshot.read(missing),
          throwsA(isA<FileSystemException>()),
        );
        expect(await File(missing).exists(), false);
        database.execute('DROP TABLE providers');
        await expectLater(CcSwitchSnapshot.read(path), throwsFormatException);
        final invalid = File(p.join(directory.path, 'invalid.db'));
        await invalid.writeAsString('not a database');
        await expectLater(
          CcSwitchSnapshot.read(invalid.path),
          throwsFormatException,
        );
      },
    );
  });
}
