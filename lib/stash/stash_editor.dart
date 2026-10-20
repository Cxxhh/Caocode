// Quill's paste and shortcut hooks are marked experimental.
// ignore_for_file: experimental_member_use

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, listEquals;
import 'package:flutter/gestures.dart'
    show GestureRecognizer, PointerDeviceKind, kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/internal.dart' show ClipboardServiceProvider;
import 'package:flutter_quill/quill_delta.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_models.dart' show ImageAttachment;
import '../chat/composer/composer_files.dart';
import '../chat/composer/file_drop.dart';
import '../chat/floating/hover_tooltip.dart';
import '../chat/widgets/code_citation.dart'
    show CodeBlockColorizer, MarkdownCodeBlock;
import '../chat/widgets/hover_builder.dart';
import '../chat/widgets/image_thumbnails.dart' show showImageGallery;
import '../chat/widgets/markdown_math.dart';
import '../chat/widgets/markdown_view.dart';
import '../chat/widgets/scroll_edge_fade.dart';
import '../forge/forge_api.dart' show ForgeState;
import '../forge/forge_view.dart' show ForgeStateIcon;
import '../ide/ide_dialog.dart';
import '../ide/ide_hover.dart';
import '../ide/ide_input.dart';
import '../ide/ide_menu.dart';
import '../l10n/l10n.dart';
import '../models/auxiliary_model_menu.dart';
import '../models/model_providers.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/material_file_icons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/editor_launcher.dart' show openExternal;
import '../workspace/window_controls.dart';
import '../ide/ide_motion.dart';
import 'stash_ai.dart' show StashAiException;
import 'stash_caret.dart';
import 'stash_forge.dart';
import 'stash_html.dart';
import 'stash_io_stub.dart' if (dart.library.io) 'stash_io.dart' as io;
import 'stash_markdown.dart';
import 'stash_note.dart' show StashNote;
import 'stash_store.dart';

/// What the editor's pictures and files need: where the stash's folder
/// is, and the stash's number (made on the first picture, for a new one
/// nothing was written in yet).
class StashEditorScope extends InheritedWidget {
  const StashEditorScope({
    super.key,
    required this.store,
    required this.ensureNote,
    this.readOnly = false,
    this.onCard,
    required super.child,
  });

  final StashStore store;

  /// A link's tag clicked, at its offset, linking to the url: its menu.
  final void Function(int offset, String url)? onCard;

  /// The stash's number, the stash made first if it was not yet.
  final Future<int> Function() ensureNote;
  final bool readOnly;

  static StashEditorScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StashEditorScope>();

  @override
  bool updateShouldNotify(StashEditorScope oldWidget) =>
      store != oldWidget.store || readOnly != oldWidget.readOnly;
}

/// What `[[`, `@` and `#` offer in a stash's text: other stashes (by
/// title, or number), projects. Picked, they go in as links: `stash:12`,
/// `project:<path>`, which [open] follows.
class StashRefs {
  const StashRefs({
    required this.stashes,
    required this.projects,
    required this.open,
  });

  final List<({int id, String title})> Function() stashes;
  final List<({String name, String path})> Function() projects;
  final void Function(String href) open;

  static const stashScheme = 'stash:';
  static const projectScheme = 'project:';

  static String stashHref(int id) => '$stashScheme$id';
  static String projectHref(String path) =>
      '$projectScheme${Uri.encodeComponent(path)}';

  /// The stash a link is to; null for another link.
  static int? stashOf(String href) => href.startsWith(stashScheme)
      ? int.tryParse(href.substring(stashScheme.length))
      : null;

  /// The project a link is to; null for another link.
  static String? projectOf(String href) => href.startsWith(projectScheme)
      ? Uri.decodeComponent(href.substring(projectScheme.length))
      : null;
}

/// The colors a selection can be given: the text's, and the background's
/// (CSS names, which the file keeps and other editors read; their colors
/// here follow the theme).
abstract final class StashColors {
  static const text = [
    'red',
    'orange',
    'gold',
    'green',
    'royalblue',
    'purple',
    'gray',
  ];
  static const background = [
    'mistyrose',
    'peachpuff',
    'lightyellow',
    'honeydew',
    'aliceblue',
    'lavender',
    'gainsboro',
  ];

  static Map<String, Color> palette({required bool dark}) => {
    'red': const Color(0xFFE5534B),
    'orange': const Color(0xFFE0823D),
    'gold': const Color(0xFFD4A72C),
    'green': const Color(0xFF57AB5A),
    'royalblue': const Color(0xFF539BF5),
    'purple': const Color(0xFFB083F0),
    'gray': const Color(0xFF8B949E),
    'mistyrose': dark ? const Color(0x55E5534B) : const Color(0xFFFFE1DF),
    'peachpuff': dark ? const Color(0x55E0823D) : const Color(0xFFFFE6CC),
    'lightyellow': dark ? const Color(0x55D4A72C) : const Color(0xFFFFF5B8),
    'honeydew': dark ? const Color(0x5557AB5A) : const Color(0xFFDDF4DE),
    'aliceblue': dark ? const Color(0x55539BF5) : const Color(0xFFDCEBFF),
    'lavender': dark ? const Color(0x55B083F0) : const Color(0xFFECE2FF),
    'gainsboro': dark ? const Color(0x558B949E) : const Color(0xFFE8EAED),
  };
}

/// A stash's text, edited as it shows (see docs/stash.md): no `/` commands;
/// marks are typed as markdown is (`# `, `- `, `[] `, `> `, `**…**`) or
/// picked from the bar that shows over a selection, where AI can also
/// make what is selected clearer. Pictures are pasted or dropped in, and
/// resized by their corners; files are put in (copied up to 200 MB, else
/// linked to); a link pasted alone shows as a card with its page's title.
class StashEditor extends StatefulWidget {
  /// Colors a code block's lines in a language (the app's TextMate, set as
  /// it starts); none under test.
  static CodeBlockColorizer? colorize;

  /// A controller for [document] whose pastes the editor showing it takes
  /// first (pictures, files, links, web pages made markdown).
  static QuillController controllerFor(Document document) {
    late final QuillController controller;
    controller = QuillController(
      document: document,
      selection: const TextSelection.collapsed(offset: 0),
      config: QuillControllerConfig(
        clipboardConfig: QuillClipboardConfig(
          // Web pages are made markdown here, not kept as they were.
          enableExternalRichPaste: false,
          onClipboardPaste: () async =>
              await _pasting[controller]?.call() ?? false,
        ),
      ),
    );
    return controller;
  }

  static final _pasting = Expando<Future<bool> Function()>('stash paste');

  const StashEditor({
    super.key,
    required this.controller,
    required this.store,
    required this.ensureNote,
    this.focusNode,
    this.scrollController,
    this.autofocus = false,
    this.placeholder,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 20),
    this.onPolish,
    this.readOnly = false,
    this.expands = true,
    this.refs,
  });

  /// What `[[`, `@` and `#` offer; nothing without it.
  final StashRefs? refs;

  final QuillController controller;
  final StashStore store;
  final Future<int> Function() ensureNote;
  final FocusNode? focusNode;
  final ScrollController? scrollController;
  final bool autofocus;
  final String? placeholder;
  final EdgeInsets padding;

  /// [text] made clearer (see StashAi.polish); none hides the bar's AI.
  final Future<String?> Function(String text)? onPolish;
  final bool readOnly;
  final bool expands;

  @override
  State<StashEditor> createState() => StashEditorState();
}

class StashEditorState extends State<StashEditor> implements FileDropDelegate {
  final GlobalKey<EditorState> _editorKey = GlobalKey();
  late FocusNode _focus = widget.focusNode ?? FocusNode();
  late ScrollController _scroll = widget.scrollController ?? ScrollController();
  final GlobalKey _stackKey = GlobalKey();

  /// The selection's bounds, in the stack's box, for the bar over (or
  /// under) it; none without one.
  Rect? _barAround;
  bool _polishing = false;

  /// A menu opened from the bar (the model picker, the marks under "…") is
  /// showing: it takes the keyboard, and the bar stays where it is.
  bool _barMenu = false;

