import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

import '../../ide/ide_hover.dart';
import '../../theme/app_theme.dart';
import '../../theme/material_file_icons.dart';
import '../../theme/workbench_theme.dart' show WorkbenchThemeScope, themeColors;
import '../../workspace/editor_launcher.dart';
import '../side_panel/file_link.dart';
import '../side_panel/file_link_menu.dart';
import '../composer/composer_embeds.dart' show FileImageChip;
import '../side_panel/file_open.dart';
import 'code_citation.dart';
import 'content_image.dart';
import 'hover_scrollbar.dart';
import 'inline_code.dart';
import 'markdown_cjk.dart';
import 'markdown_math.dart';
import 'markdown_tags.dart';
import 'mermaid_code_block.dart';

/// GitHub-flavored markdown as plain widgets (so a surrounding
/// `SelectionArea` selects and copies it): headings, paragraphs, lists
/// (and task lists), code blocks, quotes, tables, rules, and inline
/// strong, emphasis, strikethrough, code, links and TeX math.
class MarkdownView extends StatefulWidget {
  const MarkdownView(this.data, {super.key, this.style});

  final String data;

  /// [baseStyle] when null.
  final TextStyle? style;

  static TextStyle get baseStyle =>
      TextStyle(color: AppColors.text, fontSize: 13.5, height: 1.6);

  /// Inline code's, its background painted by [InlineCodeText].
  static TextStyle get codeStyle =>
      AppFonts.uiCodeStyle(12.5).copyWith(color: AppColors.inlineCode);

  /// The block syntaxes of its own, before GFM's: code citations and TeX.
  static const blockSyntaxes = <md.BlockSyntax>[
    CodeCitationFenceSyntax(),
    MathBlockSyntax(),
  ];
  static List<md.InlineSyntax> get inlineSyntaxes => [
    InlineMathSyntax(),
    CjkEmphasisSyntax(),
  ];

