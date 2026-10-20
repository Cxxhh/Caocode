import 'package:caocode/chat/review/unpatch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('takes a change back out', () {
    expect(
      unpatch('a\nB\nc\n', '@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n'),
      'a\nb\nc\n',
    );
  });

  test('lines added and removed with no context', () {
    // Added after line 1.
    expect(unpatch('a\nnew\nb\n', '@@ -1,0 +2 @@\n+new\n'), 'a\nb\n');
    // Removed after what is line 1 now.
    expect(unpatch('a\nc\n', '@@ -2 +1,0 @@\n-b\n'), 'a\nb\nc\n');
    // All of it, from nothing.
    expect(unpatch('x\ny\n', '@@ -0,0 +1,2 @@\n+x\n+y\n'), '');
  });

  test('finds a hunk moved by lines changed since', () {
    expect(
      unpatch('top\na\nB\n', '@@ -1,2 +1,2 @@\n a\n-b\n+B\n'),
      'top\na\nb\n',
    );
  });

  test('the newline at the end, as the diff tells', () {
    expect(
      unpatch(
        'a\nb\n',
        '@@ -1,2 +1,2 @@\n a\n-c\n\\ No newline at end of file\n+b\n',
      ),
      'a\nc',
    );
    expect(
      unpatch(
        'a\nb',
        '@@ -1,2 +1,2 @@\n a\n-c\n+b\n\\ No newline at end of file\n',
      ),
      'a\nc\n',
    );
  });

  test('none where it does not fit', () {
    expect(unpatch('a\nz\n', '@@ -1,2 +1,2 @@\n a\n-b\n+c\n'), isNull);
    expect(unpatch('a\n', 'not a diff'), isNull);
  });
}
