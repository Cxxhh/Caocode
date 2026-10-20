import 'dart:typed_data';

import 'package:caocode/stash/stash_disk.dart';
import 'package:caocode/stash/stash_note.dart';
import 'package:caocode/stash/stash_settings.dart';
import 'package:caocode/stash/stash_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StashNote', () {
    test('round-trips through its file', () {
      final note = StashNote(
        id: 12,
        created: DateTime(2026, 10, 12, 18, 35),
        title: 'SSH 主机列表',
        body: '本机和 SSH 主机都显示\n\n- [ ] ALL',
        status: StashStatus.requirement,
        pinned: true,
        project: '/Users/me/monad',
        threads: [
          StashThreadLink(
            session: 'abc',
            project: '/Users/me/monad',
            title: 'Fix',
            said: 'Done: the hosts are listed.',
            at: DateTime(2026, 10, 12, 19),
          ),
        ],
        source: const StashSource(
          project: '/Users/me/monad',
          branch: 'main',
          thread: 'abc',
        ),
      );
      final back = StashNote.decode(12, note.encode());
      expect(back.title, note.title);
      expect(back.body, note.body);
      expect(back.status, StashStatus.requirement);
      expect(back.pinned, isTrue);
      expect(back.project, '/Users/me/monad');
      expect(back.threads, note.threads);
      expect(back.source, note.source);
      expect(back.created, note.created);
    });

    test('one conversation linked, as it was kept before, is read', () {
      final note = StashNote.decode(
        4,
        '---\nthread: {"project":"/p","session":"s1","title":"Fix"}\n---\n\nx\n',
      );
      expect(note.threads, [
        const StashThreadLink(session: 's1', project: '/p', title: 'Fix'),
      ]);
      // Not yet sent, it was no conversation.
      expect(
        StashNote.decode(
          5,
          '---\nthread: {"project":"/p"}\n---\n\nx\n',
        ).threads,
        isEmpty,
      );
    });

    test('a file without front matter is all text', () {
      final note = StashNote.decode(3, '# Hello\n\nworld\n');
      expect(note.body, '# Hello\n\nworld');
      expect(note.status, StashStatus.collected);
      expect(note.displayTitle, 'Hello');
    });

    test('keeps the original apart from its requirement', () {
      final note = StashNote(id: 1, created: DateTime(2026), body: 'idea');
      note.body = note.withRequirement('背景：…');
      expect(note.original, 'idea');
      expect(note.requirement, '背景：…');
      note.body = note.withRequirement('新的');
      expect(note.original, 'idea');
      expect(note.requirement, '新的');
    });

    test('finds its pictures', () {
      final note = StashNote(
        id: 1,
        created: DateTime(2026),
        body: '![](1/a.png)\n<img src="1/b.png" width="200">',
      );
      expect(note.images, ['1/a.png', '1/b.png']);
    });
  });

  group('StashStore', () {
    late MemoryStashDisk disk;
    late StashStore store;

    setUp(() {
      disk = MemoryStashDisk();
      store = StashStore(disk);
    });

    test('numbers stashes one after another, never again', () async {
      final a = await store.create(body: 'a');
      final b = await store.create(body: 'b');
      expect([a.id, b.id], [1, 2]);
      await store.delete(b.id);
      final c = await store.create(body: 'c');
      expect(c.id, 3);
      expect(disk.files.keys, unorderedEquals([1, 3]));
    });

    test('reads what another app wrote', () async {
      await store.load();
      disk.files[7] = '---\nid: 7\n---\n\nfrom elsewhere\n';
      disk.modified[7] = DateTime.now();
      await store.reload();
      expect(store.byId(7)?.body, 'from elsewhere');
      final next = await store.create();
      expect(next.id, 8);
    });

    test('merges into the lowest number, the others leading to it', () async {
      final a = await store.create(body: 'first');
      final b = await store.create(body: 'second ![](2/x.png)');
      disk.assets['2/x.png'] = Uint8List(3);
      final merged = await store.merge([b.id, a.id]);
      expect(merged!.id, 1);
      expect(merged.body, 'first\n\n---\n\nsecond ![](1/x.png)');
      expect(store.byId(2), same(merged));
      expect(disk.assets.keys, ['1/x.png']);
      expect(disk.files.containsKey(2), isFalse);
      // Kept for the next run.
      final again = StashStore(disk);
      await again.load();
      expect(again.byId(2)?.id, 1);
    });

    test('copies small files, links big ones', () async {
      final a = await store.create();
      disk.sizes['/tmp/small.pdf'] = 10;
      disk.sizes['/tmp/huge.mov'] = stashCopyLimit + 1;
      final small = await store.addFile(a.id, '/tmp/small.pdf');
      expect(small, (path: '1/small.pdf', copied: true, size: 10));
      final huge = await store.addFile(a.id, '/tmp/huge.mov');
      expect(huge?.copied, isFalse);
      expect(huge?.path, '/tmp/huge.mov');
      final copied = await store.addFile(
        a.id,
        '/tmp/huge.mov',
        copyAnyway: true,
      );
      expect(copied?.copied, isTrue);
    });

    test('searches words, titles first, pictures\' text too', () async {
      final a = await store.create(body: 'ssh hosts in the sidebar');
      final b = await store.create(body: 'nothing here ![](2/s.png)');
      store.pictureText[store.absolute('2/s.png')] = 'SSH 主机';
      await store.update(a.id, (note) => note.title = 'SSH');
      expect(store.search('ssh').map((n) => n.id), [a.id, b.id]);
      expect(store.search('sidebar ssh').map((n) => n.id), [a.id]);
      expect(store.search('#2').map((n) => n.id), [b.id]);
      expect(store.search('主机').map((n) => n.id), [b.id]);
    });

    test(
      'sorts them, pinned first, or as dragged, kept for the next',
      () async {
        final a = await store.create(body: 'a');
        final b = await store.create(body: 'b');
        final c = await store.create(body: 'c');
        await store.update(a.id, (note) => note.pinned = true);
        List<int> ids(StashSort sort) => [
          for (final note in store.sorted(store.notes, sort)) note.id,
        ];
        expect(ids(StashSort.number), [a.id, c.id, b.id]);
        expect(ids(StashSort.updated), [a.id, c.id, b.id]);

        await store.reorder([b.id, a.id]);
        // Never dragged: at the top.
        expect(ids(StashSort.manual), [c.id, b.id, a.id]);
        final again = StashStore(disk);
        await again.load();
        expect(again.order, [b.id, a.id]);
      },
    );

    test(
      'a stash is called by its text, else by its pictures\' text',
      () async {
        final pictures = await store.create(body: '![](1/x.png)');
        expect(store.headline(pictures), '');
        var told = 0;
        store.addListener(() => told++);
        store.pictureRead(store.absolute('1/x.png'), '\n  发布清单  \n第二行');
        expect(told, 1);
        expect(store.headline(pictures), '发布清单');
        await store.update(
          pictures.id,
          (note) => note.body = '记一下\n\n![](1/x.png)',
        );
        expect(store.headline(store.byId(pictures.id)!), '记一下');
      },
    );
  });
}