  /// A document parsing as it does; one keeps the link definitions it
  /// read (see the IDE's markdown preview). The chat's has [tags] too: a
  /// block between tags as a section that folds ([TagBlockSyntax]).
  static md.Document document({bool tags = false}) => md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    blockSyntaxes: [...blockSyntaxes, if (tags) const TagBlockSyntax()],
    inlineSyntaxes: inlineSyntaxes,
    encodeHtml: false,
  );

  // A message can leave the virtual viewport and be built again while the
  // scrollbar is dragged. Keep parsed documents across those visits, bounded
  // by both count and source size. Each document owns its link definitions.
  static final _parsed = <String, List<md.Node>>{};
  static int _cachedCharacters = 0;
  static const _maxCachedCharacters = 2 * 1024 * 1024;
  static const _maxCachedMessages = 256;

  static List<md.Node> _parse(String data) {
    if (_parsed.remove(data) case final nodes?) {
      _parsed[data] = nodes;
      return nodes;
    }
    final nodes = document(tags: true).parse(data);
    if (data.length > _maxCachedCharacters) return nodes;
    _parsed[data] = nodes;
    _cachedCharacters += data.length;
    while (_parsed.length > _maxCachedMessages ||
        _cachedCharacters > _maxCachedCharacters) {
      final oldest = _parsed.keys.first;
      _parsed.remove(oldest);
      _cachedCharacters -= oldest.length;
    }
    return nodes;
  }

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  Widget? _built;
  Object? _builtFrom;
  late List<md.Node> _nodes;

  @override
  void initState() {
    super.initState();
    _nodes = MarkdownView._parse(widget.data);
  }

  @override
  void didUpdateWidget(MarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _nodes = MarkdownView._parse(widget.data);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _built = null;
  }

  @override
  Widget build(BuildContext context) {
    final from = (
      widget.data,
      widget.style,
      themeColors,
      WorkbenchThemeScope.restyles,
    );
    if (_built case final built? when from == _builtFrom) return built;
    _builtFrom = from;
    return _built = _build(context);
  }

  Widget _build(BuildContext context) {
    final MarkdownView(:data, :style) = widget;
    final baseStyle = MarkdownView.baseStyle;
    final nodes = _nodes;
    // In a chat whose files open (see FileOpenScope): links to them, and
    // inline code naming one once it is known to be there.
    final files = FileOpenScope.maybeOf(context);
    if (files == null) {
      return MarkdownBlocks(
        nodes: _nodes,
        style: widget.style ?? MarkdownView.baseStyle,
      );
    }
    Widget? icon(FileLink? link) {
      final path = link == null ? null : files.resolve(link.path);
      if (path == null) return null;
      return _isFolder(link!.path, files.existence.known(path))
          ? FolderIcon(path, size: _fileIconSize)
          : FileIcon(path, size: _fileIconSize);
    }

    // The message's image files, for a click on one to go through them.
    late final gallery = [
      for (final src in _imageSources(nodes)) ?markdownImagePath(src, files),
    ];
    final options = MarkdownOptions(
      link: (href) =>
          _linkRecognizer(href) ?? files.linkRecognizer(href, context: context),
      code: (code) => files.codeRecognizer(code, context: context),
      linkIcon: (href) => icon(FileLink.parseHref(href)),
      codeIcon: (code) => icon(FileLink.parseText(code)),
      // An image as an attached one's tag.
      fileTag: (href, label) {
        final link = FileLink.parseHref(href);
        final path = link == null || link.range != null
            ? null
            : files.resolve(link.path);
        if (path == null || !files.showsImage(path)) return null;
        return FileImageChip.span(
          path: path,
          label: label.trim().isEmpty
              ? (files.paths ?? p.context).basename(path)
              : label.trim(),
          files: files,
          textStyle: style ?? baseStyle,
        );
      },
      // An image file as it is; the others of the message a click away.
      image: (src, alt, title, {width, height}) {
        final path = markdownImagePath(src, files);
        if (path == null) return _imageLink(src, alt);
        return MarkdownImage(
          path: path,
          alt: alt,
          files: files,
          gallery: gallery,
        );
      },
    );
    Widget blocks(BuildContext context) => MarkdownBlocks(
      nodes: _nodes,
      style: widget.style ?? MarkdownView.baseStyle,
      options: options,
    );
    // Code is a link, and a link's icon a file's, once the file is found.
    if (!widget.data.contains('`') && !widget.data.contains('](')) {
      return blocks(context);
    }
    return ListenableBuilder(
      listenable: files.existence,
      builder: (context, _) => blocks(context),
    );
  }
}

/// The `src` of each image in [nodes], in the order they come.
List<String> _imageSources(List<md.Node> nodes) {
  final sources = <String>[];
  void visit(md.Node node) {
    if (node is! md.Element) return;
    if (node.tag == 'img') sources.add(_unescape(node.attributes['src'] ?? ''));
    node.children?.forEach(visit);
  }

  nodes.forEach(visit);
  return sources;
}

/// An image the chat does not show (one on the web: its address could
/// tell a server what the agent read): its alt text, a link to it.
Widget _imageLink(String src, String alt) {
  final label = '[${alt.isEmpty ? 'image' : alt}]';
  final recognizer = _linkRecognizer(src);
  if (recognizer is! TapGestureRecognizer) {
    return Text(label, style: TextStyle(color: AppColors.textMuted));
  }
  return MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: recognizer.onTap,
      child: IdeHover(
        message: src,
        child: Text(label, style: TextStyle(color: AppColors.accent)),
      ),
    ),
  );
}

/// How [MarkdownBlocks] draws and what its links, images and task boxes
/// do: as the chat's by default.
@immutable
class MarkdownOptions {
  const MarkdownOptions({
    this.headingSizes = const [19, 17, 15, 13.5, 13.5, 13.5],
    this.headingRules = false,
    this.gap = 8,
    this.headingGap = 12,
    this.link,
    this.code,
    this.linkIcon,
    this.codeIcon,
    this.fileTag,
    this.image,
    this.onToggleTask,
  });

  /// `h1` to `h6`'s font sizes.
  final List<double> headingSizes;

