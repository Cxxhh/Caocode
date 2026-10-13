import 'dart:io';

import 'package:caocode/kernel/codex/codex_config_setting.dart';
import 'package:caocode/kernel/codex/codex_process_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('app-server inherits the selected custom config directory', () async {
    final folder = await Directory.systemTemp.createTemp(
      'caocode config launch ',
    );
    final before = CodexConfigSetting.current;
    final config = p.join(folder.path, 'custom home', 'config.toml');
    CodexConfigSetting.current = () => config;
    final fake = File(p.join(folder.path, 'fake-codex.py'));
    await fake.writeAsString('''
import sys, json, os
for line in sys.stdin:
    json.loads(line)
    print(json.dumps({"method": "test/config", "params": {"home": os.environ.get("CODEX_HOME")}}), flush=True)
''');
    final transport = CodexProcessTransport(
      cwd: folder.path,
      executable: '/usr/bin/python3',
      arguments: [fake.path, 'app-server'],
    );
    try {
      final reply = transport.messages.first;
      transport.write({'method': 'test/config', 'id': 1});
      final result = await reply.timeout(const Duration(seconds: 10));
      expect((result['params'] as Map)['home'], p.dirname(config));
    } finally {
      transport.close();
      await transport.stopped;
      await CodexProcessTransport.registry.flush();
      CodexConfigSetting.current = before;
      await folder.delete(recursive: true);
    }
  }, skip: Platform.isWindows);
}
