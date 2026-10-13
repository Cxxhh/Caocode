import 'package:caocode/icons/site_icon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a site\'s icon is looked for on it, then its domains\' above it', () {
    expect(siteIconPages(Uri.parse('https://api.agentrouter.org/v1')), [
      Uri.parse('https://api.agentrouter.org'),
      Uri.parse('https://agentrouter.org'),
    ]);
    expect(siteIconPages(Uri.parse('http://gw.example.com:8080/x')), [
      Uri.parse('http://gw.example.com:8080'),
      Uri.parse('https://example.com'),
    ]);
    expect(siteIconPages(Uri.parse('http://127.0.0.1:3000')), [
      Uri.parse('http://127.0.0.1:3000'),
    ]);
  });

  test('a page\'s icons are an SVG first, then the largest', () {
    const html = '''
<html><head>
<link rel="stylesheet" href="/app.css">
<link rel="shortcut icon" href="/favicon.ico">
<link rel='apple-touch-icon' href='touch.png'>
<link rel="icon" type="image/png" sizes="32x32" href="/icon-32.png?v=1&amp;x=2">
<link href="/logo.svg" rel="icon">
<link rel="mask-icon" href="/mask.svg" color="#000">
</head></html>''';
    expect(siteIconLinks(html, Uri.parse('https://example.com/app/')), [
      Uri.parse('https://example.com/logo.svg'),
      Uri.parse('https://example.com/app/touch.png'),
      Uri.parse('https://example.com/icon-32.png?v=1&x=2'),
      Uri.parse('https://example.com/favicon.ico'),
    ]);
  });
}
