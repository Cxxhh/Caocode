import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';

/// [data] as a QR code: black on white, whatever the theme (scanners read
/// that best), with the quiet margin around it the standard asks for.
class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 220});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'QR code',
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _QrPainter(data)),
    ),
  );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data)
    : image = QrImage(
        QrCode(
          payload: QrPayload.fromString(data),
          errorCorrectLevel: QrErrorCorrectLevel.medium,
        ),
      );

  final String data;
  final QrImage image;

  /// Modules of white around it.
  static const _quiet = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final count = image.moduleCount;
    final module = size.width / (count + _quiet * 2);
    final dark = Paint()
      ..color = const Color(0xFF000000)
      ..isAntiAlias = false;
    final path = Path();
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (!image.isDark(row, col)) continue;
        path.addRect(
          Rect.fromLTWH(
            (col + _quiet) * module,
            (row + _quiet) * module,
            // A hair over, so no seams show between modules.
            module + 0.5,
            module + 0.5,
          ),
        );
      }
    }
    canvas.drawPath(path, dark);
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data;
}