  QuillController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_selectionChanged);
    _focus.addListener(_selectionChanged);
    _linkFocus.addListener(_linkFocusChanged);
    _listenToDocument();
    StashEditor._pasting[_controller] = _paste;
  }

  @override
  void didUpdateWidget(StashEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_selectionChanged);
      widget.controller.addListener(_selectionChanged);
      StashEditor._pasting[oldWidget.controller] = null;
      StashEditor._pasting[widget.controller] = _paste;
      _listenToDocument();
      // Another stash's text: what was edited of the last one's goes.
      _linking = false;
      _editingCard = null;
      _caretLink = null;
      _barAround = null;
      _lastCaret = null;
    }
    if (oldWidget.focusNode != widget.focusNode) {
      _focus.removeListener(_selectionChanged);
      if (oldWidget.focusNode == null) _focus.dispose();
      _focus = widget.focusNode ?? FocusNode();
      _focus.addListener(_selectionChanged);
    }
    if (oldWidget.scrollController != widget.scrollController) {
      if (oldWidget.scrollController == null) _scroll.dispose();
      _scroll = widget.scrollController ?? ScrollController();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_selectionChanged);
    StashEditor._pasting[_controller] = null;
    _focus.removeListener(_selectionChanged);
    unawaited(_changes?.cancel());
    _linkFocus.dispose();
    _linkText.dispose();
    if (widget.focusNode == null) _focus.dispose();
    if (widget.scrollController == null) _scroll.dispose();
    super.dispose();
  }

  /// Puts the keyboard in the text, at its end unless [keepSelection].
  void focusEnd({bool keepSelection = false}) {
    if (!keepSelection) {
      final end = math.max(0, _controller.document.length - 1);
      _controller.updateSelection(
        TextSelection.collapsed(offset: end),
        ChangeSource.local,
      );
    }
    _focus.requestFocus();
  }

  void _selectionChanged() {
    _refChanged();
    _keepOffBlocks();
    final selection = _controller.selection;
    Rect? around;
    if (!widget.readOnly &&
        (_focus.hasFocus || _linking || _barMenu) &&
        selection.isValid &&
        !selection.isCollapsed) {
      around = _selectionBounds(selection);
    }
    final link = around == null ? _linkAtCaret() : null;
    // Rebuilt with the selection's styles too: a mark toggled shows at once.
    if (!mounted ||
        (around == null &&
            _barAround == null &&
            link?.href == _caretLink?.href &&
            link?.range == _caretLink?.range)) {
      return;
    }
    setState(() {
      _barAround = around;
      _caretLink = link;
    });
  }

  /// Shows the bar while a menu opened from it shows, and keeps it once
  /// one closes: the editor's focus comes back with the menu.
  void _barMenuShown(bool open) {
    if (!mounted || _barMenu == open) return;
    setState(() => _barMenu = open);
    if (!open) _selectionChanged();
  }

  /// The web link the caret is in, and where its text is (stack's box):
  /// a bar over it opens or edits it, the text typed on as ever.
  ({String href, TextSelection range, Rect around})? _caretLink;

  ({String href, TextSelection range, Rect around})? _linkAtCaret() {
    final selection = _controller.selection;
    if (widget.readOnly ||
        !_focus.hasFocus ||
        _linking ||
        !selection.isValid ||
        !selection.isCollapsed) {
      return null;
    }
    final offset = selection.baseOffset;
    // The character before the caret, or after it at a link's start.
    for (final near in [offset, offset + 1]) {
      final leaf = _controller.document.querySegmentLeafNode(near).leaf;
      final href = leaf?.style.attributes[Attribute.link.key]?.value;
      if (leaf == null || href is! String || _isRef(href)) continue;
      final range = _linkRange(leaf);
      // Just past its end is beside it, not in it.
      if (offset <= range.start && near == offset) continue;
      if (offset >= range.end && near == offset + 1) continue;
      final around = _selectionBounds(range);
      if (around == null) return null;
      return (href: href, range: range, around: around);
    }
    return null;
  }

  /// [selection]'s bounds, in the stack's box.
  Rect? _selectionBounds(TextSelection selection) {
    final editor = _editorKey.currentState?.renderEditor;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (editor == null || stack == null || !editor.attached) return null;
    final points = editor.getEndpointsForSelection(selection);
    if (points.isEmpty) return null;
    final start = editor.getLocalRectForCaret(selection.base);
    final end = editor.getLocalRectForCaret(selection.extent);
    final top = math.min(start.top, end.top);
    final bottom = math.max(start.bottom, end.bottom);
    final left = math.min(points.first.point.dx, points.last.point.dx);
    final right = math.max(points.first.point.dx, points.last.point.dx);
    return Rect.fromPoints(
      stack.globalToLocal(editor.localToGlobal(Offset(left, top))),
      stack.globalToLocal(editor.localToGlobal(Offset(right, bottom))),
    );
  }

  // --- Blocks and the caret ------------------------------------------------------

  /// What stands on a line of its own: the caret never stands beside one.
  static const _blocks = {StashEmbeds.rule, StashEmbeds.code};

  /// Whether the input method is composing text (pinyin…): the text is
  /// not changed under it.
  bool get _composing {
    final composing = _editorKey.currentState?.textEditingValue.composing;
    return composing != null && composing.isValid && !composing.isCollapsed;
  }

  /// Where the caret was last, to tell which way it went.
  int? _lastCaret;

  /// The line at [offset] when it is a block alone (a picture, a card…).
  Line? _blockLine(int offset) {
    final document = _controller.document;
    if (offset < 0 || offset > document.length - 1) return null;
    final node = document.queryChild(offset).node;
    if (node is! Line || node.childCount != 1) return null;
    final only = node.children.single;
    if (only is! Embed || !_blocks.contains(only.value.type)) return null;
    return node;
  }

  /// The caret before the block on the line at [start]: at the end of the
  /// line before it, or on a new one when there is none (or it is a block
  /// too).
  void _caretBefore(int start) {
    if (start > 0 && _blockLine(start - 1) == null) {
      _controller.updateSelection(
        TextSelection.collapsed(offset: start - 1),
        ChangeSource.local,
      );
    } else {
      _controller.replaceText(
        start,
        0,
        '\n',
        TextSelection.collapsed(offset: start),
      );
    }
  }

  /// The caret after the block on the line at [start]: at the start of the
  /// line after it, or on a new one when there is none (or it is a block
  /// too).
  void _caretAfter(int start) {
    final next = start + 2;
    if (next < _controller.document.length && _blockLine(next) == null) {
      _controller.updateSelection(
        TextSelection.collapsed(offset: next),
        ChangeSource.local,
      );
    } else {
      _controller.replaceText(
        start + 1,
        0,
        '\n',
        TextSelection.collapsed(offset: next),
      );
    }
  }

  /// The caret never stands beside a block: it goes on to the line after,
  /// or to the line before when it came up from below.
  void _keepOffBlocks() {
    final selection = _controller.selection;
    if (widget.readOnly || !selection.isValid || !selection.isCollapsed) {
      _lastCaret = null;
      return;
    }
    final offset = selection.baseOffset;
    final line = _blockLine(offset);
    if (line == null || _composing) {
      _lastCaret = offset;
      return;
    }
    final start = line.documentOffset;
    final up = (_lastCaret ?? -1) > start + 1;
    scheduleMicrotask(() {
      if (!mounted || _controller.selection != selection) return;
      up ? _caretBefore(start) : _caretAfter(start);
    });
  }

  /// A click on a block (or below the last, on its line): the caret goes
  /// before it for its upper half, after it for the lower; the block's own
  /// buttons have theirs.
  bool _tapBlock(Offset global) {
    if (widget.readOnly) return false;
    final editor = _editorKey.currentState?.renderEditor;
    if (editor == null || !editor.attached) return false;
    final position = editor.getPositionForOffset(global);
    final line = _blockLine(position.offset);
    if (line == null) return false;
    final start = line.documentOffset;
    final box = editor.childAtPosition(TextPosition(offset: start));
    final top = box.localToGlobal(Offset.zero).dy;
    final below = global.dy > top + box.size.height / 2;
    _focus.requestFocus();
    below ? _caretAfter(start) : _caretBefore(start);
    return true;
  }

  /// Backspace at the start of the line after a block, or Delete at the
  /// end of the one before, removes the block (rather than joining the
  /// lines beside it).
  bool _deleteBlock(LogicalKeyboardKey key) {
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) return false;
    final offset = selection.baseOffset;
    final text = _controller.document.toPlainText();
    final Line? line;
    if (key == LogicalKeyboardKey.backspace) {
      if (offset < 2 || text[offset - 1] != '\n') return false;
      line = _blockLine(offset - 2);
    } else if (key == LogicalKeyboardKey.delete) {
      if (offset >= text.length - 1 || text[offset] != '\n') return false;
      line = _blockLine(offset + 1);
    } else {
      return false;
    }
    if (line == null) return false;
    final start = line.documentOffset;
    _controller.replaceText(
      start,
      2,
      '',
      TextSelection.collapsed(
        offset: key == LogicalKeyboardKey.backspace ? start : offset,
      ),
    );
    return true;
  }

  // --- `[[`, `@` and `#` ---------------------------------------------------------

  _RefTrigger? _ref;
  List<_RefOption> _refOptions = const [];
  int _refHighlighted = 0;

  /// Where the trigger dismissed with Esc starts (it stays dismissed while
  /// typed on).
  int? _refDismissed;

  void _refChanged() {
    final refs = widget.refs;
    final trigger = refs == null || widget.readOnly ? null : _findRef();
    if (trigger == null || trigger.from != _refDismissed) _refDismissed = null;
    final shown = trigger != null && _refDismissed == null;
    final options = shown ? _optionsFor(refs!, trigger) : const <_RefOption>[];
    final visible = shown && options.isNotEmpty;
    if (!visible && _ref == null) return;
    if (!mounted) return;
    setState(() {
      _ref = visible ? trigger : null;
      _refOptions = options;
      _refHighlighted = _refHighlighted.clamp(
        0,
        math.max(0, options.length - 1),
      );
    });
  }

  _RefTrigger? _findRef() {
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed || !_focus.hasFocus) {
      return null;
    }
    final caret = selection.baseOffset;
    final plain = _controller.document.toPlainText();
    if (caret > plain.length) return null;
    final lineStart = plain.lastIndexOf('\n', math.max(0, caret - 1)) + 1;
    if (lineStart > caret) return null;
    final before = plain.substring(lineStart, caret);
    if (RegExp(r'\[\[([^\[\]\n]*)$').firstMatch(before) case final m?) {
      return _RefTrigger(_RefKind.title, lineStart + m.start, caret, m[1]!);
    }
    if (RegExp(r'(?:^|\s)@([^\s@]*)$').firstMatch(before) case final m?) {
      return _RefTrigger(
        _RefKind.project,
        caret - m[1]!.length - 1,
        caret,
        m[1]!,
      );
    }
    if (RegExp(r'(?:^|\s)#([^\s#]+)$').firstMatch(before) case final m?) {
      return _RefTrigger(
        _RefKind.number,
        caret - m[1]!.length - 1,
        caret,
        m[1]!,
      );
    }
    return null;
  }

  List<_RefOption> _optionsFor(StashRefs refs, _RefTrigger trigger) {
    final query = trigger.query.toLowerCase();
    if (trigger.kind == _RefKind.project) {
      return [
        for (final project in refs.projects())
          if (project.name.toLowerCase().contains(query))
            _RefOption(
              label: project.name,
              detail: project.path,
              text: '@${project.name}',
              href: StashRefs.projectHref(project.path),
            ),
      ].take(8).toList();
    }
    return [
      for (final stash in refs.stashes())
        if ('${stash.id}'.startsWith(query) ||
            stash.title.toLowerCase().contains(query))
          _RefOption(
            label: stash.title.isEmpty ? '#${stash.id}' : stash.title,
            detail: '#${stash.id}',
            text: trigger.kind == _RefKind.number || stash.title.isEmpty
                ? '#${stash.id}'
                : stash.title,
            href: StashRefs.stashHref(stash.id),
          ),
    ].take(8).toList();
  }

  void _acceptRef(int index) {
    final trigger = _ref;
    if (trigger == null || index >= _refOptions.length) return;
    final option = _refOptions[index];
    // `]]` typed already after the caret goes too.
    var end = trigger.to;
    final plain = _controller.document.toPlainText();
    if (trigger.kind == _RefKind.title && plain.startsWith(']]', end)) end += 2;
    _controller.compose(
      Delta()
        ..retain(trigger.from)
        ..delete(end - trigger.from)
        ..insert(option.text, {Attribute.link.key: option.href})
        ..insert(' '),
      TextSelection.collapsed(offset: trigger.from + option.text.length + 1),
      ChangeSource.local,
    );
    setState(() {
      _ref = null;
      _refOptions = const [];
      _refHighlighted = 0;
    });
  }

  KeyEventResult? _key(KeyEvent event, Node? node) {
    if (event is KeyUpEvent) return null;
    if (!widget.readOnly && !_composing && _codeKey(event)) {
      return KeyEventResult.handled;
    }
    // Quill's own for these are Material dialogs: a link is put in the
    // bar's field instead, and there is no finding in a stash.
    final keyboard = HardwareKeyboard.instance;
    final command = defaultTargetPlatform == TargetPlatform.macOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (command && !keyboard.isShiftPressed && !keyboard.isAltPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyK) {
        if (!widget.readOnly && !_controller.selection.isCollapsed) _link();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        return KeyEventResult.skipRemainingHandlers;
      }
    }
    if ((_ref == null || _refOptions.isEmpty) &&
        !widget.readOnly &&
        _deleteBlock(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    if (_ref == null || _refOptions.isEmpty) return null;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(
        () => _refHighlighted = (_refHighlighted + 1) % _refOptions.length,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _refHighlighted =
            (_refHighlighted - 1 + _refOptions.length) % _refOptions.length,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.tab) {
      _acceptRef(_refHighlighted);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _refDismissed = _ref?.from;
        _ref = null;
      });
      return KeyEventResult.handled;
    }
    return null;
  }

  /// Under the caret, in the stack's box.
  Offset? _caretBottom() {
    final editor = _editorKey.currentState?.renderEditor;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (editor == null || stack == null || !editor.attached) return null;
    final caret = editor.getLocalRectForCaret(_controller.selection.extent);
    return stack.globalToLocal(editor.localToGlobal(caret.bottomLeft));
  }

  Widget _refMenu(BuildContext context) {
    final at = _caretBottom() ?? Offset.zero;
    return Positioned(
      left: at.dx,
      top: at.dy + 4,
      child: PopIn(
        alignment: Alignment.topLeft,
        offset: const Offset(0, -4),
        child: Container(
          width: 300,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: themeColors['editorSuggestWidget.background'],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: themeColors['editorSuggestWidget.border'],
            ),
            boxShadow: [
              BoxShadow(color: themeColors['widget.shadow'], blurRadius: 16),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, option) in _refOptions.indexed)
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onHover: (_) {
                    if (_refHighlighted != i) {
                      setState(() => _refHighlighted = i);
                    }
                  },
                  child: GestureDetector(
                    onTap: () => _acceptRef(i),
                    child: Container(
                      height: 28,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: i == _refHighlighted
                            ? themeColors['editorSuggestWidget.selectedBackground']
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            option.href.startsWith(StashRefs.projectScheme)
                                ? Codicons.folder
                                : Codicons.note,
                            size: 13,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              option.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              option.detail,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                color: AppColors.textFaint,
                                fontSize: 11.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A link ⌘-clicked (or clicked, read only): followed at once.
  void _openLink(String href) {
    if (_isRef(href)) {
      widget.refs?.open(href);
      return;
    }
    unawaited(openExternal(href));
  }

  /// The link's text selected, edited in the bar.
  void _editLink(String href, TextSelection range) {
    _controller.updateSelection(range, ChangeSource.local);
    _focus.requestFocus();
    _link(current: href);
  }

  /// Over the link the caret is in: where it goes, opened or edited.
  Widget _linkBar(BuildContext context) {
    final link = _caretLink!;
    final l10n = context.l10n;
    return _SelectionBar(
      around: link.around,
      children: [
        _BarButton(
          icon: Codicons.linkExternal,
          label: _shortUrl(link.href),
          tooltip: l10n.stashLinkOpen,
          onTap: () => _openLink(link.href),
        ),
        _BarButton(
          icon: Codicons.edit,
          tooltip: l10n.stashLinkEdit,
          onTap: () => _editLink(link.href, link.range),
        ),
      ],
    );
  }

  /// [url] without its scheme, cut short.
  static String _shortUrl(String url) {
    final bare = url.replaceFirst(RegExp(r'^https?://'), '');
    return bare.length > 40 ? '${bare.substring(0, 39)}…' : bare;
  }

  static bool _isRef(String href) =>
      StashRefs.stashOf(href) != null || StashRefs.projectOf(href) != null;

  /// Where the pointer last went down, the window's: where a link's menu
  /// opens.
  Offset? _pressedAt;

  /// A link clicked: open it, or edit it in the bar. [range] is the link's
  /// text; [card] the offset of the link's tag, for one.
  Future<void> _linkMenu(String href, {TextSelection? range, int? card}) async {
    final l10n = context.l10n;
    final at = _pressedAt ?? Offset.zero;
    await showIdeMenu(
      context,
      anchor: Rect.fromLTWH(at.dx, at.dy, 1, 1),
      entries: [
        IdeMenuAction(l10n.stashLinkOpen, onSelected: () => _openLink(href)),
        if (!widget.readOnly)
          IdeMenuAction(
            l10n.stashLinkEdit,
            onSelected: () {
              _editingCard = card;
              _editLink(
                href,
                range ??
                    TextSelection(baseOffset: card!, extentOffset: card + 1),
              );
            },
          ),
      ],
    );
  }

  /// The text of the link [leaf] is in: the leaves beside it with the same
  /// link.
  static TextSelection _linkRange(Leaf leaf) {
    final href = leaf.style.attributes[Attribute.link.key]?.value;
    bool same(Object? node) =>
        node is Leaf &&
        node.style.attributes[Attribute.link.key]?.value == href;
    var first = leaf;
    var last = leaf;
    while (same(first.previous)) {
      first = first.previous! as Leaf;
    }
    while (same(last.next)) {
      last = last.next! as Leaf;
    }
    return TextSelection(
      baseOffset: first.documentOffset,
      extentOffset: last.documentOffset + last.length,
    );
  }

  // --- Files dragged in ----------------------------------------------------------

  /// Where files dragged over the text would go: shown as a caret.
  int? _dropAt;

  int _dropOffset(Offset position) {
    final end = _controller.document.length - 1;
    final editor = _editorKey.currentState?.renderEditor;
    if (editor == null || !editor.attached) return end;
    final local = editor.globalToLocal(position);
    if (!(Offset.zero & editor.size).contains(local)) return end;
    return editor.getPositionForOffset(position).offset.clamp(0, end);
  }

  @override
  void fileDragOver(Offset position, List<ComposerFile> files) {
    if (widget.readOnly) return;
    final at = _dropOffset(position);
    if (at != _dropAt) setState(() => _dropAt = at);
  }

  @override
  void fileDragLeave() {
    if (_dropAt != null) setState(() => _dropAt = null);
  }

  @override
  void fileDrop(Offset position, List<ComposerFile> files) {
    if (widget.readOnly) return;
    final at = _dropAt ?? _dropOffset(position);
    setState(() => _dropAt = null);
    _controller.updateSelection(
      TextSelection.collapsed(offset: at),
      ChangeSource.local,
    );
    _focus.requestFocus();
    unawaited(insertFiles(files));
  }

  /// The caret's box at [offset], in the stack's: as StashCaret draws it.
  Rect? _caretBox(int offset, double height) {
    final editor = _editorKey.currentState?.renderEditor;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (editor == null || stack == null || !editor.attached) return null;
    final position = TextPosition(offset: offset);
    final line = editor.getLocalRectForCaret(position);
    final x = editor
        .getEndpointsForSelection(TextSelection.fromPosition(position))
        .first
        .point
        .dx;
    final origin = stack.globalToLocal(
      editor.localToGlobal(Offset(x, line.top)),
    );
    final shown = math.min(height, line.height);
    return Rect.fromLTWH(
      origin.dx,
      origin.dy + (line.height - shown) / 2,
      2,
      shown,
    );
  }

  /// The caret's height at [offset]: its line's text's.
  double _caretHeight(int offset) {
    final header = _controller.document
        .collectStyle(offset, 0)
        .attributes[Attribute.header.key]
        ?.value;
    final size = switch (header) {
      1 => 20.0,
      2 => 17.0,
      3 => 15.0,
      _ => 14.0,
    };
    return (size * 1.2).roundToDouble();
  }

  // --- Tags at the ends of lines ---------------------------------------------------

  StreamSubscription<DocChange>? _changes;

  /// Flutter lays a line out taller when an inline widget ends it, and the
  /// caret after it hangs off: a tag never ends a line (as the chat's input
  /// has it), a space after it. Returns whether it put one.
  bool _padTrailingTags() {
    if (widget.readOnly || _composing) return false;
    final ops = _controller.document.toDelta().toList();
    var offset = 0;
    for (var i = 0; i < ops.length; i++) {
      final length = ops[i].length ?? 0;
      final data = ops[i].data;
      if (data is Map &&
          !data.containsKey(StashEmbeds.rule) &&
          !data.containsKey(StashEmbeds.code)) {
        final next = i + 1 < ops.length ? ops[i + 1].data : null;
        if (next == null || (next is String && next.startsWith('\n'))) {
          // Not the user's: nothing to undo (the markdown drops it too).
          final history = _controller.document.history;
          final ignoring = history.ignoreChange;
          history.ignoreChange = true;
          try {
            _controller.replaceText(
              offset + length,
              0,
              ' ',
              _controller.selection,
            );
          } finally {
            history.ignoreChange = ignoring;
          }
          return true;
        }
      }
      offset += length;
    }
    return false;
  }

  void _listenToDocument() {
    unawaited(_changes?.cancel());
    _changes = _controller.document.changes.listen((_) {
      scheduleMicrotask(() {
        if (mounted) _padTrailingTags();
      });
    });
    scheduleMicrotask(() {
      if (mounted) while (_padTrailingTags()) {}
    });
  }

  // --- Code blocks ------------------------------------------------------------------

  /// Enter after ```` ```lang ```` starts a code block; Enter on a code
  /// block's empty last line leaves it; down from the text's last line, a
  /// code block's, makes a line after it to go on in.
  bool _codeKey(KeyEvent event) {
    final selection = _controller.selection;
    if (!selection.isCollapsed) return false;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed ||
        keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return false;
    }
    final key = event.logicalKey;
    final at = _controller.document.queryChild(selection.baseOffset);
    final line = at.node;
    if (line is! Line) return false;
    final text = line.toPlainText().replaceAll('\n', '');
    final start = line.documentOffset;
    final code = line.style.attributes[Attribute.codeBlock.key];
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (code == null) {
        final fence = RegExp(r'^```([\w+#.-]*)$').firstMatch(text);
        if (fence == null || selection.baseOffset != start + text.length) {
          return false;
        }
        final language = fence[1]!;
        _controller
          ..replaceText(
            start,
            text.length,
            '',
            TextSelection.collapsed(offset: start),
          )
          ..formatText(
            start,
            0,
            Attribute.fromKeyValue(
              Attribute.codeBlock.key,
              language.isEmpty ? true : language,
            ),
          );
        return true;
      }
      final next = line.next;
      final last =
          next is! Line ||
          next.style.attributes[Attribute.codeBlock.key]?.value != code.value;
      if (text.isNotEmpty || !last) return false;
      _controller.formatText(
        start,
        0,
        Attribute.clone(Attribute.codeBlock, null),
      );
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown && code != null) {
      final document = _controller.document;
      if (start + line.length < document.length) return false;
      final end = document.length - 1;
      _controller.compose(
        Delta()
          ..retain(end + 1)
          ..insert('\n'),
        TextSelection.collapsed(offset: end + 1),
        ChangeSource.local,
      );
      // The new line is the code block's (it took the last one's place):
      // made a paragraph, the caret in it.
      _controller
        ..formatText(end + 1, 0, Attribute.clone(Attribute.codeBlock, null))
        ..updateSelection(
          TextSelection.collapsed(offset: end + 1),
          ChangeSource.local,
        );
      return true;
    }
    return false;
  }

  /// What each code line is colored as, by its language and text: those
  /// colored last, kept while the block is colored again.
  final Map<String, List<TextSpan>> _lineColors = {};

  /// The blocks asked to be colored (by language and code).
  final Set<String> _colorAsked = {};

  InlineSpan _codeSpan(
    BuildContext context,
    Node node,
    int textOffset,
    String text,
    TextStyle? style,
    GestureRecognizer? recognizer,
  ) {
    InlineSpan plain() =>
        defaultSpanBuilder(context, node, textOffset, text, style, recognizer);
    final line = node.parent;
    if (line is! Line) return plain();
    final language = line.style.attributes[Attribute.codeBlock.key]?.value;
    if (language is! String || language.isEmpty) return plain();
    _colorSoon(language, line.parent);
    final full = line.toPlainText().replaceAll('\n', '');
    final colors = _lineColors['$language\u0000$full'];
    if (colors == null) return plain();
    // The part of the line this node's text is.
    final from = node.offset + textOffset;
    final to = from + text.length;
    final pieces = <InlineSpan>[];
    var at = 0;
    for (final span in colors) {
      final piece = span.text ?? '';
      final start = math.max(at, from);
      final end = math.min(at + piece.length, to);
      if (start < end) {
        pieces.add(
          TextSpan(
            text: piece.substring(start - at, end - at),
            style: (style ?? const TextStyle()).copyWith(
              color: span.style?.color,
              fontStyle: span.style?.fontStyle,
              fontWeight: span.style?.fontWeight,
            ),
          ),
        );
      }
      at += piece.length;
    }
    // Colored for other text than this (typed meanwhile): plain.
    if (pieces.fold<int>(0, (n, span) => n + (span as TextSpan).text!.length) !=
        text.length) {
      return plain();
    }
    return TextSpan(style: style, recognizer: recognizer, children: pieces);
  }

  /// Colors [block]'s code in [language] a moment after it changes.
  void _colorSoon(String language, Node? block) {
    final colorize = StashEditor.colorize;
    if (colorize == null || block is! Block) return;
    final code = [
      for (final line in block.children)
        line.toPlainText().replaceAll('\n', ''),
    ].join('\n');
    final key = '$language\u0000$code';
    if (!_colorAsked.add(key)) return;
    Timer(const Duration(milliseconds: 120), () async {
      final lines = await colorize(language, code);
      if (!mounted || lines == null) return;
      final texts = code.split('\n');
      setState(() {
        for (final (i, spans) in lines.indexed) {
          if (i < texts.length) {
            _lineColors['$language\u0000${texts[i]}'] = spans;
          }
        }
      });
    });
  }

  // --- Pasting and dropping ----------------------------------------------------

  /// Pictures and files on the clipboard go in as such; a lone link as a
  /// card; a web page (or a document) as the markdown it makes; text that
  /// is markdown as what it says. Other text Quill pastes itself.
  Future<bool> _paste() async {
    if (widget.readOnly) return true;
    // Copied here (or in another stash): as it was, its pictures and files
    // with it.
    final copied = _controller.pasteDelta;
    final raw = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (raw != null &&
        raw.isNotEmpty &&
        raw == _controller.pastePlainText &&
        copied.isNotEmpty &&
        copied.toList().every(
          (op) =>
              op.data is! Map ||
              (op.data! as Map).keys.every(
                (key) => '$key'.startsWith('stash-'),
              ),
        )) {
      final selection = _controller.selection;
      final after = TextSelection.collapsed(
        offset: selection.start + _textLength(copied),
      );
      _controller
        ..compose(
          (Delta()
                ..retain(selection.start)
                ..delete(selection.end - selection.start))
              .concat(copied),
          after,
          ChangeSource.local,
        )
        ..updateSelection(after, ChangeSource.local);
      return true;
    }
    final files = await WindowControls.readPasteboardFiles();
    if (files.isNotEmpty) {
      await insertFiles(files);
      return true;
    }
    final images = await WindowControls.readPasteboardImages();
    if (images.isNotEmpty) {
      for (final image in images) {
        await insertImageBytes(image.bytes, name: image.name);
      }
      return true;
    }
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text != null &&
        RegExp(r'^https?://\S+$').hasMatch(text) &&
        _controller.selection.isCollapsed &&
        _lineIsEmpty()) {
      insertCard(text);
      return true;
    }
    if (text != null && !text.contains('```') && looksLikeCode(text)) {
      var fence = '```';
      while (text.contains(fence)) {
        fence += '`';
      }
      insertMarkdown('$fence\n$text\n$fence');
      return true;
    }
    final html = await ClipboardServiceProvider.instance.getHtmlText();
    if (html != null && html.trim().isNotEmpty) {
      final markdown = stashHtmlToMarkdown(html);
      if (markdown.isNotEmpty) {
        insertMarkdown(markdown);
        return true;
      }
    }
    if (text != null && _looksLikeMarkdown(text)) {
      insertMarkdown(text);
      return true;
    }
    return false;
  }

  /// Lines of code (from an editor, a terminal): two lines or more that
  /// look like code's for sure, or one and the rest like code's too.
  /// Prose (`for the record…`) and markdown's lists (indented as code is)
  /// are not.
  @visibleForTesting
  static bool looksLikeCode(String text) {
    final lines = text
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return false;
    // Ends and words only code has.
    final sure = RegExp(
      r'[;{}]\s*$|=>|\)\s*\{|^\s*(#include|#import|import\s+[\w.{*"'
      "'"
      r']|from\s+[\w.]+\s+import|export\s|def\s+\w+\s*\(|class\s+\w+|fn\s+\w+|func\s+\w+|function\s*\w*\s*\(|(const|let|var|final)\s+\w+\s*[=:]|(public|private|protected|static)\s|package\s+[\w.]+|use\s+\w+::|struct\s+\w+|enum\s+\w+|interface\s+\w+)',
    );
    // Lines that go on as code does: indented, or a statement's start.
    final likely = RegExp(
      r'^(\s{2,}|\t)\S|^\s*(if|for|while|return|switch|case|else|elif|try|catch|await|async)\b.*[:(]',
    );
    final markdownItem = RegExp(r'^\s*([-*+]|\d+[.)])\s|^\s*#{1,6}\s|^\s*>');
    var sureLines = 0;
    var codeLines = 0;
    for (final line in lines) {
      if (sure.hasMatch(line)) {
        sureLines++;
        codeLines++;
      } else if (!markdownItem.hasMatch(line) && likely.hasMatch(line)) {
        codeLines++;
      }
    }
    return sureLines >= 2 || (sureLines >= 1 && codeLines == lines.length);
  }

  static bool _looksLikeMarkdown(String text) => RegExp(
    r'(^|\n)\s{0,3}(#{1,6}\s|[-*+]\s|\d+[.)]\s|>\s?|```|\|.*\||\$\$)|\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^)\s]+\)|!\[',
  ).hasMatch(text);

  /// [markdown] in place of the selection, as what it says.
  void insertMarkdown(String markdown) {
    final pasted = stashMarkdownToDelta(markdown);
    final ops = pasted.toList();
    bool isBlock(Operation op) =>
        op.data is Map && _blocks.any((op.data! as Map).containsKey);
    // A code block's line: its own, as a block's.
    bool isCodeLine(Operation op) =>
        op.data is String &&
        (op.data! as String).contains('\n') &&
        (op.attributes?.containsKey(Attribute.codeBlock.key) ?? false);
    final firstLine = ops
        .where(
          (op) => op.data is! String || (op.data! as String).contains('\n'),
        )
        .firstOrNull;
    final selection = _controller.selection;
    final start = selection.isValid
        ? selection.start
        : _controller.document.length - 1;
    final plain = _controller.document.toPlainText();
    // A block (code…) on a line of its own: the line it is put in broken
    // before it…
    if (ops.isNotEmpty &&
        (isBlock(ops.first) || (firstLine != null && isCodeLine(firstLine))) &&
        start > 0 &&
        plain[start - 1] != '\n') {
      ops.insert(0, Operation.insert('\n'));
    }
    // …and after it, the rest of the line on the next.
    final endsWithBlock =
        ops.length > 1 && ops.last.data == '\n' && isBlock(ops[ops.length - 2]);
    // Its last line goes on with the line it is put in, unless it is
    // a heading, an item, a block…
    if (endsWithBlock) {
      // Kept.
    } else if (ops.isNotEmpty &&
        ops.last.data == '\n' &&
        (ops.last.attributes == null || ops.last.attributes!.isEmpty) &&
        ops.length > 1) {
      ops.removeLast();
    } else if (ops.isNotEmpty &&
        ops.last.data is String &&
        (ops.last.data as String).endsWith('\n') &&
        (ops.last.attributes == null || ops.last.attributes!.isEmpty)) {
      final last = ops.removeLast();
      final text = (last.data as String);
      if (text.length > 1) {
        ops.add(Operation.insert(text.substring(0, text.length - 1)));
      }
    }
    final length = selection.isValid ? selection.end - selection.start : 0;
    final change = Delta()
      ..retain(start)
      ..delete(length);
    var inserted = 0;
    for (final op in ops) {
      change.push(op);
      inserted += op.length ?? 0;
    }
    final after = TextSelection.collapsed(offset: start + inserted);
    // `compose` leaves the caret before what it put in: after it.
    _controller
      ..compose(change, after, ChangeSource.local)
      ..updateSelection(after, ChangeSource.local);
  }

  bool _lineIsEmpty() {
    final offset = _controller.selection.baseOffset;
    final line = _controller.document.queryChild(offset).node;
    return line is Line && line.toPlainText().trim().isEmpty;
  }

  /// Puts [bytes], a picture, in at the caret, kept in the stash's folder.
  Future<void> insertImageBytes(Uint8List bytes, {String? name}) async {
    final scope = widget.store;
    final id = await widget.ensureNote();
    final path = await scope.addImage(id, bytes, name: name);
    _insertInline(StashEmbeds.image, {'src': path});
  }

  /// Puts [files] in at the caret: pictures as pictures, others as links
  /// to them (copied into the stash's folder up to 200 MB; past it the
  /// user is asked whether to copy it anyway).
  Future<void> insertFiles(List<ComposerFile> files) async {
    final id = await widget.ensureNote();
    for (final file in files) {
      final added = await widget.store.addFile(
        id,
        file.path,
        copyAnyway: false,
      );
      if (added == null && !file.directory) continue;
      var path = added?.path ?? file.path;
      if (added != null && !added.copied && mounted) {
        final l10n = context.l10n;
        final choice = await showIdeDialog(
          context,
          message: l10n.stashBigFileTitle(file.name),
          detail: l10n.stashBigFileDetail,
          buttons: [l10n.stashBigFileLink, l10n.stashBigFileCopy],
          type: IdeDialogType.question,
        );
        // Cancelled: not put in.
        if (choice == null || choice > 1) continue;
        if (choice == 1) {
          path =
              (await widget.store.addFile(
                id,
                file.path,
                copyAnyway: true,
              ))?.path ??
              path;
        }
      }
      if (file.maybeImage && !file.directory) {
        _insertInline(StashEmbeds.image, {'src': path});
      } else {
        _insertInline(StashEmbeds.file, {'path': path, 'name': file.name});
      }
    }
  }

  /// A card for [url] at the caret, titled once its page says.
  void insertCard(String url) {
    _insertInline(StashEmbeds.card, {'url': url, 'title': url});
    unawaited(_titleCard(url));
  }

  Future<void> _titleCard(String url) async {
    final title = await _forgeTitle(url) ?? await io.fetchPageTitle(url);
    if (title == null || !mounted) return;
    replaceEmbedWhere(
      (type, data) =>
          type == StashEmbeds.card &&
          data['url'] == url &&
          data['title'] == url,
      {'url': url, 'title': title},
    );
  }

  /// An issue's or pull request's card's title (`o/r#3 Its title`), as
  /// its forge says, where it can be asked.
  Future<String?> _forgeTitle(String url) async {
    final forge = StashForge.current;
    final ref = forge?.refOf(url);
    final api = ref == null ? null : forge!.accounts.apiOf(ref);
    if (ref == null || api == null) return null;
    try {
      return '${ref.fullTag} ${(await api.item(ref)).title}';
    } on Object {
      return null;
    }
  }

  void _insertInline(String type, Map<String, Object?> data) {
    final selection = _controller.selection;
    final index = selection.isValid
        ? selection.start
        : _controller.document.length - 1;
    final length = selection.isValid ? selection.end - selection.start : 0;
    // The tag and the space after it in one edit, undone as one.
    _controller.compose(
      Delta()
        ..retain(index)
        ..delete(length)
        ..insert(StashEmbeds.of(type, data).toJson())
        ..insert(' '),
      TextSelection.collapsed(offset: index + 2),
      ChangeSource.local,
    );
    // `compose` leaves the caret where it was, before the tag: after it.
    _controller.updateSelection(
      TextSelection.collapsed(offset: index + 2),
      ChangeSource.local,
    );
  }

  /// The first embed [test] picks takes [data] in its place.
  void replaceEmbedWhere(
    bool Function(String type, Map<String, Object?> data) test,
    Map<String, Object?> data,
  ) {
    var offset = 0;
    for (final op in _controller.document.toDelta().toList()) {
      final value = op.data;
      if (value is Map && value.length == 1) {
        final type = '${value.keys.first}';
        if (test(type, StashEmbeds.data(value.values.first))) {
          replaceEmbedAt(offset, type, data);
          return;
        }
      }
      offset += op.length ?? 0;
    }
  }

  /// The embed at [offset] takes [data] (keeping the selection).
  void replaceEmbedAt(int offset, String type, Map<String, Object?> data) {
    final selection = _controller.selection;
    _controller.replaceText(offset, 1, StashEmbeds.of(type, data), selection);
  }

  // --- The selection's bar -----------------------------------------------------

  bool _has(Attribute attribute) {
    final style = _controller.getSelectionStyle();
    final value = style.attributes[attribute.key];
    if (value == null) return false;
    return attribute.value == null || value.value == attribute.value;
  }

  void _toggle(Attribute attribute) {
    _controller.formatSelection(
      _has(attribute) ? Attribute.clone(attribute, null) : attribute,
    );
    _focus.requestFocus();
  }

  void _color(String key, String? name) {
    _controller.formatSelection(Attribute.fromKeyValue(key, name));
    _focus.requestFocus();
  }

  /// The link typed in the bar, in place of its buttons, while one is.
  bool _linking = false;
  final TextEditingController _linkText = TextEditingController();
  final FocusNode _linkFocus = FocusNode();

  /// The offset of the link's tag being edited, for one.
  int? _editingCard;

  void _link({String? current}) {
    _linkText.text =
        current ??
        _controller.getSelectionStyle().attributes[Attribute.link.key]?.value
            as String? ??
        '';
    _linkText.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _linkText.text.length,
    );
    setState(() => _linking = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_linking) _linkFocus.requestFocus();
    });
  }

  /// The link typed, on the selection (none for an empty one); back to the
  /// text either way.
  void _endLink({required bool apply}) {
    if (!_linking) return;
    final card = _editingCard;
    _editingCard = null;
    final href = _linkText.text.trim();
    if (apply && card != null) {
      if (href.isNotEmpty) {
        replaceEmbedAt(card, StashEmbeds.card, {'url': href, 'title': href});
        unawaited(_titleCard(href));
      }
      _controller.updateSelection(
        TextSelection.collapsed(offset: card + 1),
        ChangeSource.local,
      );
    } else if (apply) {
      _controller.formatSelection(
        href.isEmpty
            ? Attribute.clone(Attribute.link, null)
            : LinkAttribute(href),
      );
    }
    setState(() => _linking = false);
    _focus.requestFocus();
  }

  /// Clicked elsewhere: what was typed is dropped.
  void _linkFocusChanged() {
    if (_linking && !_linkFocus.hasFocus) {
      _editingCard = null;
      setState(() => _linking = false);
      _selectionChanged();
    }
  }

  Widget _linkField(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Codicons.link, size: 14, color: AppColors.textMuted),
      const SizedBox(width: 6),
      SizedBox(
        width: 240,
        child: IdeInputBox(
          controller: _linkText,
          focusNode: _linkFocus,
          placeholder: 'https://',
          fontSize: 12.5,
          semanticsLabel: context.l10n.stashLinkTitle,
          onSubmitted: (_) => _endLink(apply: true),
          shortcuts: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                _endLink(apply: false),
          },
        ),
      ),
      const SizedBox(width: 2),
      _BarButton(
        icon: Codicons.check,
        tooltip: context.l10n.commonOk,
        onTap: () => _endLink(apply: true),
      ),
    ],
  );

  void _clearFormat() {
    for (final key in const [
      'bold',
      'italic',
      'underline',
      'strike',
      'code',
      'color',
      'background',
      'link',
    ]) {
      _controller.formatSelection(Attribute.fromKeyValue(key, null));
    }
    _focus.requestFocus();
  }

  /// Its text as a model is given it (see [stashTextPart]).
  StashTextPart? get textPart =>
      stashTextPart(_controller.document, widget.store.absolute);

  /// Its text, given to a model as [asked] ([textPart]), [reply] in its
  /// place: a step Undo takes back. Whether it was: not when the text is no
  /// longer [asked].
  bool rewrite(String asked, String reply) {
    final rewritten = stashTextRewrite(
      _controller.document,
      asked,
      reply,
      widget.store.absolute,
    );
    if (rewritten == null) return false;
    final after = TextSelection.collapsed(offset: rewritten.length);
    _controller
      ..compose(rewritten.change, after, ChangeSource.local)
      ..updateSelection(after, ChangeSource.local);
    return true;
  }

  Future<void> _polish() async {
    final polish = widget.onPolish;
    final selection = _controller.selection;
    if (polish == null || selection.isCollapsed || _polishing) return;
    final slice = _controller.document.toDelta().slice(
      selection.start,
      selection.end,
    );
    final asked = stashTextForModel(slice, widget.store.absolute);
    if (asked.text.trim().isEmpty) return;
    setState(() => _polishing = true);
    try {
      final String? better;
      try {
        better = await polish(asked.text);
      } on StashAiException catch (error) {
        if (!mounted) return;
        final l10n = context.l10n;
        await showIdeDialog(
          context,
          message: l10n.stashPolishFailed(
            error.message ?? l10n.stashAiNoAnswer,
          ),
          buttons: [l10n.commonOk],
          cancel: null,
          type: IdeDialogType.error,
        );
        return;
      }
      if (better == null || !mounted) return;
      // Only if the text is as it was when asked.
      final document = _controller.document;
      if (selection.end > document.length - 1 ||
          document.toDelta().slice(selection.start, selection.end) != slice) {
        return;
      }
      final replaced = stashTextFromModel(
        better,
        asked.attachments,
        endsLine: switch (slice.toList().lastOrNull?.data) {
          final String last => last.endsWith('\n'),
          _ => false,
        },
      );
      final after = TextSelection(
        baseOffset: selection.start,
        extentOffset: selection.start + _textLength(replaced),
      );
      _controller
        ..compose(
          (Delta()
                ..retain(selection.start)
                ..delete(selection.end - selection.start))
              .concat(replaced),
          after,
          ChangeSource.local,
        )
        ..updateSelection(after, ChangeSource.local);
    } finally {
      if (mounted) setState(() => _polishing = false);
    }
  }

  Widget _bar(BuildContext context, Rect around) {
    final l10n = context.l10n;
    final list = _controller
        .getSelectionStyle()
        .attributes[Attribute.list.key]
        ?.value;
    Widget button(
      IconData icon,
      String tip,
      VoidCallback onTap, {
      bool active = false,
    }) => _BarButton(icon: icon, tooltip: tip, onTap: onTap, active: active);
    // What is used most; the rest under "…".
    final items = <Widget>[
      button(
        Codicons.bold,
        l10n.stashFormatBold,
        () => _toggle(Attribute.bold),
        active: _has(Attribute.bold),
      ),
      button(
        Codicons.italic,
        l10n.stashFormatItalic,
        () => _toggle(Attribute.italic),
        active: _has(Attribute.italic),
      ),
      button(
        Codicons.strikethrough,
        l10n.stashFormatStrike,
        () => _toggle(Attribute.strikeThrough),
        active: _has(Attribute.strikeThrough),
      ),
      button(
        Codicons.code,
        l10n.stashFormatCode,
        () => _toggle(Attribute.inlineCode),
        active: _has(Attribute.inlineCode),
      ),
      button(
        Codicons.link,
        l10n.stashFormatLink,
        _link,
        active: _has(Attribute.link),
      ),
      _ColorButton(
        tooltip: l10n.stashFormatColor,
        onPick: (key, name) => _color(key, name),
      ),
      const _BarDivider(),
      button(
        Codicons.listUnordered,
        l10n.stashFormatBullets,
        () => _toggle(Attribute.ul),
        active: list == 'bullet',
      ),
      button(
        Codicons.checklist,
        l10n.stashFormatTasks,
        () => _toggle(Attribute.unchecked),
        active: list == 'checked' || list == 'unchecked',
      ),
      Builder(
        builder: (context) => _BarButton(
          icon: Codicons.ellipsis,
          tooltip: l10n.stashFormatMore,
          active: _moreActive(),
          onTap: () {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            unawaited(
              _more(context, box.localToGlobal(Offset.zero) & box.size),
            );
          },
        ),
      ),
      if (widget.onPolish != null) ...[
        const _BarDivider(),
        Builder(
          builder: (context) => _BarButton(
            icon: Codicons.sparkle,
            label: _polishing ? l10n.stashPolishing : l10n.stashPolish,
            tooltip: l10n.stashPolishHint,
            onTap: () {
              if (anchorOf(context) case final anchor?) {
                unawaited(withActionsModel(context, anchor, _polish));
              }
            },
            busy: _polishing,
          ),
        ),
        Builder(
          builder: (context) => _BarButton(
            icon: Codicons.chevronDown,
            tooltip: l10n.aiModelTooltip(
              actionsModelName(l10n, ModelProviders.current) ??
                  l10n.aiModelNone,
            ),
            onTap: () {
              if (anchorOf(context) case final anchor?) {
                unawaited(pickActionsModel(context, anchor));
              }
            },
          ),
        ),
      ],
    ];
    return _SelectionBar(
      around: around,
      children: _linking ? [_linkField(context)] : items,
    );
  }

  /// The bar, told when a menu opened from it shows and hides: while one
  /// does, the bar stays (see [_barMenuShown]).
  Widget _barWithMenus(BuildContext context, Rect around) => IdeMenuAnchorScope(
    onMenu: _barMenuShown,
    child: _bar(context, around),
  );

  /// Whether the selection has one of the marks under "…".
  bool _moreActive() {
    final attributes = _controller.getSelectionStyle().attributes;
    return attributes.containsKey(Attribute.header.key) ||
        attributes[Attribute.list.key]?.value == 'ordered' ||
        attributes.containsKey(Attribute.blockQuote.key) ||
        attributes.containsKey(Attribute.underline.key);
  }

  /// The marks used less, in a menu under "…": [from] the button's context,
  /// under the bar's scope (see [_barWithMenus]).
  Future<void> _more(BuildContext from, Rect anchor) async {
    final l10n = from.l10n;
    final attributes = _controller.getSelectionStyle().attributes;
    final header = attributes[Attribute.header.key]?.value;
    final list = attributes[Attribute.list.key]?.value;
    await showIdeMenu(
      from,
      anchor: anchor,
      entries: [
        IdeMenuAction(
          l10n.stashFormatHeading1,
          checked: header == 1,
          onSelected: () => _toggle(Attribute.h1),
        ),
        IdeMenuAction(
          l10n.stashFormatHeading2,
          checked: header == 2,
          onSelected: () => _toggle(Attribute.h2),
        ),
        IdeMenuAction(
          l10n.stashFormatHeading3,
          checked: header == 3,
          onSelected: () => _toggle(Attribute.h3),
        ),
        const IdeMenuSeparator(),
        IdeMenuAction(
          l10n.stashFormatNumbers,
          checked: list == 'ordered',
          onSelected: () => _toggle(Attribute.ol),
        ),
        IdeMenuAction(
          l10n.stashFormatQuote,
          checked: attributes.containsKey(Attribute.blockQuote.key),
          onSelected: () => _toggle(Attribute.blockQuote),
        ),
        IdeMenuAction(
          l10n.stashFormatCodeBlock,
          checked: attributes.containsKey(Attribute.codeBlock.key),
          onSelected: () {
            _controller.formatSelection(
              attributes.containsKey(Attribute.codeBlock.key)
                  ? Attribute.clone(Attribute.codeBlock, null)
                  : Attribute.codeBlock,
            );
            _focus.requestFocus();
          },
        ),
        IdeMenuAction(
          l10n.stashFormatUnderline,
          checked: attributes.containsKey(Attribute.underline.key),
          onSelected: () => _toggle(Attribute.underline),
        ),
        const IdeMenuSeparator(),
        IdeMenuAction(l10n.stashFormatClear, onSelected: _clearFormat),
      ],
    );
    // Back in the text, its selection as it was.
    if (mounted) _focus.requestFocus();
  }

  // --- Building ----------------------------------------------------------------

  DefaultStyles _styles(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        color: AppColors.text,
        fontSize: 14,
        height: 1.55,
        // Glyphs centered in the line box, as the caret is (see
        // StashCaret).
        leadingDistribution: TextLeadingDistribution.even,
      ),
    );
    final dark = themeColors.dark;
    DefaultTextBlockStyle block(
      TextStyle style, {
      double top = 0,
      double bottom = 0,
      BoxDecoration? decoration,
      double left = 0,
    }) => DefaultTextBlockStyle(
      base.merge(style),
      HorizontalSpacing(left, 0),
      VerticalSpacing(top, bottom),
      VerticalSpacing.zero,
      decoration,
    );
    return DefaultStyles(
      paragraph: block(const TextStyle()),
      h1: block(
        TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
          height: 1.4,
        ),
        top: 8,
        bottom: 4,
      ),
      h2: block(
        TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
          height: 1.4,
        ),
        top: 6,
        bottom: 2,
      ),
      h3: block(
        TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
          height: 1.4,
        ),
        top: 4,
      ),
      bold: const TextStyle(fontWeight: FontWeight.w600),
      italic: const TextStyle(fontStyle: FontStyle.italic),
      underline: const TextStyle(decoration: TextDecoration.underline),
      strikeThrough: const TextStyle(decoration: TextDecoration.lineThrough),
      link: TextStyle(
        color: themeColors['textLink.foreground'],
        decoration: TextDecoration.underline,
        decorationColor: themeColors['textLink.foreground'].withValues(
          alpha: 0.4,
        ),
      ),
      inlineCode: InlineCodeStyle(
        style: AppFonts.uiCodeStyle(12.5).copyWith(color: AppColors.inlineCode),
        backgroundColor: AppColors.inlineCodeBackground,
        radius: const Radius.circular(4),
      ),
      // As the chat's code blocks are: typed in, in place.
      code: DefaultTextBlockStyle(
        base.merge(
          AppFonts.uiCodeStyle(12.5)
              .copyWith(color: AppColors.text, height: 1.5),
        ),
        HorizontalSpacing.zero,
        const VerticalSpacing(6, 6),
        VerticalSpacing.zero,
        BoxDecoration(
          color: themeColors['textCodeBlock.background'],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: themeColors['chat.requestBorder']),
        ),
      ),
      quote: block(
        TextStyle(color: AppColors.textMuted),
        left: 12,
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: AppColors.borderStrong, width: 3),
          ),
        ),
      ),
      lists: DefaultListBlockStyle(
        base,
        HorizontalSpacing.zero,
        VerticalSpacing.zero,
        VerticalSpacing.zero,
        null,
        _StashCheckbox(line: base.fontSize! * base.height!),
        indentWidthBuilder: _indentWidth,
      ),
      placeHolder: block(TextStyle(color: AppColors.textFaint)),
      palette: StashColors.palette(dark: dark),
    );
  }

  /// A task's box at the text's left edge, its text just after it (Quill
  /// leaves a list's width, the box at its right); other lists as Quill
  /// has them.
  static HorizontalSpacing _indentWidth(
    Block block,
    BuildContext context,
    int count,
    LeadingBlockNumberPointWidth numberPointWidthBuilder,
  ) {
    final list = block.style.attributes[Attribute.list.key];
    if (list != Attribute.checked && list != Attribute.unchecked) {
      return TextBlockUtils.defaultIndentWidthBuilder(
        block,
        context,
        count,
        numberPointWidthBuilder,
      );
    }
    final indent = block.style.attributes[Attribute.indent.key]?.value;
    return HorizontalSpacing(
      _StashCheckbox.size + 8 + (indent is int ? 14.0 * indent : 0),
      0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final editor = QuillEditor(
      controller: _controller,
      focusNode: _focus,
      scrollController: _scroll,
      config: QuillEditorConfig(
        editorKey: _editorKey,
        placeholder: widget.placeholder,
        autoFocus: widget.autofocus,
        expands: widget.expands,
        padding: widget.padding,
        enableSelectionToolbar: false,
        textCapitalization: TextCapitalization.none,
        customStyles: _styles(context),
        characterShortcutEvents: standardCharactersShortcutEvents,
        spaceShortcutEvents: [
          ...standardSpaceShorcutEvents,
          ..._extraSpaceShortcuts,
        ],
        embedBuilders: const [
          _ImageEmbedBuilder(),
          _FileEmbedBuilder(),
          _FormulaEmbedBuilder(),
          _TableEmbedBuilder(),
          _CodeEmbedBuilder(),
          _CardEmbedBuilder(),
          _RuleEmbedBuilder(),
        ],
        unknownEmbedBuilder: const _UnknownEmbedBuilder(),
        // A code block's lines in their language's colors.
        textSpanBuilder: _codeSpan,
        onLaunchUrl: _openLink,
        // Followed at once, not asked about in a menu of Quill's own.
        // Followed (see [_openLink]), not asked about in a menu of
        // Quill's own.
        linkActionPickerDelegate: (context, link, node) async =>
            LinkMenuAction.launch,
        // StashCaret's in its place.
        showCursor: false,
        onKeyPressed: _key,
        // Never beside a block: before or after it.
        onTapUp: (details, _) => _tapBlock(details.globalPosition),
      ),
    );
    return IdeMotion(
      lively: true,
      child: StashEditorScope(
        store: widget.store,
        ensureNote: widget.ensureNote,
        readOnly: widget.readOnly,
        onCard: (offset, url) => unawaited(_linkMenu(url, card: offset)),
        child: Stack(
          key: _stackKey,
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: FileDropRegion(
                delegate: this,
                child: Listener(
                  onPointerDown: (event) {
                    _pressedAt = event.position;
                    // Quill takes the keyboard on a click, not on a drag:
                    // text selected by one is to be deleted, typed over.
                    if (event.kind == PointerDeviceKind.mouse &&
                        event.buttons & kPrimaryMouseButton != 0 &&
                        !_focus.hasFocus) {
                      _focus.requestFocus();
                    }
                  },
                  // Fading out at an edge scrolled past, the caret with it.
                  child: ScrollEdgeFade(
                    child: StashCaret(
                      editorKey: _editorKey,
                      controller: _controller,
                      focusNode: _focus,
                      scrollController: _scroll,
                      height: _caretHeight(-1),
                      heightAt: _caretHeight,
                      color: themeColors['editorCursor.foreground'],
                      child: editor,
                    ),
                  ),
                ),
              ),
            ),
            if (_dropAt case final at?)
              if (_caretBox(at, _caretHeight(at)) case final box?)
                Positioned.fromRect(
                  rect: box,
                  child: IgnorePointer(
                    child: ColoredBox(color: AppColors.accent),
                  ),
                ),
            if (_barAround case final around?)
              _barWithMenus(context, around)
            else if (_caretLink != null)
              _linkBar(context),
            if (_ref != null && _refOptions.isNotEmpty) _refMenu(context),
          ],
        ),
      ),
    );
  }
}

