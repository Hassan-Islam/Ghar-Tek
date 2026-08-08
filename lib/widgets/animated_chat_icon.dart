import 'dart:math' as math;
import 'package:flutter/material.dart';

class AnimatedChatIcon extends StatefulWidget {
  final double size;

  const AnimatedChatIcon({super.key, this.size = 20});

  @override
  State<AnimatedChatIcon> createState() => _AnimatedChatIconState();
}

class _AnimatedChatIconState extends State<AnimatedChatIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        return CustomPaint(
          size: Size.square(widget.size),
          painter: _ChatIconPainter(progress: _controller.value),
        );
      },
    );
  }
}

class _ChatIconPainter extends CustomPainter {
  final double progress;

  const _ChatIconPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final base = size.shortestSide;
    final scale = base / 150.0;

    // Background ellipse with gradient
    final bgRect = Rect.fromCenter(
      center: Offset(base / 2, base / 2),
      width: 110 * scale,
      height: 110 * scale,
    );
    final gradient = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF8E2DED),
        Color(0xFFA357EE),
        Color(0xFFB981F0),
      ],
      stops: [0.0, 0.5, 1.0],
    );
    final bgPaint = Paint()..shader = gradient.createShader(bgRect);
    canvas.drawOval(bgRect, bgPaint);

    // Chat bubble
    final bubbleRect = Rect.fromLTWH(
      45 * scale,
      54 * scale,
      80 * scale,
      55 * scale,
    );
    final bubbleRRect = RRect.fromRectAndRadius(
      bubbleRect,
      Radius.circular(16 * scale),
    );
    final bubblePaint = Paint()..color = Colors.white;
    canvas.drawRRect(bubbleRRect, bubblePaint);

    final tail = Path()
      ..moveTo(58 * scale, 108 * scale)
      ..lineTo(48 * scale, 120 * scale)
      ..lineTo(72 * scale, 114 * scale)
      ..close();
    canvas.drawPath(tail, bubblePaint);

    // Animated dots
    final dotCenters = [
      Offset(70 * scale, 82 * scale),
      Offset(85 * scale, 82 * scale),
      Offset(100 * scale, 82 * scale),
    ];
    for (var i = 0; i < dotCenters.length; i++) {
      final phase = (progress * 2 * math.pi) + (i * 0.4);
      final opacity = 0.2 + 0.8 * ((math.sin(phase) + 1) / 2);
      final dotPaint = Paint()
        ..color = const Color(0xFF8E2DED).withOpacity(opacity);
      canvas.drawCircle(dotCenters[i], 5 * scale, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChatIconPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
