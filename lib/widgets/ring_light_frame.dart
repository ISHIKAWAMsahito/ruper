import 'package:flutter/material.dart';

/// インカメラ用のスクリーン・リングライト。画面外周を白色で発光させる。
class RingLightFrame extends StatelessWidget {
  const RingLightFrame({
    super.key,
    this.thickness = 44,
    this.color = Colors.white,
  });

  final double thickness;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _RingPainter(thickness: thickness, color: color),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.thickness, required this.color});

  final double thickness;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Offset.zero & size;
    final inner = RRect.fromRectAndRadius(
      outer.deflate(thickness),
      const Radius.circular(28),
    );
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(outer)
      ..addRRect(inner);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.thickness != thickness || old.color != color;
}
