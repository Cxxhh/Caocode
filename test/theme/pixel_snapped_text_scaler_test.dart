import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:caocode/theme/pixel_snapped_text_scaler.dart';

void main() {
  test('rounds each size to a whole device pixel', () {
    const scaler = PixelSnappedTextScaler(TextScaler.noScaling, 1.25);
    // 13 * 1.25 = 16.25 px rounds to 16 px.
    expect(scaler.scale(13), 16 / 1.25);
    // 14 * 1.25 = 17.5 px rounds to 18 px.
    expect(scaler.scale(14), 18 / 1.25);
    expect(scaler.scale(12) * 1.25, 15);
  });

  test('snaps after the base scale', () {
    const scaler = PixelSnappedTextScaler(TextScaler.linear(1.1), 1.5);
    // 13 * 1.1 * 1.5 = 21.45 px rounds to 21 px.
    expect(scaler.scale(13) * 1.5, closeTo(21, 1e-9));
  });

  test('leaves sizes alone without a pixel ratio', () {
    const scaler = PixelSnappedTextScaler(TextScaler.linear(1.1), 0);
    expect(scaler.scale(13), closeTo(14.3, 1e-9));
  });

  test('equal for the same base and ratio', () {
    expect(
      const PixelSnappedTextScaler(TextScaler.linear(1.2), 2),
      PixelSnappedTextScaler(const TextScaler.linear(1.2), 2),
    );
    expect(
      const PixelSnappedTextScaler(TextScaler.linear(1.2), 2) ==
          const PixelSnappedTextScaler(TextScaler.linear(1.2), 1.5),
      isFalse,
    );
  });
}
