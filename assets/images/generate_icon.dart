import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'dart:io';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await generateIcons();
}

Future<void> generateIcons() async {
  // Create app icon (main icon with background)
  await createIcon(
    size: 1024,
    backgroundColor: const Color(0xFF2196F3),
    iconColor: Colors.white,
    filename: 'app_icon.png',
  );
  
  // Create foreground icon (for adaptive icons)
  await createIcon(
    size: 1024,
    backgroundColor: Colors.transparent,
    iconColor: const Color(0xFF2196F3),
    filename: 'app_icon_foreground.png',
  );
  
  print('Icons generated successfully!');
}

Future<void> createIcon({
  required double size,
  required Color backgroundColor,
  required Color iconColor,
  required String filename,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  
  // Draw background
  if (backgroundColor != Colors.transparent) {
    final backgroundPaint = Paint()..color = backgroundColor;
    canvas.drawCircle(Offset(size / 2, size / 2), size / 2, backgroundPaint);
  }
  
  // Draw shopping bag icon
  final iconPaint = Paint()
    ..color = iconColor
    ..style = PaintingStyle.fill;
  
  final iconSize = size * 0.6; // 60% of total size
  final iconOffset = (size - iconSize) / 2;
  
  // Shopping bag path (simplified)
  final path = Path();
  
  // Bag body
  final bagTop = iconOffset + iconSize * 0.3;
  final bagBottom = iconOffset + iconSize * 0.9;
  final bagLeft = iconOffset + iconSize * 0.2;
  final bagRight = iconOffset + iconSize * 0.8;
  
  path.moveTo(bagLeft, bagTop);
  path.lineTo(bagRight, bagTop);
  path.lineTo(bagRight * 0.95, bagBottom);
  path.lineTo(bagLeft * 1.05, bagBottom);
  path.close();
  
  canvas.drawPath(path, iconPaint);
  
  // Bag handles
  final handlePaint = Paint()
    ..color = iconColor
    ..style = PaintingStyle.stroke
    ..strokeWidth = size * 0.03;
  
  final handleTop = iconOffset + iconSize * 0.15;
  final handleLeftX = iconOffset + iconSize * 0.35;
  final handleRightX = iconOffset + iconSize * 0.65;
  
  // Left handle
  canvas.drawArc(
    Rect.fromLTWH(
      handleLeftX - iconSize * 0.1,
      handleTop,
      iconSize * 0.2,
      iconSize * 0.25,
    ),
    0,
    3.14159,
    false,
    handlePaint,
  );
  
  // Right handle
  canvas.drawArc(
    Rect.fromLTWH(
      handleRightX - iconSize * 0.1,
      handleTop,
      iconSize * 0.2,
      iconSize * 0.25,
    ),
    0,
    3.14159,
    false,
    handlePaint,
  );
  
  final picture = recorder.endRecording();
  final img = await picture.toImage(size.toInt(), size.toInt());
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  final pngBytes = byteData!.buffer.asUint8List();
  
  final file = File('assets/images/$filename');
  await file.writeAsBytes(pngBytes);
  print('Created: ${file.path}');
}
