import 'dart:async';
import 'dart:io';

import 'package:caocode/channel/account/channel_account.dart';
import 'package:caocode/channel/channel_gate.dart';
import 'package:caocode/channel/channel_setup.dart';
import 'package:caocode/channel/channel_setup_welcome.dart';
import 'package:caocode/l10n/l10n.dart';
import 'package:caocode/models/model_providers.dart';
import 'package:caocode/models/upstream.dart';
import 'package:caocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_fakes.dart';

const _id = '3f2b8c1e-9a4d-4f6b-8e2a-1c3d5e7f9a0b';
const _again = '9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f';

/// As site/channels.json lists them.
const _channels = <String, Object?>{
  'youtube': {
    'logo': '/channels/youtube.svg',
    'name': {'zh': 'YouTube', 'en': 'YouTube'},
    'account': {'type': 'newapi', 'url': 'https://panel.example'},
  },
};

const _withWelcome = <String, Object?>{
  'youtube': {
    'logo': '/channels/youtube.svg',
    'name': {'zh': 'YouTube', 'en': 'YouTube'},
    'account': {
      'type': 'sub2api',
      'url': 'https://panel.example/login',
      'apiUrl': 'https://api.example',
      'protocol': 'openai-chat',
    },
    'welcome': {
      'title': {'zh': 'YouTube 的朋友，欢迎', 'en': 'Welcome, YouTube friends'},
      'text': {'zh': '登录后领取额度。', 'en': 'Sign in for credits.'},
    },
  },
};

/// What the stats server answers, as each question comes: null while it
/// has nothing, [offline] throwing.
class FakeServer {
  ChannelAttribution? kept;
  bool offline = false;
  final List<Uri> asked = [];

  Future<ChannelAttribution?> lookUp(Uri url) async {
    asked.add(url);
    if (offline) throw const SocketException('offline');
    return kept;
  }
}