enum _RefKind { title, project, number }

/// `[[query`, `@query` or `#query` before the caret: [from] to [to].
class _RefTrigger {
  const _RefTrigger(this.kind, this.from, this.to, this.query);

  final _RefKind kind;
  final int from;
  final int to;
  final String query;
}

class _RefOption {
  const _RefOption({
    required this.label,
    required this.detail,
    required this.text,
    required this.href,
  });

  final String label;
  final String detail;

  /// What goes in the text, linked to [href].
  final String text;
  final String href;
}

/// `[] ` makes a task, `> ` a quote, as `- ` makes a list item.
final _extraSpaceShortcuts = [
  _lineStartShortcut('[]', Attribute.unchecked),
  _lineStartShortcut('[ ]', Attribute.unchecked),
  _lineStartShortcut('>', Attribute.blockQuote),
];

SpaceShortcutEvent _lineStartShortcut(String mark, Attribute attribute) =>
    SpaceShortcutEvent(
      character: mark,
      handler: (node, controller) {
        final line = node.parent;
        if (line is! Line || line.toPlainText().trimRight() != mark) {
          return false;
        }
        final start = line.documentOffset;
        controller.replaceText(
          start,
          mark.length,
          '',
          TextSelection.collapsed(offset: start),
        );
        controller.formatText(start, 0, attribute);
        return true;
      },
    );