  /// Whether `h1` and `h2` have a line under them, as GitHub's.
  final bool headingRules;

  /// The space between blocks, and before and after a heading.
  final double gap;
  final double headingGap;

  /// What a tap on a link to `href` does; web and mail links open in the
  /// browser when null, others nothing.
  final GestureRecognizer? Function(String? href)? link;

  /// What a tap on inline code does (it names a file, say); nothing when
  /// null, or it gives none.
  final GestureRecognizer? Function(String code)? code;

  /// What is drawn before a link to `href` (or inline code, see [code]):
  /// the icon of the file or folder it opens, say; nothing when null.
  final Widget? Function(String? href)? linkIcon;
  final Widget? Function(String code)? codeIcon;

  /// What a link to `href` labeled [label] shows in its place, as a tag:
  /// an image file's, say; the link when null, or it gives none.
  final InlineSpan? Function(String? href, String label)? fileTag;

  /// An image (`![alt](src "title")`, or HTML's with its [width] and
  /// [height] in pixels); its alt text in brackets when null.
  final Widget Function(
    String src,
    String alt,
    String? title, {
    double? width,
    double? height,
  })?
  image;

  /// Called with a task list box's number (see [numberTasks]) when it is
  /// clicked; the boxes are only drawn when null.
  final ValueChanged<int>? onToggleTask;
}

/// Numbers the task list boxes of [nodes], in the order their lines come,
/// for [MarkdownOptions.onToggleTask].
void numberTasks(List<md.Node> nodes) {
  var count = 0;
  void visit(md.Node node) {
    if (node is! md.Element) return;
    if (node.tag == 'input') node.attributes[_taskAttribute] = '${count++}';
    node.children?.forEach(visit);
  }

  nodes.forEach(visit);
}

const _taskAttribute = 'data-task';

/// Parsed markdown ([MarkdownView.document]) as widgets.
class MarkdownBlocks extends StatelessWidget {
  const MarkdownBlocks({
    super.key,
    required this.nodes,
    required this.style,
    this.options = const MarkdownOptions(),
  });

  final List<md.Node> nodes;
  final TextStyle style;
  final MarkdownOptions options;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final node in nodes) {
      final block = _block(node, style, options);
      if (block == null) continue;
      if (children.isNotEmpty) children.add(SizedBox(height: _gap(node)));
      children.add(block);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  double _gap(md.Node node) => switch (node) {
    md.Element(tag: 'h1' || 'h2' || 'h3') => options.headingGap,
    _ => options.gap,
  };
}

Widget? _block(md.Node node, TextStyle style, MarkdownOptions options) {
  if (node is md.Text) {
    if (node.text.trim().isEmpty || isHtmlComment(node.text)) return null;
    return Text.rich(TextSpan(style: style, text: node.text));
  }
  if (node is! md.Element) return null;
  switch (node.tag) {
    case 'math':
      return MathView(node.textContent, display: true);
    case 'p':
      return InlineCodeText(
        _inlines(node.children ?? const [], style, options),
      );
    case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
      final level = int.parse(node.tag.substring(1));
      final heading = Padding(
        padding: const EdgeInsets.only(top: 2),
        child: InlineCodeText(
          _inlines(
            node.children ?? const [],
            style.copyWith(
              color: AppColors.textPrimary,
              fontSize: options.headingSizes[level - 1],
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
            options,
          ),
        ),
      );
      if (!options.headingRules || level > 2) return heading;
      return Container(
        padding: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.partBorder)),
        ),
        child: heading,
      );
    case 'ul' || 'ol':
      return _List(node: node, style: style, options: options);
    case 'pre':
      final code = node.children?.firstOrNull;
      final text = code is md.Element ? code.textContent : node.textContent;
      final language = code is md.Element
          ? code.attributes['class']?.replaceFirst('language-', '')
          : null;
      final body = text.endsWith('\n')
          ? text.substring(0, text.length - 1)
          : text;
      if (CodeCitation.parse(language) case final citation?) {
        return CodeCitationCard(citation: citation, code: body);
      }
      // `python title="a.py"`: the language is the first word.
      final name = language?.trim().split(RegExp(r'\s')).first;
      if (name?.toLowerCase() == 'mermaid') {
        return MermaidCodeBlock(code: body);
      }
      return MarkdownCodeBlock(
        code: body,
        language: name == null || name.isEmpty ? null : name,
      );
    case 'blockquote':
      final children = node.children ?? const <md.Node>[];
      return MarkdownQuoteBlock(
        // Its paragraphs' text, as they read.
        text: children.map((child) => child.textContent).join('\n\n'),
        child: MarkdownBlocks(
          nodes: children,
          style: style.copyWith(color: AppColors.textMuted),
          options: options,
        ),
      );
    case 'hr':
      // As upstream's chat: the separator's color, faint.
      final separator = themeColors['textSeparator.foreground'];
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Divider(
          height: 1,
          color: separator.withValues(alpha: separator.a * 0.33),
        ),
      );
    case 'table':
      return _Table(node: node, style: style, options: options);
    case TagBlockSyntax.tag:
      return TagSection(node: node, style: style, options: options);
    default:
      return InlineCodeText(_inlines([node], style, options));
  }
}

