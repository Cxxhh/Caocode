import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../ide/ide_button.dart';
import '../ide/ide_commands.dart' show ideUsesMacKeys;
import '../ide/ide_hover.dart';
import '../ide/ide_menu.dart';
import '../l10n/l10n.dart';
import '../settings/settings_dialog.dart' show SettingsOpener, SettingsSection;
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'browser_bridge.dart';
import 'browser_keys.dart';
import 'browser_tools.dart';

/// A tab of the user's browser shared with Caocode, as it is now: the one
/// an agent last used, or one picked from the shared. Its page is shown as
/// the browser draws it (its screencast while the tab is in front, which
/// stops behind another; screenshots then), and what the user does here is
/// sent to it: the pointer's, the keyboard's, an input method's.
class BrowserMirror extends StatefulWidget {
  const BrowserMirror({super.key});

  @override
  State<BrowserMirror> createState() => _BrowserMirrorState();
}

class _BrowserMirrorState extends State<BrowserMirror> with TextInputClient {
  BrowserBridge get _bridge => BrowserBridge.instance;

  /// Picked by the user, over the agent's last.
  BrowserTab? _picked;

  /// The shared tabs of the browser shown, by id: their title and URL.
  final Map<int, Map> _tabs = {};
  BrowserConnection? _tabsOf;

  /// The tab shown, its screencast started.
  BrowserTab? _shown;
  String? _detached;

  /// The last frame, and the page's size it shows (CSS pixels).
  Uint8List? _frame;
  Size? _pageSize;
  DateTime _lastFrame = DateTime(0);
  DateTime _lastShot = DateTime(0);
  bool _shooting = false;
  Timer? _watch;
  StreamSubscription<BrowserEvent>? _events;
  StreamSubscription<BrowserTab>? _asked;

  /// The view's size and pixels, for the frames' size.
  Size _viewSize = Size.zero;
  double _ratio = 1;