// --- The bar over the selection ------------------------------------------------

/// Over the selection, or under it where there is no room above (it
/// never covers what is selected while there is room for it at all).
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.around, required this.children});

  final Rect around;
  final List<Widget> children;

  static const _height = 32.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, box) {
          final above = around.top - _gap - _height;
          final below = around.bottom + _gap;
          final double top;
          var over = true;
          if (above >= 0) {
            top = above;
          } else if (below + _height <= box.maxHeight) {
            top = below;
            over = false;
          } else {
            // Selected past both ends: over the end in view.
            top = math.max(0, box.maxHeight - _height - _gap);
          }
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: top,
                // The editor's own: a click on it is not one beside the
                // editor, which would take its focus (and the bar) away
                // before the button had it.
                child: TextFieldTapRegion(
                  // Coming in from the selection's side.
                  child: PopIn(
                    alignment: over
                        ? Alignment.bottomCenter
                        : Alignment.topCenter,
                    offset: Offset(0, over ? 4 : -4),
                    child: _bar(around.center.dx),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _bar(double x) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bar = Container(
          height: _height,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: themeColors['editorWidget.background'],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: themeColors['editorWidget.border']),
            boxShadow: [
              BoxShadow(
                color: themeColors['widget.shadow'],
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        );
        return Align(
          alignment: Alignment(
            ((x / math.max(1, constraints.maxWidth)) * 2 - 1).clamp(-1, 1),
            0,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: bar,
          ),
        );
      },
    );
  }
}