void main() {
  late FakeServer server;
  late MemoryChannelSetupStore store;
  late List<Uri> opened;

  ChannelSetup setupOf({
    Duration poll = const Duration(milliseconds: 5),
    String? again,
  }) => ChannelSetup(
    store: store,
    installId: _id,
    again: again,
    lookUp: server.lookUp,
    open: (url) async {
      opened.add(url);
      return true;
    },
    pollInterval: poll,
  );

  setUp(() {
    server = FakeServer();
    store = MemoryChannelSetupStore();
    opened = [];
  });

  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue);
  }

  group('ChannelSetup.begin', () {
    test('the channel build marks its first start pending, for good', () {
      expect(ChannelSetup.begin(store, build: true), isTrue);
      expect(store.state, ChannelSetup.pendingState);
      // An update to the standard build: still to do.
      expect(ChannelSetup.begin(store, build: false), isTrue);
      store.state = ChannelSetup.doneState;
      expect(ChannelSetup.begin(store, build: true), isFalse);
      expect(store.state, ChannelSetup.doneState);
    });

    test('the standard build has nothing to set up', () {
      expect(ChannelSetup.begin(store, build: false), isFalse);
      expect(store.state, isNull);
    });

    test('the edition is channel from its first start on', () {
      expect(ChannelSetup.editionOf(store), 'standard');
      ChannelSetup.begin(store, build: true);
      expect(ChannelSetup.editionOf(store), 'channel');
      store.state = ChannelSetup.doneState;
      expect(ChannelSetup.editionOf(store), 'channel');
    });
  });

  group('ChannelAttribution', () {
    test('takes what the server takes, the value lower-cased', () {
      expect(
        ChannelAttribution.of('channel', 'YouTube'),
        const ChannelAttribution('channel', 'youtube'),
      );
      expect(
        ChannelAttribution.of('channel', '小红书_2026'),
        const ChannelAttribution('channel', '小红书_2026'),
      );
      expect(
        ChannelAttribution.of('referrer', 'github.com'),
        const ChannelAttribution('referrer', 'github.com'),
      );
      expect(
        ChannelAttribution.of('direct', null),
        const ChannelAttribution('direct', null),
      );
      expect(
        ChannelAttribution.of('none', ''),
        const ChannelAttribution('none', null),
      );
    });

    test('is null when malformed', () {
      expect(ChannelAttribution.of('channel', null), isNull);
      expect(ChannelAttribution.of('channel', 'a b'), isNull);
      expect(ChannelAttribution.of('channel', 'x' * 129), isNull);
      expect(ChannelAttribution.of('direct', 'x'), isNull);
      expect(ChannelAttribution.of('ads', 'x'), isNull);
      expect(ChannelAttribution.of(null, null), isNull);
    });

    test('is read back as it is kept', () {
      for (final told in const [
        ChannelAttribution('channel', 'youtube'),
        ChannelAttribution('none', null),
      ]) {
        expect(ChannelAttribution.fromJson(told.toJson()), told);
      }
      expect(ChannelAttribution.fromJson({'source': 'direct'}), isNotNull);
      expect(ChannelAttribution.fromJson('channel'), isNull);
    });
  });

  group('ChannelInfo', () {
    test('reads a channel in the language asked, English without', () {
      final info = ChannelInfo.parse(_withWelcome['youtube'], 'zh')!;
      expect(info.name, 'YouTube');
      expect(info.logo, '/channels/youtube.svg');
      expect(info.welcome!.title, 'YouTube 的朋友，欢迎');
      expect(info.welcome!.text, '登录后领取额度。');
      expect(info.welcome!.button, isNull);
      final french = ChannelInfo.parse(_withWelcome['youtube'], 'fr')!;
      expect(french.welcome!.title, 'Welcome, YouTube friends');
      expect(ChannelInfo.parse(_channels['youtube'], 'zh')!.welcome, isNull);
    });

    test('reads its account site: the panel\'s origin, where the models '
        'are, how they are spoken to', () {
      final site = ChannelInfo.parse(_withWelcome['youtube'], 'en')!.account!;
      expect(site.type, ChannelAccountType.sub2api);
      expect(site.url, Uri.parse('https://panel.example'));
      expect(site.apiUrl, Uri.parse('https://api.example'));
      expect(site.protocol, 'openai-chat');
      final plain = ChannelInfo.parse(_channels['youtube'], 'en')!.account!;
      expect(plain.type, ChannelAccountType.newApi);
      expect(plain.apiUrl, plain.url);
      expect(plain.protocol, isNull);
    });

    test('takes the button\'s own label', () {
      final info = ChannelInfo.parse({
        'name': {'en': 'X'},
        'welcome': {
          'title': {'en': 'T'},
          'text': {'en': 'B'},
          'button': {'zh': '去领取', 'en': 'Claim'},
        },
      }, 'zh')!;
      expect(info.welcome!.button, '去领取');
    });

    test('leaves out what is malformed', () {
      expect(ChannelInfo.parse({'logo': '/channels/x.svg'}, 'en'), isNull);
      expect(ChannelInfo.parse('youtube', 'en'), isNull);
      final info = ChannelInfo.parse({
        'name': {'en': 'X'},
        'logo': 'https://evil.example/x.svg',
      }, 'en')!;
      expect(info.logo, isNull);
      expect(info.account, isNull);
      for (final account in [
        {'type': 'newapi', 'url': 'http://panel.example'},
        {'type': 'oneapi', 'url': 'https://panel.example'},
        {'type': 'newapi'},
        {'type': 'newapi', 'url': 'javascript:x'},
        'https://panel.example',
      ]) {
        expect(
          ChannelInfo.parse({
            'name': {'en': 'X'},
            'account': account,
          }, 'en')!.account,
          isNull,
          reason: '$account',
        );
      }
      expect(
        ChannelAccountSite.parse({
          'type': 'newapi',
          'url': 'https://panel.example',
          'apiUrl': 'http://api.example',
          'protocol': 'carrier-pigeon',
        }),
        isA<ChannelAccountSite>()
            .having(
              (s) => s.apiUrl,
              'apiUrl',
              Uri.parse('https://panel.example'),
            )
            .having((s) => s.protocol, 'protocol', isNull),
      );
      for (final welcome in [
        {
          'text': {'en': 'B'},
        },
        {
          'title': {'en': 'T'},
        },
      ]) {
        expect(
          ChannelInfo.parse({
            'name': {'en': 'X'},
            'welcome': welcome,
          }, 'en')!.welcome,
          isNull,
          reason: '$welcome',
        );
      }
    });
  });

  group('ChannelSetup', () {
    test('opens the page with the install id, in the app language', () async {
      final setup = setupOf(poll: const Duration(hours: 1));
      addTearDown(setup.dispose);
      await setup.openPage(zh: false);
      await setup.openPage(zh: true);
      expect(opened, [
        Uri.parse('https://caocode.dev/activate#i=$_id'),
        Uri.parse('https://caocode.dev/zh/activate#i=$_id'),
      ]);
      expect(setup.waiting, isTrue);
    });

    test('asks the stats server while the page is open, and is done once '
        'it says', () async {
      final setup = setupOf();
      addTearDown(setup.dispose);
      var started = false;
      unawaited(setup.started.then((_) => started = true));
      await setup.openPage(zh: false);
      await until(() => server.asked.length >= 2);
      expect(setup.done, isFalse);
      expect(server.asked.first, Uri.parse('$lookUpBase$_id'));

      server.kept = const ChannelAttribution('channel', 'youtube');
      await until(() => setup.done);
      expect(store.state, ChannelSetup.doneState);
      expect(store.attribution, const ChannelAttribution('channel', 'youtube'));
      expect(setup.waiting, isFalse);
      // No more questions once done.
      final asked = server.asked.length;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(server.asked.length, asked);
      // Get Started is what the welcome to models waits for.
      await pumpEventQueue();
      expect(started, isFalse);
      setup.start();
      await pumpEventQueue();
      expect(started, isTrue);
    });

    test('is done at once when a run before was told', () async {
      server.kept = const ChannelAttribution('direct', null);
      final setup = setupOf();
      addTearDown(setup.dispose);
      await setup.check();
      expect(setup.done, isTrue);
      expect(opened, isEmpty);
    });

    test('says when the server cannot be reached, till it can', () async {
      server.offline = true;
      final setup = setupOf();
      addTearDown(setup.dispose);
      // Not before the page is opened.
      await setup.check();
      await setup.check();
      expect(setup.offline, isFalse);
      await setup.openPage(zh: false);
      await until(() => setup.offline);
      server.offline = false;
      await until(() => !setup.offline);
      expect(setup.done, isFalse);
    });

    test('takes the link the page hands over', () {
      final setup = setupOf();
      addTearDown(setup.dispose);
      expect(
        setup.acceptLink(' caocode://activate?i=$_id&s=channel&c=YouTube\n'),
        ChannelLinkResult.accepted,
      );
      expect(setup.done, isTrue);
      expect(store.attribution, const ChannelAttribution('channel', 'youtube'));
    });

    test('takes one without a value, for direct and none', () {
      final setup = setupOf();
      addTearDown(setup.dispose);
      expect(
        setup.acceptLink('caocode://activate?i=$_id&s=none'),
        ChannelLinkResult.accepted,
      );
      expect(store.attribution, const ChannelAttribution('none', null));
    });

    test('turns down a link not the page’s, or another install’s', () {
      final setup = setupOf();
      addTearDown(setup.dispose);
      for (final link in [
        '',
        'https://caocode.dev/activate#i=$_id',
        'caocode://provider/import?v=1',
        'caocode://activate?i=$_id',
        'caocode://activate?i=$_id&s=channel',
        'caocode://activate?i=$_id&s=ads&c=x',
      ]) {
        expect(setup.acceptLink(link), ChannelLinkResult.invalid, reason: link);
      }
      expect(
        setup.acceptLink(
          'caocode://activate?i=00000000-0000-4000-8000-000000000000&s=direct',
        ),
        ChannelLinkResult.otherInstall,
      );
      expect(setup.done, isFalse);
      expect(store.state, isNull);
    });

    test('asks once more, done before: the page and the server told the '
        'asking, what it says replacing what was kept', () async {
      store
        ..state = ChannelSetup.doneState
        ..attribution = const ChannelAttribution('channel', 'youtube');
      final setup = setupOf(again: _again);
      addTearDown(setup.dispose);
      expect(setup.done, isFalse);
      await setup.openPage(zh: false);
      expect(opened, [
        Uri.parse('https://caocode.dev/activate#i=$_id&again=$_again'),
      ]);
      server.kept = const ChannelAttribution('channel', 'aijws');
      await until(() => setup.done);
      expect(server.asked.first, Uri.parse('$lookUpBase$_id?again=$_again'));
      expect(store.attribution, const ChannelAttribution('channel', 'aijws'));
      expect(store.state, ChannelSetup.doneState);
    });

    test('tells its links from the other caocode:// links', () {
      expect(ChannelSetup.isLink('caocode://activate?i=x'), isTrue);
      expect(ChannelSetup.isLink('caocode://provider/import?v=1'), isFalse);
      expect(ChannelSetup.isLink('https://caocode.dev/activate'), isFalse);
    });
  });

  test('the global storage reads back what was set, and keeps it', () async {
    final folder = await Directory.systemTemp.createTemp('channel_setup');
    addTearDown(() => folder.delete(recursive: true));
    final path = '${folder.path}/storage.json';
    final storage = GlobalStorage(path, debounce: Duration.zero);
    await storage.load();
    final kept = GlobalChannelSetupStore(storage);
    expect(ChannelSetup.begin(kept, build: true), isTrue);
    kept
      ..attribution = const ChannelAttribution('channel', 'youtube')
      ..state = ChannelSetup.doneState;
    expect(kept.state, ChannelSetup.doneState);
    for (var i = 0; i < 100; i++) {
      if (File(path).existsSync() &&
          File(path).readAsStringSync().contains('done')) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final again = GlobalStorage(path);
    await again.load();
    final read = GlobalChannelSetupStore(again);
    expect(read.state, ChannelSetup.doneState);
    expect(read.attribution, const ChannelAttribution('channel', 'youtube'));
  });

  group('the welcome', () {
    late List<FakeLoginWindow> windows;
    late MemoryChannelAccountStore accounts;

    tearDown(() => ChannelAccount.current = null);

    Future<({Future<void> closed, ChannelGate gate})> open(
      WidgetTester tester,
      ChannelSetup? setup, {
      List<String>? troubles,
      Map<String, Object?>? channels,
      ChannelSetup Function()? again,
    }) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      windows = [];
      accounts = MemoryChannelAccountStore();
      final site = newApiSite();
      final providers = ModelProviders.memory();
      final gate = ChannelGate(
        setup: setup,
        setupStore: setup?.store ?? store,
        accountStore: accounts,
        fetch: (id) async => switch ((channels ?? _channels)[id]) {
          final Object json => (id: id, json: json, logo: null),
          null => null,
        },
        makeAccount: (channel) => ChannelAccount(
          site: channel.info.account!,
          channelName: channel.info.name,
          store: accounts,
          send: site.send,
          listModels: (_, _) async => const [RemoteModel('claude-sonnet-4-5')],
          providers: () => providers,
          openWindow: () {
            final window = FakeLoginWindow();
            windows.add(window);
            return window;
          },
          pollInterval: const Duration(milliseconds: 100),
        ),
        makeSetupAgain: again,
      );
      addTearDown(gate.dispose);
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      final closed = showChannelSetupWelcome(
        context,
        gate: gate,
        trouble: (_) => troubles?.add('trouble'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      return (closed: closed, gate: gate);
    }

    /// Signs in in the login window: done once the welcome has closed.
    Future<void> signIn(WidgetTester tester) async {
      await tester.tap(find.text('登录'));
      await tester.pump();
      expect(find.text('请在弹出的窗口中登录…'), findsOneWidget);
      windows.single.cookieJar = {'new_api_refresh': 'r0'};
      await tester.pump(const Duration(milliseconds: 100));
      // The account read and a key put to use, over a few requests.
      for (var i = 0; i < 20; i++) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('stays till set up: Escape, Enter and a click beside it '
        'leave it', (tester) async {
      final setup = setupOf(poll: const Duration(hours: 1));
      addTearDown(setup.dispose);
      await open(tester, setup);
      expect(find.text('欢迎使用 Caocode'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('欢迎使用 Caocode'), findsOneWidget);
      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('欢迎使用 Caocode'), findsOneWidget);
    });

    testWidgets('opens the page, waits for it, then welcomes the channel’s '
        'user, who signs in to go on', (tester) async {
      final setup = setupOf(poll: const Duration(seconds: 3));
      addTearDown(setup.dispose);
      var started = false;
      unawaited(setup.started.then((_) => started = true));
      final shown = await open(tester, setup);
      await tester.tap(find.text('在浏览器中完成设置').last);
      await tester.pump();
      expect(opened, [Uri.parse('https://caocode.dev/zh/activate#i=$_id')]);
      expect(find.text('正在等待浏览器完成…'), findsOneWidget);
      expect(find.text('重新打开网页'), findsOneWidget);

      server.kept = const ChannelAttribution('channel', 'youtube');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.text('设置完成'), findsOneWidget);
      expect(find.text('欢迎使用 YouTube'), findsOneWidget);
      expect(find.text('稍后'), findsNothing);
      // Not closed before signing in.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('欢迎使用 YouTube'), findsOneWidget);

      var closed = false;
      unawaited(shown.closed.then((_) => closed = true));
      await signIn(tester);
      expect(windows.single.opened, Uri.parse('https://panel.example/login'));
      expect(windows.single.title, 'YouTube');
      expect(closed, isTrue);
      expect(started, isTrue);
      expect(shown.gate.ready, isTrue);
    });

    testWidgets('a window closed before signing in leaves it as it was', (
      tester,
    ) async {
      store
        ..state = ChannelSetup.doneState
        ..attribution = const ChannelAttribution('channel', 'youtube');
      final shown = await open(tester, null, channels: _withWelcome);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.text('YouTube 的朋友，欢迎'), findsOneWidget);
      expect(find.text('登录后领取额度。'), findsOneWidget);
      // No setup this run: not said to be done just now.
      expect(find.text('设置完成'), findsNothing);
      await tester.tap(find.text('登录'));
      await tester.pump();
      windows.single.dismiss();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('登录'), findsOneWidget);
      expect(shown.gate.ready, isFalse);
    });

    testWidgets('stays, saying so, for a channel it cannot be used with', (
      tester,
    ) async {
      final troubles = <String>[];
      final setup = setupOf(poll: const Duration(hours: 1));
      addTearDown(setup.dispose);
      await open(tester, setup, troubles: troubles);
      await tester.tap(find.text('浏览器没反应？'));
      await tester.pump();
      await tester.enterText(
        find.byType(EditableText),
        'caocode://activate?i=$_id&s=direct',
      );
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('这个渠道暂时用不了'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('这个渠道暂时用不了'), findsOneWidget);
      await tester.tap(find.text('遇到问题？'));
      expect(troubles, ['trouble']);
    });

    testWidgets('asks the browser once more for a channel it cannot be used '
        'with: one come by since, which has accounts, welcomed', (
      tester,
    ) async {
      store
        ..state = ChannelSetup.doneState
        ..attribution = const ChannelAttribution('channel', 'youtube');
      final asking = <ChannelSetup>[];
      final shown = await open(
        tester,
        null,
        channels: {
          'youtube': {
            'name': {'zh': 'YouTube', 'en': 'YouTube'},
          },
          'aijws': {
            'name': {'zh': '贾维斯', 'en': 'JARVIS'},
            'account': {'type': 'newapi', 'url': 'https://panel.example'},
          },
        },
        again: () {
          final setup = setupOf(
            poll: const Duration(seconds: 3),
            again: _again,
          );
          asking.add(setup);
          return setup;
        },
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('这个渠道暂时用不了'), findsOneWidget);
      await tester.tap(find.text('去浏览器确认'));
      await tester.pump();
      expect(opened, [
        Uri.parse('https://caocode.dev/zh/activate#i=$_id&again=$_again'),
      ]);
      expect(shown.gate.stage, ChannelStage.setup);
      expect(find.text('正在等待浏览器完成…'), findsOneWidget);

      server.kept = const ChannelAttribution('channel', 'aijws');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1600));
      expect(store.attribution, const ChannelAttribution('channel', 'aijws'));
      expect(find.text('欢迎使用 贾维斯'), findsOneWidget);
      expect(shown.gate.stage, ChannelStage.signIn);
      asking.single.dispose();
    });

    testWidgets('takes the page’s link pasted, after saying what is wrong '
        'with another', (tester) async {
      final setup = setupOf(poll: const Duration(hours: 1));
      addTearDown(setup.dispose);
      await open(tester, setup);
      expect(find.byType(EditableText), findsNothing);
      await tester.tap(find.text('浏览器没反应？'));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'caocode://nope');
      await tester.tap(find.text('确定'));
      await tester.pump();
      expect(find.textContaining('这不是网页上的链接'), findsOneWidget);

      await tester.enterText(
        find.byType(EditableText),
        'caocode://activate?i=$_id&s=channel&c=youtube',
      );
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1600));
      expect(find.text('欢迎使用 YouTube'), findsOneWidget);
    });

    testWidgets('says it needs the network, Retry opening the page again', (
      tester,
    ) async {
      server.offline = true;
      final troubles = <String>[];
      final setup = setupOf(poll: const Duration(seconds: 3));
      await open(tester, setup, troubles: troubles);
      await tester.tap(find.text('在浏览器中完成设置').last);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.textContaining('需要联网才能完成设置'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(opened, hasLength(2));

      await tester.tap(find.text('遇到问题？'));
      expect(troubles, ['trouble']);
      // Its questions stop with it, before the test's end checks the timers.
      setup.dispose();
    });
  });
}

const lookUpBase = ChannelSetup.lookUpBase;
