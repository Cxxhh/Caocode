// The files page's text search (#82): the header's magnifier shows the
// search in place of the tree, the results come from the engine the IDE
// searches with, and a result opens its file at its line.

import 'package:caocode/ide/ide_notifications.dart';
import 'package:caocode/chat/chat_session.dart';
import 'package:caocode/chat/side_panel/file_link.dart';
import 'package:caocode/chat/side_panel/side_panel_controller.dart';
import 'package:caocode/chat/side_panel/side_panel_view.dart';
import 'package:caocode/ide/file_service.dart';
import 'package:caocode/ide/ide_explorer.dart';
import 'package:caocode/ide/search/ide_search_view.dart';
import 'package:caocode/ide/ide_input.dart';
import 'package:caocode/ide/search/text_search.dart';
import 'package:caocode/kernel/agent_kernel.dart';
import 'package:caocode/theme/app_theme.dart';
import 'package:caocode/theme/code_font.dart';
import 'package:caocode/theme/codicons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Files in memory.
class _Files implements IdeFileService {
  _Files(this.texts);

  final Map<String, String> texts;

  @override
  Future<String> read(String path, {bool force = false}) async =>
      texts[path] ?? (throw IdeFileNotFoundException(path));

  @override
  Future<List<IdeFile>> list(String directory) async {
    final entries = <String, bool>{};
    for (final path in texts.keys) {
      if (!p.isWithin(directory, path)) continue;
      final relative = p.split(p.relative(path, from: directory));
      entries[p.join(directory, relative.first)] = relative.length > 1;
    }
    return [
      for (final MapEntry(key: path, value: isDirectory) in entries.entries)
        IdeFile(path, p.basename(path), isDirectory: isDirectory),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _project = '/code/site';

final _files = _Files({
  '$_project/index.html': '<html>\nhello world\n</html>',
  '$_project/app.js': 'const greeting = "hello";\n',
});

/// The engine the IDE searches with, over [_files]: what the panel is
/// given so its results match.
Stream<Object> _engine(String root, IdeTextQuery query) async* {
  final accept = query.pathFilter();
  final regExp = query.toRegExp();
  for (final MapEntry(key: path, value: text) in _files.texts.entries) {
    final relative = p.relative(path, from: root).replaceAll(r'\', '/');
    if (!accept(relative)) continue;
    final matches = ideMatchLines(text, regExp);
    if (matches.isNotEmpty) yield IdeFileMatches(path, matches);
  }
  yield const IdeTextSearchComplete(limitHit: false);
}

Future<({AgentSidePanel panel, ChatSession session})> _pump(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = ChatSession(
    kernelContext: const KernelContext(cwd: _project),
    openReview: (root, {session}) async => null,
  );
  addTearDown(session.dispose);
  final panel = AgentSidePanel();
  addTearDown(panel.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      localizationsDelegates: const [FlutterQuillLocalizations.delegate],
      home: ValueListenableBuilder<double>(
        valueListenable: CodeFont.size,
        builder: (context, _, _) => Material(
          child: AgentSidePanelArea(
            panel: panel,
            builder: (context) => AgentSidePanelView(
              notifications: IdeNotifications(),
              panel: panel,
              session: session,
              files: _files,
              watchDirectory: (_) => const Stream.empty(),
              searchEngine: _engine,
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ),
  );
  panel.showSection(session, SidePanelSection.files);
  await tester.pumpAndSettle();
  return (panel: panel, session: session);
}

Finder get _list => find.byKey(const ValueKey('side-panel-list'));

Finder _headerIcon(IconData icon) =>
    find.descendant(of: _list, matching: find.byIcon(icon));

void main() {
  testWidgets('the header has the search button, left of refresh', (
    tester,
  ) async {
    await _pump(tester);
    expect(_headerIcon(Codicons.search), findsOneWidget);
    // Left of the refresh button, as asked for.
    final search = tester.getCenter(_headerIcon(Codicons.search));
    final refresh = tester.getCenter(_headerIcon(Codicons.refresh));
    expect(search.dx, lessThan(refresh.dx));
  });

  testWidgets('the magnifier shows the search in place of the tree', (
    tester,
  ) async {
    await _pump(tester);
    expect(
      find.descendant(of: _list, matching: find.byType(IdeExplorer)),
      findsOneWidget,
    );
    expect(find.byType(IdeSearchView), findsNothing);

    await tester.tap(_headerIcon(Codicons.search));
    await tester.pumpAndSettle();

    expect(find.byType(IdeSearchView), findsOneWidget);
    expect(
      find.descendant(of: _list, matching: find.byType(IdeExplorer)),
      findsNothing,
    );
  });

  testWidgets('closing the search brings the tree back', (tester) async {
    await _pump(tester);
    await tester.tap(_headerIcon(Codicons.search));
    await tester.pumpAndSettle();

    await tester.tap(_headerIcon(Codicons.close));
    await tester.pumpAndSettle();

    expect(find.byType(IdeSearchView), findsNothing);
    expect(
      find.descendant(of: _list, matching: find.byType(IdeExplorer)),
      findsOneWidget,
    );
  });

  testWidgets('Escape closes the search', (tester) async {
    await _pump(tester);
    await tester.tap(_headerIcon(Codicons.search));
    await tester.pumpAndSettle();
    expect(find.byType(IdeSearchView), findsOneWidget);
    // In the query box, as it is on opening the search.
    await tester.tap(
      find.descendant(of: _list, matching: find.byType(EditableText)).first,
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(IdeSearchView), findsNothing);
  });

  testWidgets('a search lists its results, and a match opens at its line', (
    tester,
  ) async {
    final (:panel, :session) = await _pump(tester);
    await tester.tap(_headerIcon(Codicons.search));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(of: _list, matching: find.byType(EditableText)).first,
      'hello',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // Both files matched, by name.
    expect(
      find.descendant(of: _list, matching: find.text('index.html')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _list, matching: find.text('app.js')),
      findsOneWidget,
    );

    // A match opens its file at its line (1-based for the side panel).
    final match = find
        .descendant(of: _list, matching: find.textContaining('hello'))
        .last;
    await tester.tap(match);
    await tester.pumpAndSettle();

    final tab = panel.tabsOf(session).current;
    expect(
      tab?.request.path,
      anyOf('$_project/index.html', '$_project/app.js'),
    );
    expect(tab?.request.range, isA<FileLineRange>());
  });

  testWidgets('the search offers no replacing: the side panel only looks', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_headerIcon(Codicons.search));
    await tester.pumpAndSettle();

    final view = tester.widget<IdeSearchView>(find.byType(IdeSearchView));
    expect(view.replaceBackend, isNull);
    // The query alone: no replace input beside it.
    expect(
      find.descendant(
        of: _list,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is IdeInputBox && widget.semanticsLabel == 'Replace',
        ),
      ),
      findsNothing,
    );
  });
}