class _BarDivider extends StatelessWidget {
  const _BarDivider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 16,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: AppColors.border,
  );
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.label,
    this.active = false,
    this.busy = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final String? label;
  final bool active;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.textPrimary : AppColors.textMuted;
    return IdeHover(
      message: tooltip,
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          // Keeps the editor's focus (and selection).
          onTapDown: (_) {},
          onTap: busy ? null : onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 24,
            constraints: const BoxConstraints(minWidth: 24),
            padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 6),
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: active
                  ? themeColors['toolbar.activeBackground']
                  : hovered
                  ? themeColors['toolbar.hoverBackground']
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(5),
            ),
            alignment: Alignment.center,
            child: label != null && icon == Icons.title
                ? Text(
                    label!,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        icon,
                        size: 15,
                        color: busy ? AppColors.accent : color,
                      ),
                      if (label case final label?) ...[
                        const SizedBox(width: 4),
                        Text(
                          label,
                          style: TextStyle(color: color, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// The text's and the background's colors, in a menu.
class _ColorButton extends StatefulWidget {
  const _ColorButton({required this.tooltip, required this.onPick});

  final String tooltip;
  final void Function(String key, String? name) onPick;

  @override
  State<_ColorButton> createState() => _ColorButtonState();
}

class _ColorButtonState extends State<_ColorButton> {
  final _key = GlobalKey();
  OverlayEntry? _entry;

  void _open() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(context);
    final origin = box.localToGlobal(
      Offset(0, box.size.height + 6),
      ancestor: overlay.context.findRenderObject(),
    );
    final palette = StashColors.palette(dark: themeColors.dark);
    Widget swatch(String key, String? name, {required bool background}) {
      final color = name == null ? null : palette[name];
      return GestureDetector(
        onTap: () {
          _close();
          widget.onPick(key, name);
        },
        child: Container(
          width: 22,
          height: 22,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: background ? color : null,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppColors.border),
          ),
          alignment: Alignment.center,
          child: Text(
            name == null ? '∅' : 'A',
            style: TextStyle(
              color: background ? AppColors.text : (color ?? AppColors.text),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      );
    }

    _entry = OverlayEntry(
      builder: (context) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
            ),
          ),
          Positioned(
            left: origin.dx,
            top: origin.dy,
            // Like the bar, picking a color is still inside the editor.
            child: TextFieldTapRegion(
              child: PopIn(
                alignment: Alignment.topLeft,
                offset: const Offset(0, -4),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: themeColors['editorWidget.background'],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: themeColors['editorWidget.border'],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: themeColors['widget.shadow'],
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          swatch('color', null, background: false),
                          for (final name in StashColors.text)
                            swatch('color', name, background: false),
                        ],
                      ),
                      Row(
                        children: [
                          swatch('background', null, background: true),
                          for (final name in StashColors.background)
                            swatch('background', name, background: true),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
  }

  void _close() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: _key,
    child: _BarButton(
      icon: Codicons.symbolColor,
      tooltip: widget.tooltip,
      onTap: _open,
    ),
  );
}

// --- What is not text ------------------------------------------------------------

abstract class _StashEmbedBuilder extends EmbedBuilder {
  const _StashEmbedBuilder();

  Map<String, Object?> dataOf(EmbedContext embed) =>
      StashEmbeds.data(embed.node.value.data);

  /// Gives the embed [data] in place of what it had.
  void replace(EmbedContext embed, Map<String, Object?> data) {
    final controller = embed.controller;
    final offset = embed.node.documentOffset;
    controller.replaceText(
      offset,
      1,
      StashEmbeds.of(key, data),
      controller.selection,
    );
  }

  void remove(EmbedContext embed) {
    final offset = embed.node.documentOffset;
    embed.controller.replaceText(
      offset,
      1,
      '',
      TextSelection.collapsed(offset: offset),
    );
  }
}

/// A tag in the text, as the chat's are (see ComposerImageChip): centered
/// on the text around it, on its line.
mixin _Tagged on EmbedBuilder {
  @override
  bool get expanded => false;

  @override
  WidgetSpan buildWidgetSpan(Widget widget) => WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: widget,
  );
}

class _ImageEmbedBuilder extends _StashEmbedBuilder with _Tagged {
  const _ImageEmbedBuilder();

  @override
  String get key => StashEmbeds.image;

  @override
  Widget build(BuildContext context, EmbedContext embed) {
    final data = dataOf(embed);
    final scope = StashEditorScope.maybeOf(context);
    final src = data['src'] as String? ?? '';
    final remote = isRemoteStashPicture(src);
    final path = scope == null || remote ? src : scope.store.absolute(src);
    final ImageProvider picture = remote
        ? NetworkImage(path)
        : io.stashImageProvider(path);
    Widget broken(BuildContext context, Object _, StackTrace? _) =>
        Icon(Codicons.fileMedia, size: 12, color: AppColors.textFaint);
    return _StashChip(
      textStyle: embed.textStyle,
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(2.5),
        child: Image(
          image: ResizeImage(picture, width: 42),
          width: 14,
          height: 14,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: broken,
        ),
      ),
      label: context.l10n.imageChip(_number(embed)),
      preview: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320, maxHeight: 240),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image(
            image: ResizeImage(picture, width: 960),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: broken,
          ),
        ),
      ),
      onTap: () => unawaited(
        _openPicture(
          context,
          path,
          remote: remote,
          gallery: scope == null
              ? const []
              : _gallery(embed.controller.document, scope.store.absolute),
        ),
      ),
    );
  }

  /// Copied, its path (`@/…/shot.png`): pasted in a message, the picture
  /// itself (see [pastedAsPicture]); read as text, where it is.
  @override
  String toPlainText(Embed node) {
    final src = StashEmbeds.data(node.value.data)['src'] as String? ?? '';
    if (src.isEmpty || isRemoteStashPicture(src)) return src;
    return fileReferenceText(StashStore.current?.absolute(src) ?? src);
  }

  /// Which picture of the text it is, from 1.
  static int _number(EmbedContext embed) {
    final at = embed.node.documentOffset;
    var number = 0;
    var offset = 0;
    for (final op in embed.controller.document.toDelta().toList()) {
      if (offset > at) break;
      final value = op.data;
      if (value is Map && value.containsKey(StashEmbeds.image)) number++;
      offset += op.length ?? 0;
    }
    return number;
  }
}