  final _focus = FocusNode(debugLabel: 'browser mirror');
  final _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    _bridge.addListener(_sync);
    BrowserTools.lastTab.addListener(_agentMoved);
    _events = _bridge.events.listen(_received);
    // A step of the conversation's tab, asked for: over the user's pick.
    _asked = BrowserTools.shown.listen((_) => _agentMoved());
    _watch = Timer.periodic(const Duration(milliseconds: 300), (_) => _poll());
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _bridge.removeListener(_sync);
    BrowserTools.lastTab.removeListener(_agentMoved);
    unawaited(_events?.cancel());
    unawaited(_asked?.cancel());
    _watch?.cancel();
    _stop();
    _closeInput();
    _focus.dispose();
    super.dispose();
  }

  void _agentMoved() {
    // The agent's move shows: the user's pick gives way.
    _picked = null;
    _sync();
  }

  /// The tab to show: picked, else the agent's last, else the first shared.
  BrowserTab? get _wanted {
    final browsers = _bridge.browsers;
    bool live(BrowserTab? tab) =>
        tab != null &&
        browsers.any((b) => identical(b, tab.browser)) &&
        (!identical(tab.browser, _tabsOf) || _tabs.containsKey(tab.tabId));
    if (live(_picked)) return _picked;
    final last = BrowserTools.lastTab.value;
    if (live(last)) return last;
    if (browsers.isEmpty) return null;
    final browser = browsers.first;
    if (!identical(browser, _tabsOf) || _tabs.isEmpty) return null;
    return BrowserTab(browser, _tabs.keys.first);
  }

  Future<void> _sync() async {
    if (!mounted) return;
    final browsers = _bridge.browsers;
    final browser = _wanted?.browser ?? browsers.firstOrNull;
    if (!identical(browser, _tabsOf)) {
      _tabsOf = browser;
      _tabs.clear();
      if (browser != null) await _listTabs();
    }
    final wanted = _wanted;
    if (wanted != _shown) {
      _stop();
      _shown = wanted;
      _detached = null;
      _frame = null;
      _pageSize = null;
      if (wanted != null) unawaited(_start(wanted));
    }
    if (mounted) setState(() {});
  }

  Future<void> _listTabs() async {
    final browser = _tabsOf;
    if (browser == null) return;
    try {
      final tabs = await browser.request('tabs.list') as List? ?? const [];
      if (!identical(browser, _tabsOf)) return;
      _tabs
        ..clear()
        ..addEntries([
          for (final tab in tabs.cast<Map>())
            MapEntry(tab['tabId'] as int, tab),
        ]);
    } on Object {
      // Gone: the bridge says so.
    }
  }

  Future<void> _start(BrowserTab tab) async {
    try {
      await tab.browser.cdp(tab.tabId, 'Page.startScreencast', {
        'format': 'jpeg',
        'quality': 70,
        'maxWidth': (_viewSize.width * _ratio).round().clamp(320, 3840),
        'maxHeight': (_viewSize.height * _ratio).round().clamp(240, 3840),
      });
    } on Object catch (error) {
      if (tab == _shown && mounted) setState(() => _detached = '$error');
    }
  }

  void _stop() {
    final tab = _shown;
    if (tab == null) return;
    unawaited(
      tab.browser
          .cdp(tab.tabId, 'Page.stopScreencast')
          .then((_) {}, onError: (Object _) {}),
    );
  }

  /// A screenshot where the screencast has stopped (the tab behind
  /// another, its window out of sight) or sends nothing (the page still):
  /// a second apart at most.
  Future<void> _poll() async {
    final tab = _shown;
    if (tab == null || _shooting || _detached != null) return;
    final now = DateTime.now();
    if (now.difference(_lastFrame) < const Duration(milliseconds: 600) ||
        now.difference(_lastShot) < const Duration(seconds: 1)) {
      return;
    }
    _shooting = true;
    _lastShot = now;
    try {
      final view = await BrowserTools.viewport(tab.browser, tab.tabId);
      // As the screen has it, made small here: a screenshot's own scale
      // has the browser draw the page that small in its window meanwhile.
      final shot = await tab.browser.cdp(tab.tabId, 'Page.captureScreenshot', {
        'format': 'jpeg',
        'quality': 70,
      });
      if (tab != _shown || !mounted) return;
      // A screencast's frame may have come meanwhile: the newer is kept.
      if (DateTime.now().difference(_lastFrame) <
          const Duration(milliseconds: 600)) {
        return;
      }
      setState(() {
        _frame = base64Decode(shot['data'] as String);
        _pageSize = view.rect.size;
      });
    } on Object {
      // Between pages, or gone.
    } finally {
      _shooting = false;
    }
  }

  void _received(BrowserEvent event) {
    final tab = _shown;
    switch (event.event) {
      case 'cdp':
        if (tab == null ||
            !identical(event.connection, tab.browser) ||
            event.tabId != tab.tabId ||
            event.message['method'] != 'Page.screencastFrame') {
          return;
        }
        final params = (event.message['params'] as Map).cast<String, Object?>();
        unawaited(
          tab.browser
              .cdp(tab.tabId, 'Page.screencastFrameAck', {
                'sessionId': params['sessionId'],
              })
              .then((_) {}, onError: (Object _) {}),
        );
        final metadata = (params['metadata'] as Map).cast<String, Object?>();
        _lastFrame = DateTime.now();
        setState(() {
          _frame = base64Decode(params['data'] as String);
          _pageSize = Size(
            (metadata['deviceWidth'] as num).toDouble(),
            (metadata['deviceHeight'] as num).toDouble(),
          );
        });
      case 'tab':
        if (!identical(event.connection, _tabsOf)) return;
        final info = event.message['tab'] as Map;
        setState(() => _tabs[info['tabId'] as int] = info);
      case 'closed' || 'unshared':
        if (!identical(event.connection, _tabsOf)) return;
        _tabs.remove(event.tabId);
        unawaited(_sync());
      case 'detached':
        if (tab == null ||
            !identical(event.connection, tab.browser) ||
            event.tabId != tab.tabId) {
          return;
        }
        setState(() => _detached = '${event.message['reason']}');
    }
  }

  void _retry() {
    final tab = _shown;
    if (tab == null) return;
    setState(() => _detached = null);
    unawaited(_start(tab));
  }

  void _pick(BrowserTab tab) {
    _picked = tab;
    unawaited(_sync());
  }

  // --- The input method: there while the page has the focus and what has
  // its focus takes text (asked after each click, each Tab).

  TextInputConnection? _input;
  TextEditingValue _value = TextEditingValue.empty;
  bool _composing = false;
  bool _editable = false;

  Future<void> _checkEditable() async {
    final tab = _shown;
    if (tab == null) return;
    try {
      final result = await tab.browser.cdp(tab.tabId, 'Runtime.evaluate', {
        'expression':
            '(() => { let e = document.activeElement;'
            ' while (e && e.shadowRoot && e.shadowRoot.activeElement) e = e.shadowRoot.activeElement;'
            ' if (e && e.tagName === "IFRAME") return true;'
            ' return !!e && (e.isContentEditable || e.tagName === "TEXTAREA" ||'
            ' (e.tagName === "INPUT" && !/^(button|checkbox|radio|submit|reset|file|image|range|color)\$/i.test(e.type))); })()',
        'returnByValue': true,
      });
      _editable = (result['result'] as Map?)?['value'] == true;
    } on Object {
      _editable = false;
    }
    _syncInput();
  }

  void _syncInput() {
    final wanted = _focus.hasFocus && _editable && _shown != null;
    if (wanted && _input == null) {
      _value = TextEditingValue.empty;
      _input = TextInput.attach(
        this,
        const TextInputConfiguration(
          inputType: TextInputType.multiline,
          inputAction: TextInputAction.newline,
          autocorrect: false,
          enableSuggestions: false,
        ),
      )..show();
      _input!.setEditingState(_value);
      _placeInput();
    } else if (!wanted) {
      _closeInput();
    }
  }

  void _closeInput() {
    if (_composing) _ime('', commit: false);
    _composing = false;
    _input?.close();
    _input = null;
  }

  /// The input method's window, below the page's box (where the text is,
  /// the mirror does not know).
  void _placeInput() {
    final input = _input;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (input == null || box == null || !box.hasSize) return;
    input
      ..setEditableSizeAndTransform(box.size, box.getTransformTo(null))
      ..setComposingRect(Offset.zero & const Size(1, 1))
      ..setCaretRect(Offset.zero & const Size(1, 1));
  }

  void _ime(String text, {required bool commit, TextRange? selection}) {
    final tab = _shown;
    if (tab == null) return;
    final call = commit
        ? tab.browser.cdp(tab.tabId, 'Input.insertText', {'text': text})
        : tab.browser.cdp(tab.tabId, 'Input.imeSetComposition', {
            'text': text,
            'selectionStart': selection?.start ?? text.length,
            'selectionEnd': selection?.end ?? text.length,
          });
    unawaited(call.then((_) {}, onError: (Object _) {}));
  }

  @override
  TextEditingValue get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _value = value;
    final composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _composing = true;
      final start = composing.start;
      final length = composing.end - start;
      _ime(
        composing.textInside(value.text),
        commit: false,
        selection: value.selection.isValid
            ? TextRange(
                start: (value.selection.start - start).clamp(0, length),
                end: (value.selection.end - start).clamp(0, length),
              )
            : null,
      );
      return;
    }
    final was = _composing;
    _composing = false;
    if (value.text.isNotEmpty) {
      _ime(value.text, commit: true);
    } else if (was) {
      _ime('', commit: false);
    }
    // Empty again for what comes next: the page keeps the text.
    _value = TextEditingValue.empty;
    _input?.setEditingState(_value);
  }

  @override
  void performAction(TextInputAction action) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _input = null;
    _composing = false;
  }

  // --- Keys.

  /// Whether [character] is text: not a control character, nor one of
  /// macOS's function keys' (U+F700…).
  static bool _types(String? character) {
    if (character == null || character.isEmpty) return false;
    final unit = character.codeUnitAt(0);
    return unit >= 0x20 && unit != 0x7F && (unit < 0xF700 || unit > 0xF8FF);
  }

  void _sendKey(
    String type,
    KeyEvent event, {
    String? text,
    List<String>? commands,
  }) {
    final tab = _shown;
    if (tab == null) return;
    final name = browserKeyName(event.physicalKey);
    final label = event.logicalKey.keyLabel;
    unawaited(
      tab.browser
          .cdp(tab.tabId, 'Input.dispatchKeyEvent', {
            'type': type,
            'modifiers': BrowserModifiers.keyboard,
            'windowsVirtualKeyCode': browserKeyCode(event.physicalKey),
            'key':
                name ??
                text ??
                (label.length == 1 ? label.toLowerCase() : label),
            'code': ?name,
            'text': ?text,
            'unmodifiedText': ?text,
            'commands': ?commands,
          })
          .then((_) {}, onError: (Object _) {}),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_shown == null) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final down = event is! KeyUpEvent;
    final mac = ideUsesMacKeys;
    // Ctrl elsewhere, on a key that types: Ctrl and an arrow, Backspace…
    // are the page's, and Ctrl with Alt is AltGr, which types.
    final shortcut = mac
        ? keys.isMetaPressed
        : keys.isControlPressed &&
              !keys.isAltPressed &&
              browserKeyName(event.physicalKey) == null;
    if (shortcut) {
      if (!down) return KeyEventResult.ignored;
      // The Edit menu's, as macOS's commands: what the page takes alone.
      final command = switch (event.logicalKey) {
        LogicalKeyboardKey.keyC => 'copy',
        LogicalKeyboardKey.keyX => 'cut',
        LogicalKeyboardKey.keyV => 'paste',
        LogicalKeyboardKey.keyA => 'selectAll',
        LogicalKeyboardKey.keyZ => keys.isShiftPressed ? 'redo' : 'undo',
        LogicalKeyboardKey.keyY when !mac => 'redo',
        _ => null,
      };
      // Any other is the app's (⌘W, ⌘P…; Ctrl+W, Ctrl+P elsewhere).
      if (command == null) return KeyEventResult.ignored;
      _sendKey('rawKeyDown', event, commands: [command]);
      _sendKey('keyUp', event);
      return KeyEventResult.handled;
    }
    // What the input method composes is its.
    if (_composing) return KeyEventResult.ignored;
    final control = browserKeyName(event.physicalKey) != null;
    final types =
        (!keys.isControlPressed || (!mac && keys.isAltPressed)) &&
        _types(event.character);
    // Text, where the page takes it, comes through the input method.
    if (_input != null && types && !control) return KeyEventResult.ignored;
    if (!down) {
      _sendKey('keyUp', event);
      return KeyEventResult.handled;
    }
    final enter = browserKeyName(event.physicalKey) == 'Enter';
    if (enter || (types && !control)) {
      _sendKey('keyDown', event, text: enter ? '\r' : event.character);
    } else {
      _sendKey('rawKeyDown', event);
    }
    if (event.physicalKey == PhysicalKeyboardKey.tab) {
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 80), _checkEditable),
      );
    }
    return KeyEventResult.handled;
  }

  // --- The pointer, at the page's point (CSS pixels) under it.

  /// Where the frame is drawn in [size]: as big as fits, at the top.
  Rect _frameRect(Size size) {
    final page = _pageSize;
    if (page == null || page.isEmpty) return Offset.zero & size;
    final scale = (size.width / page.width).clamp(
      0.0,
      size.height / page.height,
    );
    final width = page.width * scale;
    return Rect.fromLTWH(
      (size.width - width) / 2,
      0,
      width,
      page.height * scale,
    );
  }

  Offset? _pagePoint(Offset local) {
    final page = _pageSize;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (page == null || box == null || !box.hasSize) return null;
    final rect = _frameRect(box.size);
    if (rect.isEmpty) return null;
    return (local - rect.topLeft) * (page.width / rect.width);
  }

  int _buttons = 0;
  int _clicks = 0;
  Duration? _lastDown;
  Offset? _lastDownAt;
  DateTime _lastMove = DateTime(0);

  static String _button(int buttons) => switch (buttons) {
    kSecondaryButton => 'right',
    kMiddleMouseButton => 'middle',
    _ => 'left',
  };

  void _mouse(
    String type,
    Offset local, {
    String button = 'none',
    int clicks = 0,
  }) {
    final tab = _shown;
    final point = _pagePoint(local);
    if (tab == null || point == null) return;
    unawaited(
      tab.browser
          .cdp(tab.tabId, 'Input.dispatchMouseEvent', {
            'type': type,
            'x': point.dx,
            'y': point.dy,
            'button': button,
            'buttons': _buttons,
            'clickCount': clicks,
            'modifiers': BrowserModifiers.keyboard,
          })
          .then((_) {}, onError: (Object _) {}),
    );
  }

  void _down(PointerDownEvent event) {
    _focus.requestFocus();
    final again =
        _lastDownAt != null &&
        _lastDown != null &&
        (event.localPosition - _lastDownAt!).distance < 5 &&
        event.timeStamp - _lastDown! < const Duration(milliseconds: 500);
    _clicks = again ? _clicks % 3 + 1 : 1;
    _lastDown = event.timeStamp;
    _lastDownAt = event.localPosition;
    _buttons = event.buttons;
    _mouse(
      'mousePressed',
      event.localPosition,
      button: _button(event.buttons),
      clicks: _clicks,
    );
  }

  void _up(PointerUpEvent event) {
    final button = _button(_buttons);
    _buttons = 0;
    _mouse(
      'mouseReleased',
      event.localPosition,
      button: button,
      clicks: _clicks,
    );
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 80), _checkEditable),
    );
  }

  /// Moves, fewer while no button is down: enough for hovers.
  void _move(PointerEvent event) {
    final now = DateTime.now();
    if (_buttons == 0 &&
        now.difference(_lastMove) < const Duration(milliseconds: 50)) {
      return;
    }
    _lastMove = now;
    _mouse(
      'mouseMoved',
      event.localPosition,
      button: _buttons == 0 ? 'none' : _button(_buttons),
    );
  }

  void _wheel(Offset local, Offset delta) {
    final tab = _shown;
    final point = _pagePoint(local);
    final page = _pageSize;
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (tab == null || point == null || page == null || box == null) return;
    // As far on the page as here: the page under the fingers follows them.
    final scale = page.width / _frameRect(box.size).width;
    unawaited(
      tab.browser
          .cdp(tab.tabId, 'Input.dispatchMouseEvent', {
            'type': 'mouseWheel',
            'x': point.dx,
            'y': point.dy,
            'deltaX': delta.dx * scale,
            'deltaY': delta.dy * scale,
            'modifiers': BrowserModifiers.keyboard,
          })
          .then((_) {}, onError: (Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final String? message;
    // Where to see why, and get the extension: none but a browser to share
    // a tab of.
    var settings = true;
    if (_bridge.otherApp) {
      message = l10n.browserOtherApp;
    } else if (_bridge.browsers.isEmpty) {
      message = l10n.browserNotConnected;
    } else if (_shown == null) {
      settings = false;
      message = l10n.browserNoSharedTab;
    } else {
      message = null;
    }
    if (message != null) {
      final open = settings ? SettingsOpener.maybeOf(context) : null;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textMuted),
              ),
              if (open != null) ...[
                const SizedBox(height: 12),
                IdeButton(
                  label: l10n.browserSettingsOpen,
                  icon: Codicons.settingsGear,
                  secondary: true,
                  onPressed: () => open(SettingsSection.browser),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final tab = _shown!;
    final info = identical(tab.browser, _tabsOf) ? _tabs[tab.tabId] : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TabBar(
          title: '${info?['title'] ?? ''}',
          url: '${info?['url'] ?? ''}',
          tabs: () async {
            await _listTabs();
            return [
              for (final MapEntry(key: id, value: other) in _tabs.entries)
                IdeMenuAction(
                  '${other['title'] ?? other['url']}',
                  checked: id == tab.tabId,
                  onSelected: () => _pick(BrowserTab(tab.browser, id)),
                ),
            ];
          },
          onReload: () => unawaited(
            tab.browser
                .cdp(tab.tabId, 'Page.reload')
                .then((_) {}, onError: (Object _) {}),
          ),
          onShow: () => unawaited(
            tab.browser
                .request('tabs.activate', {'tabId': tab.tabId})
                .then((_) {}, onError: (Object _) {}),
          ),
        ),
        Expanded(child: _page(context)),
      ],
    );
  }

  Widget _page(BuildContext context) {
    _ratio = MediaQuery.devicePixelRatioOf(context);
    final frame = _frame;
    final detached = _detached;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _viewSize) {
          final first = _viewSize == Size.zero;
          _viewSize = size;
          // Frames as big as shown: asked anew once the view is laid out.
          final tab = _shown;
          if (first && tab != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _stop();
              unawaited(_start(tab));
            });
          }
        }
        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          onFocusChange: (_) => _syncInput(),
          child: Listener(
            key: _key,
            onPointerDown: _down,
            onPointerUp: _up,
            onPointerMove: _move,
            onPointerHover: _move,
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                _wheel(event.localPosition, event.scrollDelta);
              }
            },
            onPointerPanZoomUpdate: (event) =>
                _wheel(event.localPosition, -event.localPanDelta),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (frame != null)
                  Positioned.fromRect(
                    rect: _frameRect(size),
                    child: Image.memory(
                      frame,
                      gaplessPlayback: true,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                if (detached != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.l10n.browserDetached,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textMuted),
                          ),
                          const SizedBox(height: 8),
                          IdeActionButton(
                            icon: Codicons.refresh,
                            tooltip: context.l10n.browserReconnect,
                            onPressed: _retry,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The tab's title and URL, its shared tabs' menu, and its actions.
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.title,
    required this.url,
    required this.tabs,
    required this.onReload,
    required this.onShow,
  });

  final String title;
  final String url;
  final FutureOr<List<IdeMenuEntry>> Function() tabs;
  final VoidCallback onReload;
  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      height: 34,
      padding: const EdgeInsets.only(left: 10, right: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.partBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: title.isEmpty ? url : title),
                  if (title.isNotEmpty && url.isNotEmpty)
                    TextSpan(
                      text: '  $url',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          IdeMenuButton(
            icon: Codicons.listFlat,
            tooltip: l10n.browserSharedTabs,
            entries: tabs,
          ),
          IdeActionButton(
            icon: Codicons.refresh,
            tooltip: l10n.browserReload,
            onPressed: onReload,
          ),
          IdeActionButton(
            icon: Codicons.linkExternal,
            tooltip: l10n.browserShowInBrowser,
            onPressed: onShow,
          ),
        ],
      ),
    );
  }
}
