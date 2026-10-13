import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/kernel/codex/codex_catalog.dart';
import 'package:caocode/search/codex_conversation_search.dart';
import 'package:flutter_test/flutter_test.dart';

class Catalog extends CodexCatalog {
  Catalog();
  int reads = 0;
  DateTime updated = DateTime(2026);
  bool deleted = false;
  String reply = 'initial response';
  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(
      path: '/project',
      sessions: [
        if (!deleted)
          SessionRecord(
            id: 'one',
            title: 'one',
            updatedAt: updated,
            cwd: '/project',
          ),
      ],
    ),
  ];
  @override
  Future<Map<String, Object?>> read(SessionRecord session) async {
    reads++;
    return {
      'turns': [
        {
          'items': [
            {
              'type': 'userMessage',
              'content': [
                {'type': 'text', 'text': 'user input'},
                {
                  'type': 'text',
                  'text': '<caocode_context>hidden reminder</caocode_context>',
                },
              ],
            },
            {'type': 'agentMessage', 'text': reply},
          ],
        },
      ],
    };
  }
}

void main() {
  test(
    'search caches unchanged threads and ignores private context notes',
    () async {
      final catalog = Catalog();
      final search = CodexConversationSearch(catalog: catalog);
      await search.prepare();
      expect((await search.search('INITIAL')).single.sessionId, 'one');
      expect(await search.search('hidden reminder'), isEmpty);
      expect(catalog.reads, 1);
      catalog.reply = 'updated response';
      catalog.updated = DateTime(2026, 2);
      await search.prepare();
      expect((await search.search('updated')).single.sessionId, 'one');
      expect(catalog.reads, 2);
      catalog.deleted = true;
      await search.prepare();
      expect(await search.search('response'), isEmpty);
    },
  );
}