/// A stash's text as a model is given it ([stashTextForModel]): up to
/// its requirement section ([StashNote.requirementHeading]) if one was
/// written, which stays as it is; [end] where it ends in the document,
/// [endsLine] whether it ends its line.
typedef StashTextPart = ({
  int end,
  String text,
  List<(String, String)> attachments,
  bool endsLine,
});

/// [document]'s text (see [StashTextPart]); null when it has none.
StashTextPart? stashTextPart(
  Document document,
  String Function(String path) absolute,
) {
  final end = _textEnd(document);
  if (end == 0) return null;
  final slice = document.toDelta().slice(0, end);
  final asked = stashTextForModel(slice, absolute);
  if (asked.text.trim().isEmpty) return null;
  return (
    end: end,
    text: asked.text,
    attachments: asked.attachments,
    endsLine: switch (slice.toList().lastOrNull?.data) {
      final String last => last.endsWith('\n'),
      _ => false,
    },
  );
}

/// What puts [reply], a model's to [document]'s text given it as [asked]
/// ([stashTextPart]), in the text's place, and how long it is; null when
/// the text is no longer [asked].
({Delta change, int length})? stashTextRewrite(
  Document document,
  String asked,
  String reply,
  String Function(String path) absolute,
) {
  final part = stashTextPart(document, absolute);
  if (part == null || part.text != asked) return null;
  final replaced = stashTextFromModel(
    reply,
    part.attachments,
    endsLine: part.endsLine,
  );
  return (
    change: (Delta()..delete(part.end)).concat(replaced),
    length: _textLength(replaced),
  );
}

/// Where [document]'s text ends: before a requirement section's heading
/// and the empty lines above it, if there is one; else before the
/// document's last line break.
int _textEnd(Document document) {
  final plain = document.toPlainText();
  final heading = StashNote.requirementHeading.replaceFirst(
    RegExp(r'^#+\s*'),
    '',
  );
  var end = plain.length - 1;
  var offset = 0;
  var lineStart = 0;
  for (final op in document.toDelta().toList()) {
    final data = op.data;
    if (data is! String) {
      offset += 1;
      continue;
    }
    for (var i = 0; i < data.length; i++, offset++) {
      if (data[i] != '\n') continue;
      if (op.attributes?[Attribute.header.key] == 2 &&
          plain.substring(lineStart, offset).trim() == heading) {
        end = lineStart;
        while (end > 0 &&
            plain[end - 1] == '\n' &&
            (end < 2 || plain[end - 2] == '\n')) {
          end--;
        }
        return end;
      }
      lineStart = offset + 1;
    }
  }
  return end;
}

/// How long [delta]'s text is (an embed is one), not its count of
/// operations ([Delta.length]).
int _textLength(Delta delta) =>
    delta.toList().fold(0, (length, op) => length + (op.length ?? 0));

/// [slice] (a part of a stash's text) as a model is given it: markdown,
/// each picture and file in it as its path in brackets (`[/…/shot.png]`),
/// which says what it is where a model only reads; with the markdown each
/// such path stands for (see [stashTextFromModel]).
@visibleForTesting
({String text, List<(String, String)> attachments}) stashTextForModel(
  Delta slice,
  String Function(String path) absolute,
) {
  final marked = Delta();
  final attachments = <(String, String)>[];
  for (final op in slice.toList()) {
    final data = op.data;
    if (data is Map && data.isNotEmpty) {
      final type = data.keys.first;
      final value = StashEmbeds.data(data.values.first);
      final path = switch (type) {
        StashEmbeds.image => value['src'],
        StashEmbeds.file => value['path'],
        _ => null,
      };
      if (path is String && path.isNotEmpty) {
        final own = stashDeltaToMarkdown(
          Delta()
            ..insert(data)
            ..insert('\n'),
        ).trim();
        final where = isRemoteStashPicture(path) ? path : absolute(path);
        // Marked where it is; the markdown around it written first, which
        // would escape the brackets.
        marked.insert('\uE000${attachments.length}\uE001');
        attachments.add(('[$where]', own));
        continue;
      }
    }
    marked.push(op);
  }
  final last = slice.toList().lastOrNull?.data;
  if (last is! String || !last.endsWith('\n')) marked.insert('\n');
  var text = stashDeltaToMarkdown(marked).trimRight();
  for (final (i, (token, _)) in attachments.indexed) {
    text = text.replaceFirst('\uE000$i\uE001', token);
  }
  return (text: text, attachments: attachments);
}