/// A list, numbered or not, whose items may hold blocks and nested lists.
class _List extends StatelessWidget {
  const _List({required this.node, required this.style, required this.options});

  final md.Element node;
  final TextStyle style;
  final MarkdownOptions options;

  @override
  Widget build(BuildContext context) {
    final ordered = node.tag == 'ol';
    final start = int.tryParse(node.attributes['start'] ?? '') ?? 1;
    final items = [
      for (final child in node.children ?? const <md.Node>[])
        if (child is md.Element && child.tag == 'li') child,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, item) in items.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: ordered ? 24 : 18,
                  child: _marker(item, ordered ? '${start + i}.' : '•'),
                ),
                Expanded(child: _itemBody(item)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _marker(md.Element item, String text) {
    final checkbox = item.children?.firstOrNull;
    if (checkbox is md.Element && checkbox.tag == 'input') {
      final checked = checkbox.attributes['checked'] != null;
      final box = Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Icon(
          checked ? Icons.check_box_rounded : Icons.check_box_outline_blank,
          size: 14,
          color: checked ? AppColors.added : AppColors.textMuted,
        ),
      );
      final toggle = options.onToggleTask;
      final task = int.tryParse(checkbox.attributes[_taskAttribute] ?? '');
      if (toggle == null || task == null) return box;
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => toggle(task),
          child: box,
        ),
      );
    }
    return Text(text, style: style.copyWith(color: AppColors.textMuted));
  }

  /// An item's text and blocks: a tight item's text is inline children, a
  /// loose one's is paragraphs.
  Widget _itemBody(md.Element item) {
    final children = [
      for (final child in item.children ?? const <md.Node>[])
        if (!(child is md.Element && child.tag == 'input')) child,
    ];
    final inline = <md.Node>[];
    final blocks = <Widget>[];
    void flush() {
      if (inline.isEmpty) return;
      blocks.add(InlineCodeText(_inlines([...inline], style, options)));
      inline.clear();
    }

    for (final child in children) {
      final isBlock =
          child is md.Element &&
          const {
            'p',
            'ul',
            'ol',
            'pre',
            'blockquote',
            'table',
            'h1',
            'h2',
            'h3',
            'h4',
            'hr',
          }.contains(child.tag);
      if (!isBlock) {
        inline.add(child);
        continue;
      }
      flush();
      final block = _block(child, style, options);
      if (block != null) blocks.add(block);
    }
    flush();
    if (blocks.length == 1) return blocks.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, block) in blocks.indexed) ...[
          if (i > 0) const SizedBox(height: 4),
          block,
        ],
      ],
    );
  }
}

/// A table in a card as the steps' are, as wide as its columns up to the
/// width there is; wider, it scrolls sideways, with a bar to show it while
/// the pointer is over it or it scrolls.
class _Table extends StatefulWidget {
  const _Table({
    required this.node,
    required this.style,
    required this.options,
  });

