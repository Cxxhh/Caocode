import 'package:caocode/ide/ide_workspace.dart';
import 'package:caocode/ide/lsp/language_features.dart';
import 'package:caocode/ide/lsp/lsp_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'lsp_ui/fake_language_features.dart';
import 'workbench/fake_files.dart';

/// Language servers the workspace keeps in sync, as the LSP manager.
class _Servers extends FakeLanguageFeatures implements LanguageDocumentSync {
  _Servers({super.supported});

  final Map<String, String> open = {};
  final List<String> events = [];

  @override
  void openDocument(String path, String text, {int version = 0}) {
    events.add('open');
    open[path] = text;
  }

  @override
  void changeDocument(
    String path,
    String text, {
    required int version,
    List<LspTextDocumentContentChange>? changes,
  }) => open[path] = text;

  @override
  void saveDocument(String path, String text) {}

  @override
  void closeDocument(String path) {
    events.add('close');
    open.remove(path);
  }

  @override
  Future<void> shutdown() async {}
}

const _edit = LspTextEdit(
  LspRange(LspPosition(0, 0), LspPosition(0, 0)),
  '// formatted\n',
);

void main() {
  final a = inRoot('a.ts');

  IdeWorkspace workspaceWith(_Servers servers, {String text = 'let a=1'}) {
    final workspace = IdeWorkspace(
      testRoot,
      files: TreeFiles({a: text}),
      languages: servers,
    );
    addTearDown(workspace.dispose);
    addTearDown(servers.dispose);
    return workspace;
  }

  Future<IdeFormatOutcome> format(IdeWorkspace workspace, String text) =>
      workspace.formatOutside(a, text, tabSize: 2, insertSpaces: true);

  test('a file no tab has: open with the servers while they format its '
      'text', () async {
    final servers = _Servers(supported: {LanguageRequest.format});
    String? formatted;
    servers.onFormat = (path, range) {
      formatted = servers.open[path];
      return const [_edit];
    };
    final workspace = workspaceWith(servers);
    final outcome = await format(workspace, 'let b=2');
    expect(outcome.edits, [_edit]);
    expect(formatted, 'let b=2');
    expect(servers.events, ['open', 'close']);
  });

  test('its servers waited for as they start', () async {
    final servers = _Servers(supported: {})
      ..statuses[a] = const [
        LanguageServerStatus(
          serverId: 'ts',
          state: LanguageServerState.starting,
        ),
      ]
      ..onFormat = (path, range) => const [_edit];
    final workspace = workspaceWith(servers);
    final formatting = format(workspace, 'let b=2');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    servers
      ..supported = {LanguageRequest.format}
      ..statuses[a] = const [
        LanguageServerStatus(
          serverId: 'ts',
          state: LanguageServerState.running,
        ),
      ];
    expect((await formatting).edits, [_edit]);
  });

  test('two of one file at once: each formats its own text', () async {
    final servers = _Servers(supported: {})
      ..statuses[a] = const [
        LanguageServerStatus(
          serverId: 'ts',
          state: LanguageServerState.starting,
        ),
      ];
    final formatted = <String?>[];
    servers.onFormat = (path, range) {
      formatted.add(servers.open[path]);
      return const [_edit];
    };
    final workspace = workspaceWith(servers);
    // The second asked for while the first waits for its servers.
    final first = format(workspace, 'let b=2');
    final second = format(workspace, 'let c=3');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    servers
      ..supported = {LanguageRequest.format}
      ..statuses[a] = const [
        LanguageServerStatus(
          serverId: 'ts',
          state: LanguageServerState.running,
        ),
      ];
    expect((await first).edits, [_edit]);
    expect((await second).edits, [_edit]);
    expect(formatted, ['let b=2', 'let c=3']);
    expect(servers.events, ['open', 'close', 'open', 'close']);
  });

  test('none formats it: which server would, to install', () async {
    final servers = _Servers(supported: {})
      ..statuses[a] = const [
        LanguageServerStatus(
          serverId: 'ts',
          state: LanguageServerState.missing,
          installable: true,
        ),
      ];
    final workspace = workspaceWith(servers);
    final outcome = await format(workspace, 'let b=2');
    expect(outcome.edits, isNull);
    expect(outcome.missing, 'ts');
    await outcome.install!();
    expect(servers.installed, ['ts']);
    expect(servers.events, ['open', 'close']);
  });

  test("a file a tab has: the servers have the tab's text", () async {
    final servers = _Servers(supported: {LanguageRequest.format})
      ..onFormat = (path, range) => const [_edit];
    final workspace = workspaceWith(servers);
    await workspace.open(a);
    servers.events.clear();
    expect((await format(workspace, 'let a=1')).edits, [_edit]);
    // Not opened again, nor closed under the tab.
    expect(servers.events, isEmpty);
    // Another text than the tab's: not theirs to format.
    expect((await format(workspace, 'let b=2')).edits, isNull);
  });
}