/// [reply], a model's to [stashTextForModel], as a stash's text: the paths
/// in brackets the pictures and files they were, those it left out put
/// after it (none is lost). [endsLine]: the part ended its line.
@visibleForTesting
Delta stashTextFromModel(
  String reply,
  List<(String, String)> attachments, {
  required bool endsLine,
}) {
  var text = reply.trimRight();
  final left = <String>[];
  for (final (token, markdown) in attachments) {
    final at = text.indexOf(token);
    if (at < 0) {
      left.add(markdown);
    } else {
      text = text.replaceRange(at, at + token.length, markdown);
    }
  }
  if (left.isNotEmpty) text = '$text ${left.join(' ')}';
  final delta = stashMarkdownToDelta(text);
  // The line goes on after it, as it did.
  return endsLine ? delta : delta.slice(0, _textLength(delta) - 1);
}

/// The picture whole, as the chat's are; a remote one in the browser.
/// [gallery] is the stash's pictures on this machine (absolute), which
/// the arrows go through from it.
Future<void> _openPicture(
  BuildContext context,
  String path, {
  required bool remote,
  List<String> gallery = const [],
}) async {
  if (remote) {
    await openExternal(path);
    return;
  }
  final pictures = gallery.contains(path) ? gallery : [path];
  showImageGallery(
    context,
    count: pictures.length,
    index: pictures.indexOf(path),
    load: (index) => _readPicture(pictures[index]),
  );
}

/// The picture at [path] (on this machine); null when it cannot be read.
Future<ImageAttachment?> _readPicture(String path) async {
  final bytes = await io.readBytesFile(path);
  if (bytes == null) return null;
  final type = switch (p.extension(path).toLowerCase()) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.gif' => 'image/gif',
    '.webp' => 'image/webp',
    _ => 'image/png',
  };
  return ImageAttachment(bytes: bytes, mediaType: type, name: p.basename(path));
}

/// [document]'s pictures on this machine, in order, by their absolute
/// paths ([absolute]).
List<String> _gallery(Document document, String Function(String) absolute) => [
  for (final attachment in StashAttachment.of(document))
    if (attachment.picture && !isRemoteStashPicture(attachment.path))
      absolute(attachment.path),
];

/// A picture or a file of a stash's text, as [StashAttachments] shows it.
@immutable
class StashAttachment {
  const StashAttachment.picture(this.path) : name = null;
  const StashAttachment.file(this.path, this.name);

  /// As the text has it: kept with the stash (relative), a file's where it
  /// is, or a picture's url.
  final String path;

  /// A file's; null for a picture.
  final String? name;

  bool get picture => name == null;

  /// Each picture and file of [document] once, as they first come: one
  /// put in twice is one.
  static List<StashAttachment> of(Document document) {
    final seen = <String>{};
    final found = <StashAttachment>[];
    for (final op in document.toDelta().toList()) {
      final value = op.data;
      if (value is! Map || value.isEmpty) continue;
      final type = value.keys.first;
      final data = StashEmbeds.data(value.values.first);
      final attachment = switch (type) {
        StashEmbeds.image => switch (data['src']) {
          final String src when src.isNotEmpty => StashAttachment.picture(src),
          _ => null,
        },
        StashEmbeds.file => switch (data['path']) {
          final String path when path.isNotEmpty => StashAttachment.file(
            path,
            data['name'] as String? ?? p.basename(path),
          ),
          _ => null,
        },
        _ => null,
      };
      if (attachment != null && seen.add('$type:${attachment.path}')) {
        found.add(attachment);
      }
    }
    return found;
  }

  @override
  bool operator ==(Object other) =>
      other is StashAttachment && other.path == path && other.name == name;

  @override
  int get hashCode => Object.hash(path, name);
}

/// The pictures and files of the text in [controller], above it: each once,
/// however often it is put in. Nothing while there are none.
class StashAttachments extends StatefulWidget {
  const StashAttachments({
    super.key,
    required this.controller,
    required this.store,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 8),
  });

  final QuillController controller;
  final StashStore store;
  final EdgeInsets padding;

  static const tileSize = 64.0;

  @override
  State<StashAttachments> createState() => _StashAttachmentsState();
}

class _StashAttachmentsState extends State<StashAttachments> {
  List<StashAttachment> _found = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _found = StashAttachment.of(widget.controller.document);
  }

  @override
  void didUpdateWidget(StashAttachments oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _found = StashAttachment.of(widget.controller.document);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final found = StashAttachment.of(widget.controller.document);
    if (listEquals(found, _found)) return;
    setState(() => _found = found);
  }

  @override
  Widget build(BuildContext context) {
    if (_found.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: StashAttachments.tileSize + widget.padding.vertical,
      child: ScrollEdgeFade(
        axis: Axis.horizontal,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: widget.padding,
          itemCount: _found.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) => _AttachmentTile(
            attachment: _found[index],
            store: widget.store,
            gallery: [
              for (final found in _found)
                if (found.picture && !isRemoteStashPicture(found.path))
                  widget.store.absolute(found.path),
            ],
          ),
        ),
      ),
    );
  }
}

/// A stash's first picture, small, else its first file's icon; null for
/// one with neither.
class StashAttachmentIcon extends StatelessWidget {
  const StashAttachmentIcon({
    super.key,
    required this.attachment,
    required this.store,
    this.size = 16,
  });

  final StashAttachment attachment;
  final StashStore store;
  final double size;

  /// [body]'s (markdown) pictures first, then its files: the first.
  static StashAttachment? of(String body) {
    final found = StashAttachment.of(stashDocument(body));
    return found.where((a) => a.picture).firstOrNull ?? found.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final path = attachment.picture && isRemoteStashPicture(attachment.path)
        ? attachment.path
        : store.absolute(attachment.path);
    if (!attachment.picture) return FileIcon(path, size: size);
    final ImageProvider picture = isRemoteStashPicture(attachment.path)
        ? NetworkImage(path)
        : io.stashImageProvider(path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Image(
        image: ResizeImage(picture, width: (size * 3).round()),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => Icon(
          Codicons.fileMedia,
          size: size - 2,
          color: AppColors.textFaint,
        ),
      ),
    );
  }
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({
    required this.attachment,
    required this.store,
    this.gallery = const [],
  });

  final StashAttachment attachment;
  final StashStore store;

  /// The stash's pictures, which the arrows go through from this one.
  final List<String> gallery;

  @override
  Widget build(BuildContext context) {
    final remote = attachment.picture && isRemoteStashPicture(attachment.path);
    final path = remote ? attachment.path : store.absolute(attachment.path);
    const size = StashAttachments.tileSize;
    final Widget content;
    if (attachment.picture) {
      final ImageProvider picture = remote
          ? NetworkImage(path)
          : io.stashImageProvider(path);
      content = Image(
        image: ResizeImage(picture, width: (size * 3).round()),
        width: size,
        height: size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, _, _) => Center(
          child: Icon(Codicons.fileMedia, size: 20, color: AppColors.textFaint),
        ),
      );
    } else {
      content = Padding(
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
        child: Column(
          children: [
            FileIcon(path, size: 22),
            const Spacer(),
            Text(
              attachment.name!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.textMuted, fontSize: 10.5),
            ),
          ],
        ),
      );
    }
    return IdeHover(
      message: attachment.picture ? p.basename(path) : path,
      child: HoverBuilder(
        cursor: SystemMouseCursors.click,
        builder: (context, hovered) => GestureDetector(
          onTap: () => unawaited(
            attachment.picture
                ? _openPicture(context, path, remote: remote, gallery: gallery)
                : openExternal(path),
          ),
          onSecondaryTap: remote
              ? null
              : () => unawaited(WindowControls.revealInFileManager(path)),
          child: Container(
            width: size,
            height: size,
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: hovered ? AppColors.borderStrong : AppColors.partBorder,
              ),
            ),
            decoration: BoxDecoration(
              color: hovered ? AppColors.hover : AppColors.surface,
              borderRadius: BorderRadius.circular(6),
            ),
            clipBehavior: Clip.antiAlias,
            child: content,
          ),
        ),
      ),
    );
  }
}

/// A picture, a file, code, a table or a link, as a tag in the text: what
/// it is beside its label, larger ([preview]) or told ([hint]) on hover.
class _StashChip extends StatelessWidget {
  const _StashChip({
    required this.textStyle,
    required this.leading,
    required this.label,
    this.detail,
    this.preview,
    this.hint,
    this.onTap,
    this.onSecondaryTap,
  });

  /// The text's around it, to be centered on.
  final TextStyle textStyle;
  final Widget leading;
  final String label;

  /// After [label], fainter.
  final String? detail;
  final WidgetBuilder? preview;
  final String? hint;
  final VoidCallback? onTap;
  final VoidCallback? onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    Widget chip = _CenteredOnText(
      textStyle: textStyle,
      child: DefaultTextStyle.merge(
        style: const TextStyle(
          height: 1.25,
          leadingDistribution: TextLeadingDistribution.even,
        ),
        child: HoverBuilder(
          cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
          builder: (context, hovered) => GestureDetector(
            onTap: onTap,
            onSecondaryTap: onSecondaryTap,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              padding: const EdgeInsets.fromLTRB(3, 1, 5, 1),
              decoration: BoxDecoration(
                color: hovered && onTap != null
                    ? AppColors.hover
                    : AppColors.surface,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: themeColors['chat.requestBorder']),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(dimension: 14, child: Center(child: leading)),
                  const SizedBox(width: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppColors.text, fontSize: 12),
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      detail,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (preview case final preview?) {
      chip = HoverTooltip(content: preview, child: chip);
    } else if (hint case final hint?) {
      chip = IdeHover(message: hint, child: chip);
    }
    return chip;
  }
}

class _FileEmbedBuilder extends _StashEmbedBuilder with _Tagged {
  const _FileEmbedBuilder();

  @override
  String get key => StashEmbeds.file;

  @override
  Widget build(BuildContext context, EmbedContext embed) {
    final data = dataOf(embed);
    final scope = StashEditorScope.maybeOf(context);
    final path = data['path'] as String? ?? '';
    final absolute = scope == null ? path : scope.store.absolute(path);
    final name = data['name'] as String? ?? p.basename(path);
    return _StashChip(
      textStyle: embed.textStyle,
      leading: FileIcon(absolute, size: 14),
      label: name,
      // Linked to where it is (too big to copy), not kept with the stash.
      detail: p.isAbsolute(path) ? '↗' : null,
      hint: absolute,
      onTap: () => unawaited(openExternal(absolute)),
      onSecondaryTap: () =>
          unawaited(WindowControls.revealInFileManager(absolute)),
    );
  }

  /// Copied, its path (`@/…/notes.pdf`): pasted in a message, a tag of
  /// the file.
  @override
  String toPlainText(Embed node) {
    final data = StashEmbeds.data(node.value.data);
    final path = data['path'] as String? ?? '';
    if (path.isEmpty) return data['name'] as String? ?? '';
    return fileReferenceText(StashStore.current?.absolute(path) ?? path);
  }
}

class _FormulaEmbedBuilder extends _StashEmbedBuilder {
  const _FormulaEmbedBuilder();

  @override
  String get key => StashEmbeds.formula;

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embed) {
    final data = dataOf(embed);
    final tex = data['tex'] as String? ?? '';
    final block = data['block'] == true;
    final readOnly =
        embed.readOnly ||
        (StashEditorScope.maybeOf(context)?.readOnly ?? false);
    return GestureDetector(
      onTap: readOnly
          ? null
          : () async {
              final edited = await showStashTextDialog(
                context,
                title: context.l10n.stashFormulaTitle,
                text: tex,
                monospace: true,
              );
              if (edited == null) return;
              if (edited.trim().isEmpty) {
                remove(embed);
              } else {
                replace(embed, {'tex': edited.trim(), 'block': block});
              }
            },
      child: MouseRegion(
        cursor: readOnly ? MouseCursor.defer : SystemMouseCursors.click,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: block ? 6 : 0),
          child: MathView(tex, display: block),
        ),
      ),
    );
  }

  @override
  String toPlainText(Embed node) =>
      StashEmbeds.data(node.value.data)['tex'] as String? ?? '';
}

/// Code or a table, as a tag: shown on hover, edited as its markdown in a
/// dialog on a click.
abstract class _SourceBlockBuilder extends _StashEmbedBuilder with _Tagged {
  const _SourceBlockBuilder();

  String sourceOf(Map<String, Object?> data);
  Map<String, Object?> dataFrom(String source, Map<String, Object?> old);
  Widget view(BuildContext context, Map<String, Object?> data);
  String title(AppLocalizations l10n);
  IconData get icon;
  String label(AppLocalizations l10n, Map<String, Object?> data);
  String? detail(AppLocalizations l10n, Map<String, Object?> data);