  final md.Element node;
  final TextStyle style;
  final MarkdownOptions options;

  @override
  State<_Table> createState() => _TableState();
}

class _TableState extends State<_Table> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final rows = <(bool, List<md.Element>)>[];
    for (final section in widget.node.children ?? const <md.Node>[]) {
      if (section is! md.Element) continue;
      for (final row in section.children ?? const <md.Node>[]) {
        if (row is! md.Element || row.tag != 'tr') continue;
        rows.add((
          section.tag == 'thead',
          [
            for (final cell in row.children ?? const <md.Node>[])
              if (cell is md.Element) cell,
          ],
        ));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows
        .map((row) => row.$2.length)
        .reduce((a, b) => a > b ? a : b);
    final line = BorderSide(color: themeColors['chat.requestBorder']);
    final table = Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      // The card draws the edge.
      border: TableBorder.symmetric(inside: line),
      children: [
        for (final (header, cells) in rows)
          TableRow(
            decoration: header
                ? BoxDecoration(color: AppColors.surfaceRaised)
                : null,
            children: [
              for (var i = 0; i < columns; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: i < cells.length
                      ? InlineCodeText(
                          _inlines(
                            cells[i].children ?? const [],
                            header
                                ? style.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  )
                                : style,
                            widget.options,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
            ],
          ),
      ],
    );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        // The edge over the cells, the header's color clipped to the corners.
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.fromBorderSide(line),
        ),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: HoverScrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: table,
          ),
        ),
      ),
    );
  }
}

TextSpan _inlines(
  List<md.Node> nodes,
  TextStyle style,
  MarkdownOptions options,
) => TextSpan(
  style: style,
  children: [for (final node in nodes) _inline(node, options)],
);

InlineSpan _inline(md.Node node, MarkdownOptions options) {
  if (node is md.Text) {
    // A comment is the writer's note, not shown (as HTML has it); the
    // parser joins it to the text after it.
    final text = node.text.contains('<!--')
        ? node.text.replaceAll(_htmlComment, '')
        : node.text;
    return TextSpan(text: _unescape(text));
  }
  if (node is! md.Element) return const TextSpan();
  final children = node.children ?? const <md.Node>[];
  List<InlineSpan> inner() => [
    for (final child in children) _inline(child, options),
  ];
  if (node.tag == 'a') {
    final href = node.attributes['href'];
    if (options.fileTag?.call(href, _unescape(node.textContent))
        case final tag?) {
      return tag;
    }
  }
  return switch (node.tag) {
    'strong' || 'b' => TextSpan(
      style: TextStyle(
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      children: inner(),
    ),
    'em' || 'i' => TextSpan(
      style: const TextStyle(fontStyle: FontStyle.italic),
      children: inner(),
    ),
    'del' => TextSpan(
      style: const TextStyle(decoration: TextDecoration.lineThrough),
      children: inner(),
    ),
    'code' => switch (options.code?.call(_unescape(node.textContent))) {
      // A file's: in the link's color, its icon first in the background.
      final recognizer? => InlineCodeSpan(
        style: MarkdownView.codeStyle.copyWith(color: AppColors.accent),
        children: [
          if (options.codeIcon?.call(_unescape(node.textContent))
              case final icon?)
            _linkIcon(
              icon,
              recognizer,
              const EdgeInsets.only(left: 4, right: 3),
            )
          else
            const TextSpan(text: ' '),
          TextSpan(
            text: '${_unescape(node.textContent)} ',
            recognizer: recognizer,
            mouseCursor: SystemMouseCursors.click,
          ),
        ],
      ),
      null => InlineCodeSpan(
        text: ' ${_unescape(node.textContent)} ',
        style: MarkdownView.codeStyle,
      ),
    },
    'a' => switch ((options.link ?? _linkRecognizer)(node.attributes['href'])) {
      final recognizer? => TextSpan(
        style: TextStyle(color: AppColors.accent),
        children: [
          if (options.linkIcon?.call(node.attributes['href']) case final icon?)
            _linkIcon(icon, recognizer, const EdgeInsets.only(right: 3)),
          for (final span in inner()) _linked(span, recognizer),
        ],
      ),
      null => TextSpan(
        style: TextStyle(color: AppColors.accent),
        children: inner(),
      ),
    },
    'math' => WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MathView(
        node.textContent,
        display: node.attributes['display'] == 'block',
      ),
    ),
    'br' => const TextSpan(text: '\n'),
    'img' => switch (options.image) {
      final image? => WidgetSpan(
        child: image(
          _unescape(node.attributes['src'] ?? ''),
          _unescape(node.attributes['alt'] ?? ''),
          node.attributes['title'],
          width: double.tryParse(node.attributes['width'] ?? ''),
          height: double.tryParse(node.attributes['height'] ?? ''),
        ),
      ),
      null => TextSpan(text: '[${node.attributes['alt'] ?? 'image'}]'),
    },
    _ => TextSpan(children: inner()),
  };
}

