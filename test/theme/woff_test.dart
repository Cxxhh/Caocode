// WOFF fonts as SFNTs (the Chalice icon theme's font is a WOFF): the
// codicon TTF wrapped as a WOFF comes back with the same tables.

import 'dart:io';
import 'dart:typed_data';

import 'package:caocode/theme/woff.dart';
import 'package:flutter_test/flutter_test.dart';

/// The tables of an SFNT by tag, and its flavor.
({int flavor, Map<int, List<int>> tables}) readSfnt(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  return (
    flavor: data.getUint32(0),
    tables: {
      for (var i = 0; i < data.getUint16(4); i++)
        data.getUint32(12 + i * 16): bytes.sublist(
          data.getUint32(12 + i * 16 + 8),
          data.getUint32(12 + i * 16 + 8) + data.getUint32(12 + i * 16 + 12),
        ),
    },
  );
}

/// [sfnt] as a WOFF, its tables compressed where that makes them smaller.
Uint8List toWoff(Uint8List sfnt) {
  final (:flavor, :tables) = readSfnt(sfnt);
  final entries = tables.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  final stored = [
    for (final MapEntry(value: table) in entries)
      switch (ZLibCodec().encode(table)) {
        final compressed when compressed.length < table.length => compressed,
        _ => table,
      },
  ];
  var length = 44 + entries.length * 20;
  final offsets = <int>[];
  for (final table in stored) {
    offsets.add(length);
    length += (table.length + 3) & ~3;
  }
  final woff = Uint8List(length);
  final out = ByteData.sublistView(woff)
    ..setUint32(0, 0x774f4646)
    ..setUint32(4, flavor)
    ..setUint32(8, length)
    ..setUint16(12, entries.length);
  for (final (i, MapEntry(key: tag, value: table)) in entries.indexed) {
    out
      ..setUint32(44 + i * 20, tag)
      ..setUint32(44 + i * 20 + 4, offsets[i])
      ..setUint32(44 + i * 20 + 8, stored[i].length)
      ..setUint32(44 + i * 20 + 12, table.length);
    woff.setRange(offsets[i], offsets[i] + stored[i].length, stored[i]);
  }
  return woff;
}

void main() {
  final ttf = File('assets/codicons/codicon.ttf').readAsBytesSync();

  test('a WOFF comes back as the SFNT it wraps, its tables inflated', () {
    final woff = toWoff(ttf);
    expect(woff.length, lessThan(ttf.length));
    final decoded = readSfnt(sfntFromWoff(woff));
    final original = readSfnt(ttf);
    expect(decoded.flavor, original.flavor);
    expect(decoded.tables.keys, unorderedEquals(original.tables.keys));
    for (final MapEntry(:key, :value) in original.tables.entries) {
      expect(decoded.tables[key], value, reason: 'table $key');
    }
  });

  test('anything else is left as it is; a broken WOFF throws', () {
    expect(identical(sfntFromWoff(ttf), ttf), isTrue);
    final woff = toWoff(ttf);
    expect(
      () => sfntFromWoff(Uint8List.sublistView(woff, 0, 100)),
      throwsFormatException,
    );
  });
}
