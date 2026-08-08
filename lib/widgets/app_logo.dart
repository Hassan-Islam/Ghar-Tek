import 'dart:math' as math;
import 'package:flutter/material.dart';

/// GharTek orange shopping bag logo widget.
class AppLogoBag extends StatelessWidget {
  final double size;
  const AppLogoBag({super.key, this.size = 80});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _BagPainter()),
    );
  }
}

class _BagPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width;
    final paint = Paint()
      ..color = const Color(0xFFFF6B00)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // 1. Handle drawn FIRST so bag body covers its bottom tabs
    final handlePaint = Paint()
      ..color = const Color(0xFFFF6B00)
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.115
      ..strokeCap = StrokeCap.butt
      ..isAntiAlias = true;

    final handleRect = Rect.fromCenter(
      center: Offset(s * 0.5, s * 0.265),
      width: s * 0.38,
      height: s * 0.30,
    );
    // Arc: left → TOP → right (dome / loop handle)
    canvas.drawArc(handleRect, math.pi, math.pi, false, handlePaint);

    // 2. Bag body (rounded rectangle, covers bottom of handle)
    final bodyRRect = RRect.fromLTRBR(
      s * 0.08, s * 0.265,
      s * 0.92, s * 0.93,
      Radius.circular(s * 0.13),
    );
    canvas.drawRRect(bodyRRect, paint);

    // 3. White U / smile inside the bag
    final whitePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.09
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final smileRect = Rect.fromCenter(
      center: Offset(s * 0.5, s * 0.585),
      width: s * 0.44,
      height: s * 0.28,
    );
    // Arc: right → BOTTOM → left (U shape opening upward)
    canvas.drawArc(smileRect, 0, math.pi, false, whitePaint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
