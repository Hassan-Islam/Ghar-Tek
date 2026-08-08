import 'package:flutter/material.dart';
import 'dart:ui' as ui;

class IconGenerator {
  static Future<void> generateShoppingBagIcon() async {
    // Generate main app icon with background
    await _generateIcon(
      size: 1024,
      hasBackground: true,
      filename: 'app_icon',
    );

    // Generate foreground icon for adaptive
    await _generateIcon(
      size: 1024,
      hasBackground: false,
      filename: 'app_icon_foreground',
    );
  }

  static Future<void> _generateIcon({
    required int size,
    required bool hasBackground,
    required String filename,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint();

    // Draw background if needed
    if (hasBackground) {
      paint.color = const Color(0xFF2196F3); // Blue background
      canvas.drawCircle(
        Offset(size / 2, size / 2),
        size / 2,
        paint,
      );
    }

    // Draw shopping bag
    final bagPaint = Paint()
      ..color = hasBackground ? Colors.white : const Color(0xFF2196F3)
      ..style = PaintingStyle.fill;

    final bagSize = size * 0.6;
    final center = size / 2;
    final bagLeft = center - bagSize / 2;
    final bagTop = center - bagSize / 2;

    // Bag body (trapezoid shape)
    final bagPath = Path();
    final bagBodyTop = bagTop + bagSize * 0.3;
    final bagBodyBottom = bagTop + bagSize * 0.85;
    final bagBodyLeftTop = bagLeft + bagSize * 0.25;
    final bagBodyRightTop = bagLeft + bagSize * 0.75;
    final bagBodyLeftBottom = bagLeft + bagSize * 0.15;
    final bagBodyRightBottom = bagLeft + bagSize * 0.85;

    bagPath.moveTo(bagBodyLeftTop, bagBodyTop);
    bagPath.lineTo(bagBodyRightTop, bagBodyTop);
    bagPath.lineTo(bagBodyRightBottom, bagBodyBottom);
    bagPath.lineTo(bagBodyLeftBottom, bagBodyBottom);
    bagPath.close();

    canvas.drawPath(bagPath, bagPaint);

    // Bag handles
    final handlePaint = Paint()
      ..color = hasBackground ? Colors.white : const Color(0xFF2196F3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.02
      ..strokeCap = StrokeCap.round;

    // Left handle
    final leftHandlePath = Path();
    final leftHandleCenter = bagLeft + bagSize * 0.35;
    final handleTop = bagTop + bagSize * 0.15;
    final handleHeight = bagSize * 0.2;
    final handleWidth = bagSize * 0.15;

    leftHandlePath.addArc(
      Rect.fromCenter(
        center: Offset(leftHandleCenter, handleTop + handleHeight / 2),
        width: handleWidth,
        height: handleHeight,
      ),
      0,
      3.14159, // π radians = 180 degrees
    );

    canvas.drawPath(leftHandlePath, handlePaint);

    // Right handle
    final rightHandlePath = Path();
    final rightHandleCenter = bagLeft + bagSize * 0.65;

    rightHandlePath.addArc(
      Rect.fromCenter(
        center: Offset(rightHandleCenter, handleTop + handleHeight / 2),
        width: handleWidth,
        height: handleHeight,
      ),
      0,
      3.14159, // π radians = 180 degrees
    );

    canvas.drawPath(rightHandlePath, handlePaint);

    // Convert to image
    final picture = recorder.endRecording();
    final img = await picture.toImage(size, size);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    
    if (byteData != null) {
      final pngBytes = byteData.buffer.asUint8List();
      // In a real app, you would save this to file
      // For now, just print that it was generated
      print('Generated $filename.png (${pngBytes.length} bytes)');
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await IconGenerator.generateShoppingBagIcon();
  print('Shopping bag icons generated successfully!');
}
