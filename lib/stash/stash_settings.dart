/// How a list of stashes is ordered: as dragged, the last edited first,
/// the last made first, or by number.
enum StashSort { manual, updated, created, number }

/// The `stash.*` settings of settings.json (see docs/stash.md).
class StashSettings {
  const StashSettings({
    this.hotkey = '',
    this.showAll = false,
    this.directory,
    this.sort = StashSort.updated,
    this.pinned = false,
  });

  static const hotkeyKey = 'stash.hotkey';
  static const showAllKey = 'stash.showAll';
  static const directoryKey = 'stash.directory';
  static const sortKey = 'stash.sort';
  static const pinnedKey = 'stash.pinned';

  /// ⌃⇧Space, Ctrl+Shift+Space on Windows: offered in the settings, not
  /// taken unasked (a shortcut of every app's, it would take the keys from
  /// the IDEs that have them, VS Code's parameter hints among them).
  static const suggestedHotkey = 'ctrl+shift+space';

  /// The shortcut that shows the panel from any app; none when empty, as
  /// it is until one is set.
  final String hotkey;

  /// Whether the panel shows every stash beside the one written in.
  final bool showAll;

  /// Where the stashes are kept; `~/Caocode/Stash` when null.
  final String? directory;

  /// How the panel's list of all orders them.
  final StashSort sort;

  /// Whether the panel stays over other apps' windows (pinned in its top
  /// bar); else it is in front as it shows, and others may cover it.
  final bool pinned;

  static StashSettings parse(Map<String, Object?> settings) => StashSettings(
    hotkey: switch (settings[hotkeyKey]) {
      final String hotkey => hotkey.trim(),
      _ => '',
    },
    showAll: settings[showAllKey] == true,
    directory: switch (settings[directoryKey]) {
      final String directory when directory.trim().isNotEmpty =>
        directory.trim(),
      _ => null,
    },
    sort: switch (settings[sortKey]) {
      final String sort =>
        StashSort.values.asNameMap()[sort] ?? StashSort.updated,
      _ => StashSort.updated,
    },
    pinned: settings[pinnedKey] == true,
  );

  /// [hotkey] as the menus show one: `⌃⇧Space` on macOS, `Ctrl+Shift+Space`
  /// elsewhere.
  static String label(String hotkey, {required bool mac}) {
    if (hotkey.trim().isEmpty) return '';
    final parts = hotkey.toLowerCase().split('+').map((p) => p.trim()).toList();
    final modifiers = <String>[];
    String key = '';
    for (final part in parts) {
      switch (part) {
        case 'ctrl' || 'control':
          modifiers.add(mac ? '⌃' : 'Ctrl');
        case 'alt' || 'option' || 'opt':
          modifiers.add(mac ? '⌥' : 'Alt');
        case 'shift':
          modifiers.add(mac ? '⇧' : 'Shift');
        case 'cmd' || 'command' || 'meta' || 'win':
          modifiers.add(mac ? '⌘' : 'Win');
        default:
          key = part.length == 1
              ? part.toUpperCase()
              : '${part[0].toUpperCase()}${part.substring(1)}';
      }
    }
    // macOS orders them ⌃⌥⇧⌘.
    if (mac) {
      const order = ['⌃', '⌥', '⇧', '⌘'];
      modifiers.sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
      return '${modifiers.join()}$key';
    }
    return [...modifiers, key].join('+');
  }
}
