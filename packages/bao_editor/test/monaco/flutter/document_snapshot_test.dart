import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:bao_editor/monaco/flutter/document_snapshot.dart';
import 'package:bao_editor/monaco/flutter/selection_adapter.dart';
import 'package:bao_editor/monaco/vs/editor/common/core/position.dart';

void main() {
  group('DocumentSnapshot', () {
    test('indexes mixed newlines, empty lines, and trailing lines', () {
      final snapshot = DocumentSnapshot('ab\r\nc\rd\n');
      expect(snapshot.text, 'ab\r\nc\rd\n');
      expect(snapshot.lineCount, 4);
      expect(snapshot.lineStarts, [0, 4, 6, 8]);
      expect(snapshot.contentEnds, [2, 5, 7, 8]);
      expect(snapshot.newlineLengths, [2, 1, 1, 0]);

      final empty = DocumentSnapshot('');
      expect(empty.lineCount, 1);
      expect(empty.lineStarts, [0]);
      expect(empty.contentEnds, [0]);
      expect(empty.newlineLengths, [0]);

      final adjacent = DocumentSnapshot('\r\n\n\r');
      expect(adjacent.lineStarts, [0, 2, 3, 4]);
      expect(adjacent.contentEnds, [0, 2, 3, 4]);
      expect(adjacent.newlineLengths, [2, 1, 1, 0]);
    });

    test('exposes immutable line geometry', () {
      final snapshot = DocumentSnapshot('a\r\nb');
      expect(() => snapshot.lineStarts[0] = 10, throwsUnsupportedError);
      expect(() => snapshot.contentEnds.add(10), throwsUnsupportedError);
      expect(() => snapshot.newlineLengths[0] = 0, throwsUnsupportedError);
      expect(snapshot.lineStarts, [0, 3]);
      expect(snapshot.contentEnds, [1, 4]);
      expect(snapshot.newlineLengths, [2, 0]);
    });

    test('agrees with selection adapter for every offset in varied text', () {
      final samples = <String>[
        '',
        'abc',
        '\r',
        '\n',
        '\r\n',
        '\r\n\r\n',
        'a\r\nb\rc\nd\n',
        '\r\n\n\r',
        'a😀b\r\n😀\rc\n',
      ];
      final random = Random(137);
      const pieces = ['a', '😀', '\r', '\n', '\r\n', ''];
      for (var sample = 0; sample < 80; sample++) {
        samples.add(
          List.generate(
            40,
            (_) => pieces[random.nextInt(pieces.length)],
          ).join(),
        );
      }

      for (final text in samples) {
        final snapshot = DocumentSnapshot(text);
        for (var offset = -3; offset <= text.length + 3; offset++) {
          final actual = snapshot.positionAtOffset(offset);
          expect(
            actual.equals(positionAtOffset(text, offset)),
            isTrue,
            reason: 'Text: $text, offset: $offset',
          );

          final clamped = offset < 0
              ? 0
              : (offset > text.length ? text.length : offset);
          final insideCrLf =
              clamped > 0 &&
              clamped < text.length &&
              text.codeUnitAt(clamped - 1) == 0x0D &&
              text.codeUnitAt(clamped) == 0x0A;
          expect(
            snapshot.offsetAtPosition(actual),
            insideCrLf ? clamped - 1 : clamped,
            reason: 'Roundtrip text: $text, offset: $offset',
          );
        }
      }
    });

    test('counts UTF-16 code units for positions and clamps coordinates', () {
      final snapshot = DocumentSnapshot('a😀\r\n\nZ\r');
      expect(snapshot.lineStarts, [0, 5, 6, 8]);
      expect(snapshot.contentEnds, [3, 5, 7, 8]);
      expect(snapshot.newlineLengths, [2, 1, 1, 0]);
      expect(snapshot.positionAtOffset(2).equals(const Position(1, 3)), isTrue);
      expect(snapshot.positionAtOffset(3).equals(const Position(1, 4)), isTrue);
      expect(snapshot.positionAtOffset(4).equals(const Position(1, 4)), isTrue);
      expect(snapshot.positionAtOffset(5).equals(const Position(2, 1)), isTrue);
      expect(snapshot.positionAtOffset(8).equals(const Position(4, 1)), isTrue);
      expect(snapshot.offsetAtPosition(const Position(1, 3)), 2);
      expect(snapshot.offsetAtPosition(const Position(1, 4)), 3);
      expect(snapshot.offsetAtPosition(const Position(1, 999)), 3);
      expect(snapshot.offsetAtPosition(const Position(2, 999)), 5);
      expect(snapshot.offsetAtPosition(const Position(3, 2)), 7);
      expect(snapshot.offsetAtPosition(const Position(4, 999)), 8);
      expect(snapshot.offsetAtPosition(const Position(-5, -5)), 0);
      expect(snapshot.offsetAtPosition(const Position(999, -5)), 8);
      expect(snapshot.offsetAtPosition(const Position(999, 999)), 8);
    });

    test('supports indexed lookups deep in a large document', () {
      final snapshot = DocumentSnapshot('${'ab\r\n' * 20000}z😀');
      expect(snapshot.lineCount, 20001);
      expect(snapshot.lineStarts.length, snapshot.lineCount);
      expect(snapshot.contentEnds.length, snapshot.lineCount);
      expect(snapshot.newlineLengths.length, snapshot.lineCount);
      for (final line in [0, 1, 9999, 19999]) {
        expect(snapshot.lineStarts[line], line * 4);
        expect(snapshot.contentEnds[line], line * 4 + 2);
        expect(snapshot.newlineLengths[line], 2);
        expect(
          snapshot.positionAtOffset(line * 4 + 3).equals(Position(line + 1, 3)),
          isTrue,
        );
      }
      expect(snapshot.lineStarts.last, 80000);
      expect(snapshot.contentEnds.last, 80003);
      expect(snapshot.newlineLengths.last, 0);
      expect(snapshot.offsetAtPosition(const Position(20001, 4)), 80003);
      expect(
        snapshot.positionAtOffset(80002).equals(const Position(20001, 3)),
        isTrue,
      );
    });

    test('edited scans the lines an edit touches, as a whole scan would', () {
      void same(DocumentSnapshot edited, String text) {
        final whole = DocumentSnapshot(text);
        expect(edited.text, text);
        expect(edited.lineStarts, whole.lineStarts, reason: text);
        expect(edited.contentEnds, whole.contentEnds, reason: text);
        expect(edited.newlineLengths, whole.newlineLengths, reason: text);
      }

      // CR and LF joined into a CRLF, and a CRLF split, at either end.
      for (final (text, start, end, inserted) in [
        ('a\r', 2, 2, '\n'),
        ('a\rb', 2, 2, '\nc'),
        ('a\n', 1, 1, '\r'),
        ('a\r\nb', 2, 2, 'x'),
        ('a\r\nb', 1, 2, ''),
        ('a\r\n\nb', 1, 2, ''),
        ('a\rX\nb', 2, 3, ''),
        ('a\r\r\n', 2, 3, ''),
        ('', 0, 0, '\r\n'),
        ('abc', 0, 3, ''),
        ('a\nb\nc', 0, 5, 'x\ry'),
      ]) {
        same(
          DocumentSnapshot.edited(DocumentSnapshot(text), start, end, inserted),
          text.replaceRange(start, end, inserted),
        );
      }
      final random = Random(7);
      const units = ['a', 'b', '\r', '\n', '\r\n', '😀'];
      String some(int max) => [
        for (var i = random.nextInt(max); i > 0; i--)
          units[random.nextInt(units.length)],
      ].join();
      var text = some(40);
      var snapshot = DocumentSnapshot(text);
      for (var i = 0; i < 3000; i++) {
        final start = random.nextInt(text.length + 1);
        final end = start + random.nextInt(min(6, text.length - start) + 1);
        final inserted = some(5);
        snapshot = DocumentSnapshot.edited(snapshot, start, end, inserted);
        text = text.replaceRange(start, end, inserted);
        same(snapshot, text);
        if (text.length > 200) {
          text = text.substring(0, 50);
          snapshot = DocumentSnapshot(text);
        }
      }
    });

    test('knows what edited snapshots share without reading them', () {
      (int, int) read(String a, String b) {
        final shortest = min(a.length, b.length);
        var prefix = 0;
        while (prefix < shortest && a[prefix] == b[prefix]) {
          prefix++;
        }
        var suffix = 0;
        while (suffix < shortest - prefix &&
            a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
          suffix++;
        }
        return (prefix, suffix);
      }

      final random = Random(3);
      final first = DocumentSnapshot('abc\ndef\nghi\n' * 5);
      final snapshots = [first];
      for (var i = 0; i < 40; i++) {
        final last = snapshots.last;
        final length = last.text.length;
        final start = random.nextInt(length + 1);
        final end = start + random.nextInt(min(4, length - start) + 1);
        snapshots.add(
          i.isEven
              ? DocumentSnapshot.edited(last, start, end, 'x\n' * (i % 3))
              : DocumentSnapshot.replaced(
                  last,
                  last.text.replaceRange(start, end, 'y'),
                  start,
                  end,
                ),
        );
      }
      for (var i = 0; i < snapshots.length; i++) {
        for (var j = i; j < snapshots.length; j++) {
          final old = snapshots[i];
          final next = snapshots[j];
          final known = DocumentSnapshot.knownSharedEnds(old, next);
          if (j - i > 32) {
            expect(known, isNull);
            continue;
          }
          final (prefix, suffix) = known!;
          final (realPrefix, realSuffix) = read(old.text, next.text);
          expect(prefix, lessThanOrEqualTo(realPrefix));
          expect(prefix + suffix, lessThanOrEqualTo(old.text.length));
          expect(prefix + suffix, lessThanOrEqualTo(next.text.length));
          expect(
            old.text.substring(old.text.length - suffix),
            next.text.substring(next.text.length - suffix),
          );
          if (j == i + 1) {
            expect(DocumentSnapshot.sharedEnds(old, next), known);
          }
        }
      }
      // Not edited from it: read.
      final other = DocumentSnapshot(first.text.replaceRange(3, 4, 'Z'));
      expect(DocumentSnapshot.knownSharedEnds(first, other), isNull);
      expect(DocumentSnapshot.sharedEnds(first, other), (
        3,
        first.text.length - 4,
      ));
      // Nor backwards.
      expect(DocumentSnapshot.knownSharedEnds(snapshots[1], first), isNull);
    });
  });
}