/// Opens [href] in the default browser (or mail app). Only web and mail
/// links: the text is the agent's, and `open` would as well run a local
/// file or app.
GestureRecognizer? _linkRecognizer(String? href) {
  final uri = href == null ? null : Uri.tryParse(href.trim());
  if (uri == null || !const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
    return null;
  }
  return TapGestureRecognizer()..onTap = () => openExternal(uri.toString());
}

/// Whether [text] is HTML comments alone (`<!-- note -->`), which do not
/// show.
bool isHtmlComment(String text) => _htmlComments.hasMatch(text);

final _htmlComments = RegExp(r'^\s*(?:<!--[\s\S]*?-->\s*)+$');
final _htmlComment = RegExp(r'<!--[\s\S]*?-->');

const _fileIconSize = 14.0;

/// Whether a link to [written] (as the agent wrote it), [known] to be a
/// file or not (see [FileExistence.known]), goes to a folder: one written
/// with a slash after it, or a name without an extension that is not a
/// file found (`lib/ide`, not `LICENSE`).
bool _isFolder(String written, bool? known) {
  if (written.endsWith('/') || written.endsWith(r'\')) return true;
  if (known == true) return false;
  final name = written.split(RegExp(r'[/\\]')).last;
  // A leading dot is not an extension's (`.github`).
  return name.lastIndexOf('.') <= 0;
}

/// [icon] before a link: a tap on it goes where the link does.
WidgetSpan _linkIcon(
  Widget icon,
  GestureRecognizer recognizer,
  EdgeInsets padding,
) {
  icon = Padding(padding: padding, child: icon);
  if (recognizer is FileLinkRecognizer) {
    icon = FileLinkMenuRegion(menu: recognizer.menu, child: icon);
  }
  if (recognizer is TapGestureRecognizer) {
    icon = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: recognizer.onTap,
        child: icon,
      ),
    );
  }
  return WidgetSpan(alignment: PlaceholderAlignment.middle, child: icon);
}

/// [span] with every piece of its text tappable: a tap lands on the
/// innermost span, which does not inherit its parent's recognizer.
InlineSpan _linked(InlineSpan span, GestureRecognizer recognizer) =>
    switch (span) {
      // Code in a link keeps its background, and goes where the link does.
      InlineCodeSpan(:final text, :final style) => InlineCodeSpan(
        text: text,
        style: style,
        recognizer: recognizer,
        mouseCursor: SystemMouseCursors.click,
      ),
      // An image in a link (`[![alt](src)](href)`).
      WidgetSpan(:final child, :final alignment)
          when recognizer is TapGestureRecognizer =>
        WidgetSpan(
          alignment: alignment,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(onTap: recognizer.onTap, child: child),
          ),
        ),
      TextSpan(:final text, :final style, :final children) => TextSpan(
        text: text,
        style: style,
        recognizer: recognizer,
        mouseCursor: SystemMouseCursors.click,
        children: [
          for (final child in children ?? const <InlineSpan>[])
            _linked(child, recognizer),
        ],
      ),
      _ => span,
    };

String _unescape(String text) => text
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'");
