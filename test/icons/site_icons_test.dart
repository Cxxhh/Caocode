import 'dart:async';
import 'dart:typed_data';

import 'package:caocode/icons/icon_library.dart';
import 'package:caocode/icons/site_icons.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1×1 GIF: kept as given, never decoded.
final _gif = Uint8List.fromList([
  ...'GIF89a'.codeUnits, 1, 0, 1, 0, 0, 0, 0, 0x3b, //
]);

void main() {
  test('a site\'s icon is fetched once, the first time it is asked for, '
      'and kept by its host', () async {
    final fetched = <Uri>[];
    final answer = Completer<void>();
    final library = IconLibrary();
    final icons = SiteIcons(
      library: library,
      fetch: (site, take) async {
        fetched.add(site);
        await answer.future;
        return take(_gif);
      },
    );
    var told = 0;
    icons.addListener(() => told++);
    final site = Uri.parse('https://api.agentrouter.org/v1');

    expect(icons.of(site), isNull);
    expect(icons.of(site), isNull);
    await pumpEventQueue();
    expect(fetched, [site]);

    answer.complete();
    await pumpEventQueue();
    expect(told, 1);
    expect(icons.of(site)!.name, 'api.agentrouter.org');

    // Kept from before: found, not fetched again.
    final again = SiteIcons(
      library: library,
      fetch: (site, take) async => fail('fetched again'),
    );
    again.request(site);
    await pumpEventQueue();
    expect(again.of(site), isNotNull);
  });

  test('a site with no icon is asked about once', () async {
    var fetched = 0;
    final icons = SiteIcons(
      fetch: (site, take) async {
        fetched++;
        return null;
      },
    );
    final site = Uri.parse('https://anyrouter.top');
    icons.request(site);
    await pumpEventQueue();
    expect(icons.of(site), isNull);
    await pumpEventQueue();
    expect(fetched, 1);
  });
}