  @override
  Widget build(BuildContext context, EmbedContext embed) {
    final data = dataOf(embed);
    final readOnly =
        embed.readOnly ||
        (StashEditorScope.maybeOf(context)?.readOnly ?? false);
    final l10n = context.l10n;
    return _StashChip(
      textStyle: embed.textStyle,
      leading: Icon(icon, size: 13, color: AppColors.textMuted),
      label: label(l10n, data),
      detail: detail(l10n, data),
      preview: (context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 320),
        child: ClipRect(
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: view(context, data),
          ),
        ),
      ),
      onTap: readOnly ? null : () => unawaited(edit(context, embed, data)),
    );
  }

  /// Its markdown, edited in a dialog: emptied, it goes.
  Future<void> edit(
    BuildContext context,
    EmbedContext embed,
    Map<String, Object?> data,
  ) async {
    final edited = await showStashTextDialog(
      context,
      title: title(context.l10n),
      text: sourceOf(data),
      monospace: true,
      lines: 12,
    );
    if (edited == null) return;
    if (edited.trim().isEmpty) {
      remove(embed);
    } else {
      replace(embed, dataFrom(edited, data));
    }
  }
}

class _CodeBlock extends StatefulWidget {
  const _CodeBlock({required this.child, required this.onEdit});

  final Widget child;
  final VoidCallback? onEdit;

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Stack(
        children: [
          widget.child,
          if (_hovered && widget.onEdit != null)
            Positioned(
              right: 8,
              bottom: 8,
              child: IdeHover(
                message: context.l10n.stashEdit,
                child: HoverBuilder(
                  cursor: SystemMouseCursors.click,
                  builder: (context, hovered) => GestureDetector(
                    onTap: widget.onEdit,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: hovered
                            ? themeColors['toolbar.hoverBackground']
                            : themeColors['editorWidget.background'],
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Icon(
                        Codicons.edit,
                        size: 13,
                        color: AppColors.text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _TableEmbedBuilder extends _SourceBlockBuilder {
  const _TableEmbedBuilder();

  @override
  String get key => StashEmbeds.table;

  @override
  String title(AppLocalizations l10n) => l10n.stashTableTitle;

  @override
  IconData get icon => Codicons.table;

  @override
  String label(AppLocalizations l10n, Map<String, Object?> data) =>
      l10n.stashTableChip;

  /// Its rows and columns: `3×4`.
  @override
  String? detail(AppLocalizations l10n, Map<String, Object?> data) {
    final rows = sourceOf(data)
        .split('\n')
        .where((line) => line.trim().startsWith('|'))
        .toList();
    if (rows.isEmpty) return null;
    final columns = rows.first.trim().split('|').length - 2;
    // The line under the head is no row.
    final count = rows.length > 1 ? rows.length - 1 : rows.length;
    return columns > 0 ? '$count×$columns' : null;
  }

  @override
  String sourceOf(Map<String, Object?> data) =>
      data['markdown'] as String? ?? '';

  @override
  Map<String, Object?> dataFrom(String source, Map<String, Object?> old) => {
    'markdown': source.trim(),
  };

  @override
  Widget view(BuildContext context, Map<String, Object?> data) =>
      MarkdownView(sourceOf(data));

  @override
  String toPlainText(Embed node) =>
      StashEmbeds.data(node.value.data)['markdown'] as String? ?? '';
}

/// Code as the chat shows it, on lines of its own; edited as its fence in
/// a dialog (the pencil on hover).
class _CodeEmbedBuilder extends _SourceBlockBuilder {
  const _CodeEmbedBuilder();

  @override
  String get key => StashEmbeds.code;

  @override
  bool get expanded => true;

  @override
  Widget build(BuildContext context, EmbedContext embed) {
    final data = dataOf(embed);
    final readOnly =
        embed.readOnly ||
        (StashEditorScope.maybeOf(context)?.readOnly ?? false);
    return _CodeBlock(
      onEdit: readOnly ? null : () => unawaited(edit(context, embed, data)),
      child: view(context, data),
    );
  }

  @override
  String title(AppLocalizations l10n) => l10n.stashCodeTitle;

  @override
  IconData get icon => Codicons.code;

  @override
  String label(AppLocalizations l10n, Map<String, Object?> data) {
    final language = data['language'] as String? ?? '';
    return language.isEmpty ? l10n.stashCodeChip : language;
  }

  @override
  String? detail(AppLocalizations l10n, Map<String, Object?> data) => l10n
      .stashLines('\n'.allMatches(data['code'] as String? ?? '').length + 1);

  /// The language on the first line, as a fence's.
  @override
  String sourceOf(Map<String, Object?> data) =>
      '```${data['language'] ?? ''}\n${data['code'] ?? ''}\n```';

  @override
  Map<String, Object?> dataFrom(String source, Map<String, Object?> old) {
    final lines = source.trim().split('\n');
    var language = old['language'] as String? ?? '';
    if (lines.isNotEmpty && lines.first.startsWith('```')) {
      language = lines.removeAt(0).substring(3).trim();
    }
    if (lines.isNotEmpty && lines.last.trim().startsWith('```')) {
      lines.removeLast();
    }
    return {'code': lines.join('\n'), 'language': language};
  }

  @override
  Widget view(BuildContext context, Map<String, Object?> data) {
    final language = data['language'] as String? ?? '';
    return MarkdownCodeBlock(
      code: data['code'] as String? ?? '',
      language: language.isEmpty ? null : language,
    );
  }

  @override
  String toPlainText(Embed node) =>
      StashEmbeds.data(node.value.data)['code'] as String? ?? '';
}

class _CardEmbedBuilder extends _StashEmbedBuilder with _Tagged {
  const _CardEmbedBuilder();

  @override
  String get key => StashEmbeds.card;

  @override
  Widget build(BuildContext context, EmbedContext embed) {
    final data = dataOf(embed);
    final url = data['url'] as String? ?? '';
    final title = data['title'] as String? ?? url;
    void onTap() {
      final scope = StashEditorScope.maybeOf(context);
      if (scope?.onCard case final onCard?) {
        onCard(embed.node.documentOffset, url);
      } else {
        unawaited(openExternal(url));
      }
    }

    // An issue or pull request: in its state, titled as it is now.
    final forge = StashForge.current;
    if (forge?.refOf(url) case final ref?) {
      return ListenableBuilder(
        listenable: forge!,
        builder: (context, _) {
          final link = forge.stashOf(url)?.issueOf(url);
          final now = forge.itemOf(url)?.title ?? link?.title;
          return _StashChip(
            textStyle: embed.textStyle,
            leading: ForgeStateIcon(
              ref.kind,
              forge.itemOf(url)?.state ?? ForgeState.parse(link?.state),
              size: 12,
            ),
            label: now == null
                ? (title.isEmpty || title == url ? ref.fullTag : title)
                : '${ref.fullTag} $now',
            hint: url,
            onTap: onTap,
          );
        },
      );
    }
    return _StashChip(
      textStyle: embed.textStyle,
      leading: Icon(Codicons.globe, size: 12, color: AppColors.textMuted),
      label: title.isEmpty ? url : title,
      hint: url,
      onTap: onTap,
    );
  }

  @override
  String toPlainText(Embed node) {
    final data = StashEmbeds.data(node.value.data);
    return '${data['title'] ?? ''} ${data['url'] ?? ''}';
  }
}

class _RuleEmbedBuilder extends _StashEmbedBuilder {
  const _RuleEmbedBuilder();

  @override
  String get key => StashEmbeds.rule;

  @override
  bool get expanded => true;

  @override
  Widget build(BuildContext context, EmbedContext embed) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Container(height: 1, color: AppColors.border),
  );
}

/// What another editor put in that is none of these: shown as nothing.
class _UnknownEmbedBuilder extends EmbedBuilder {
  const _UnknownEmbedBuilder();

  @override
  String get key => 'unknown';

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) =>
      const SizedBox.shrink();
}

/// Whether [src] is a picture on the web rather than in the stash's folder.
bool isRemoteStashPicture(String src) =>
    src.startsWith('http://') || src.startsWith('https://');

/// Asks for text in a dialog: a formula's TeX, a table's or code's
/// markdown. Null when cancelled.
Future<String?> showStashTextDialog(
  BuildContext context, {
  required String title,
  required String text,
  bool monospace = false,
  int lines = 4,
}) {
  final controller = TextEditingController(text: text);
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.l10n.commonDismiss,
    barrierColor: const Color(0x80000000),
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) {
      final l10n = context.l10n;
      return Center(
        child: Container(
          width: 520,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: themeColors['editorWidget.background'],
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: themeColors['editorWidget.border']),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Shortcuts(
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        _SubmitIntent(),
                    SingleActivator(LogicalKeyboardKey.enter, control: true):
                        _SubmitIntent(),
                  },
                  child: Actions(
                    actions: {
                      _SubmitIntent: CallbackAction<_SubmitIntent>(
                        onInvoke: (_) {
                          Navigator.of(context).pop(controller.text);
                          return null;
                        },
                      ),
                    },
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      minLines: lines,
                      maxLines: lines + 8,
                      cursorColor: AppColors.text,
                      style:
                          (monospace
                                  ? AppFonts.uiCodeStyle(12.5)
                                  : const TextStyle(fontSize: 13))
                              .copyWith(color: themeColors['input.foreground']),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: themeColors['input.background'],
                        contentPadding: const EdgeInsets.all(10),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: BorderSide(color: AppColors.borderStrong),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: BorderSide(
                            color: themeColors['focusBorder'],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _DialogButton(
                      label: l10n.commonCancel,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    _DialogButton(
                      label: l10n.commonOk,
                      primary: true,
                      onTap: () => Navigator.of(context).pop(controller.text),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  ).whenComplete(controller.dispose);
}

class _SubmitIntent extends Intent {
  const _SubmitIntent();
}

class _DialogButton extends StatelessWidget {
  const _DialogButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => HoverBuilder(
    cursor: SystemMouseCursors.click,
    builder: (context, hovered) => GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: primary
              ? (hovered
                    ? themeColors['button.hoverBackground']
                    : themeColors['button.background'])
              : (hovered ? AppColors.hover : Colors.transparent),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: primary ? Colors.transparent : AppColors.borderStrong,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: primary ? themeColors['button.foreground'] : AppColors.text,
            fontSize: 12.5,
          ),
        ),
      ),
    ),
  );
}

// As the chat input's tags are (composer_embeds.dart), the stash's own copy.

/// Reports a baseline that puts the child's vertical center on the center of
/// the glyphs of [textStyle], so a baseline-aligned token sits optically
/// centered on the surrounding text regardless of what else is on the line.
class _CenteredOnText extends SingleChildRenderObjectWidget {
  const _CenteredOnText({required this.textStyle, required super.child});

  final TextStyle textStyle;

  /// Distance from the alphabetic baseline up to the glyph center.
  double _glyphCenterAboveBaseline(TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: 'x', style: textStyle.copyWith(height: null)),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout();
    final metrics = painter.computeLineMetrics().first;
    painter.dispose();
    return (metrics.ascent - metrics.descent) / 2;
  }

  @override
  _RenderCenteredOnText createRenderObject(BuildContext context) =>
      _RenderCenteredOnText(
        _glyphCenterAboveBaseline(MediaQuery.textScalerOf(context)),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCenteredOnText renderObject,
  ) {
    renderObject.centerAboveBaseline = _glyphCenterAboveBaseline(
      MediaQuery.textScalerOf(context),
    );
  }
}

class _RenderCenteredOnText extends RenderProxyBox {
  _RenderCenteredOnText(this._centerAboveBaseline);

  double _centerAboveBaseline;
  set centerAboveBaseline(double value) {
    if (value == _centerAboveBaseline) return;
    _centerAboveBaseline = value;
    markNeedsLayout();
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      size.height / 2 + _centerAboveBaseline;

  @override
  double? computeDryBaseline(
    BoxConstraints constraints,
    TextBaseline baseline,
  ) => getDryLayout(constraints).height / 2 + _centerAboveBaseline;
}

/// A task's box, as the app draws checkboxes (not Material's): at the
/// left of the room before its text, centered on its first [line] (the
/// paragraph's line height).
class _StashCheckbox extends QuillCheckboxBuilder {
  _StashCheckbox({required this.line});

  static const size = 14.0;

  final double line;

  @override
  Widget build({
    required BuildContext context,
    required bool isChecked,
    required ValueChanged<bool> onChanged,
  }) {
    final colors = themeColors;
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: EdgeInsets.only(top: math.max(0, (line - size) / 2)),
        child: Semantics(
          checked: isChecked,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(!isChecked),
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: isChecked
                      ? AppColors.accent
                      : colors['checkbox.background'],
                  border: Border.all(
                    color: isChecked
                        ? AppColors.accent
                        : colors['checkbox.border'],
                  ),
                  borderRadius: BorderRadius.circular(3.5),
                ),
                child: isChecked
                    ? Icon(
                        Codicons.check,
                        size: 12,
                        color: colors['button.foreground'],
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
