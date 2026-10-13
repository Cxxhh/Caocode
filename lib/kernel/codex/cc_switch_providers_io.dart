import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'cc_switch_providers.dart';

String ccSwitchDatabasePath(
  String? path, {
  Map<String, String>? environment,
  bool? windows,
}) {
  final win = windows ?? Platform.isWindows;
  final env = environment ?? Platform.environment;
  final paths = win ? p.windows : p.posix;
  final home = env[win ? 'USERPROFILE' : 'HOME'];
  var selected = path?.trim() ?? '';
  if (selected.isEmpty ||
      selected.startsWith('~/') ||
      selected.startsWith('~\\')) {
    if (home == null || home.isEmpty) {
      throw const FileSystemException('无法找到 CC Switch 用户目录，请填写数据库绝对路径。');
    }
    selected = selected.isEmpty
        ? paths.join(home, '.cc-switch', 'cc-switch.db')
        : paths.join(home, selected.substring(2));
  }
  if (!paths.isAbsolute(selected)) {
    throw const FormatException('请填写 CC Switch 数据库的绝对路径或 ~/ 路径。');
  }
  return paths.normalize(selected);
}

Future<CcSwitchSnapshot> readCcSwitchProviders(String? path) {
  final selected = ccSwitchDatabasePath(path);
  return Isolate.run(() => _read(selected));
}

CcSwitchSnapshot _read(String path) {
  if (!File(path).existsSync()) {
    throw FileSystemException('找不到 CC Switch 数据库，请检查路径。', path);
  }
  Database? database;
  try {
    // Keep SQLite's normal locking and WAL handling. Copying just the .db file
    // or using immutable mode could silently omit CCS's most recent changes.
    database = sqlite3.open(path, mode: OpenMode.readOnly);
    database.execute('PRAGMA busy_timeout = 1500');
    final columns = database
        .select('PRAGMA table_info(providers)')
        .map((row) => row['name'])
        .toSet();
    if (!columns.containsAll({'id', 'app_type', 'name', 'settings_config'})) {
      throw const FormatException('此文件不是兼容的 CC Switch 数据库。');
    }
    final current = columns.contains('is_current')
        ? 'is_current'
        : '0 AS is_current';
    final meta = columns.contains('meta') ? 'meta' : "'{}' AS meta";
    final order = [
      if (columns.contains('sort_index')) 'COALESCE(sort_index, 999999)',
      if (columns.contains('created_at')) 'created_at',
      'id',
    ].join(', ');
    final rows = database.select(
      'SELECT id, name, settings_config, $current, $meta FROM providers '
      'WHERE app_type = ? ORDER BY $order',
      ['codex'],
    );
    return CcSwitchSnapshot.fromRows(path, rows);
  } on SqliteException {
    throw const FormatException('无法读取 CC Switch 数据库，可能正忙、已损坏或格式不兼容，请稍后刷新。');
  } finally {
    database?.close();
  }
}
