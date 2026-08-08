import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// OrderStatusWidget
/// - Shows a Preparing view (chef Lottie + animated warm text)
/// - Shows an OnTheWay view (rider Lottie + ETA, progress, Track Rider button)
/// Usage: OrderStatusWidget(orderStatus: 'preparing'|'on_the_way', ...)

class OrderStatusWidget extends StatelessWidget {
  final String orderStatus;
  final int? etaMinutes; // optional ETA to show in OnTheWay
  final double? progress; // 0.0 - 1.0 progress for rider
  final VoidCallback? onTrackPressed;

  const OrderStatusWidget({
    super.key,
    required this.orderStatus,
    this.etaMinutes,
    this.progress,
    this.onTrackPressed,
  });

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (orderStatus == 'preparing') {
      child = PreparingView();
    } else if (orderStatus == 'on_the_way') {
      child = OnTheWayView(
        etaMinutes: etaMinutes ?? 0,
        progress: progress ?? 0.0,
        onTrackPressed: onTrackPressed,
      );
    } else {
      child = const SizedBox.shrink();
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 600),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut.flipped,
      child: child,
    );
  }
}

class PreparingView extends StatefulWidget {
  const PreparingView({super.key});

  @override
  State<PreparingView> createState() => _PreparingViewState();
}

class _PreparingViewState extends State<PreparingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _textAnimCtrl;
  static const List<String> _steps = ['Chopping', 'Cooking', 'Packaging'];

  @override
  void initState() {
    super.initState();
    _textAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _textAnimCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final softShadow = Colors.orange.withOpacity(0.18);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 6,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFFFFF4E6),
              const Color(0xFFFFE2C7),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Lottie chef animation
              SizedBox(
                height: 200,
                child: Center(
                  child: Lottie.asset(
                    'assets/cooking.json',
                    height: 200,
                    repeat: true,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              AnimatedBuilder(
                animation: _textAnimCtrl,
                builder: (context, child) {
                  final t = _textAnimCtrl.value;
                  final eased = Curves.easeInOut.transform(t);
                  // interpolate between warm colors
                  final color = Color.lerp(
                    const Color(0xFFB45309),
                    const Color(0xFFFF8A2B),
                    eased,
                  );
                  final scale = 1.0 + (math.sin(t * math.pi * 2) * 0.02);
                  return Transform.scale(
                    scale: scale,
                    child: Text(
                      'Our Master Chef is crafting your delicious meal...',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        color: color,
                        shadows: [
                          Shadow(
                            color: softShadow,
                            blurRadius: 10,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              AnimatedBuilder(
                animation: _textAnimCtrl,
                builder: (context, child) {
                  final active = ((_textAnimCtrl.value * _steps.length)
                          .floor()) %
                      _steps.length;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(_steps.length, (index) {
                      final isActive = index == active;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 350),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: isActive
                              ? const Color(0xFFFF8A2B)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(999),
                          boxShadow: isActive
                              ? [
                                  BoxShadow(
                                    color: softShadow,
                                    blurRadius: 12,
                                    offset: const Offset(0, 4),
                                  ),
                                ]
                              : null,
                        ),
                        child: Text(
                          _steps[index],
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: isActive
                                ? Colors.white
                                : const Color(0xFF9A4C0C),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      );
                    }),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OnTheWayView extends StatefulWidget {
  final int etaMinutes;
  final double progress;
  final VoidCallback? onTrackPressed;

  const OnTheWayView({
    super.key,
    required this.etaMinutes,
    required this.progress,
    this.onTrackPressed,
  });

  @override
  State<OnTheWayView> createState() => _OnTheWayViewState();
}

class _OnTheWayViewState extends State<OnTheWayView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progressAnimCtrl;
  late final AnimationController _motionCtrl;

  @override
  void initState() {
    super.initState();
    _progressAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    _progressAnimCtrl.value = widget.progress.clamp(0.0, 1.0);
    _motionCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void didUpdateWidget(covariant OnTheWayView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _progressAnimCtrl.animateTo(widget.progress.clamp(0.0, 1.0),
        duration: const Duration(milliseconds: 800), curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _progressAnimCtrl.dispose();
    _motionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final etaText = 'ETA: ${widget.etaMinutes} min';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 6,
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFFE8FBFF),
              const Color(0xFFCFF2F8),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Rider Lottie moving along a track
              SizedBox(
                height: 140,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final riderWidth = 96.0;
                    final travel = (constraints.maxWidth - riderWidth)
                        .clamp(0.0, double.infinity);
                    return AnimatedBuilder(
                      animation: Listenable.merge([
                        _progressAnimCtrl,
                        _motionCtrl,
                      ]),
                      builder: (context, child) {
                        final base = _progressAnimCtrl.value * travel;
                        final wiggle =
                            math.sin(_motionCtrl.value * math.pi * 2) * 6.0;
                        final riderX = (base + wiggle).clamp(0.0, travel);
                        return Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            Positioned(
                              left: 0,
                              right: 0,
                              top: 70,
                              child: Container(
                                height: 10,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(999),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.08),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              left: 0,
                              top: 70,
                              child: Container(
                                height: 10,
                                width: base.clamp(0.0, travel) + 8,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF06B6D4),
                                      Color(0xFF0EA5E9),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                            Positioned(
                              left: riderX,
                              child: SizedBox(
                                width: riderWidth,
                                height: 120,
                                child: Lottie.asset(
                                  'assets/rider.json',
                                  repeat: true,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      etaText,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: widget.onTrackPressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF06B6D4),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Track Rider'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Animated linear progress
              AnimatedBuilder(
                animation: _progressAnimCtrl,
                builder: (context, child) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: _progressAnimCtrl.value,
                      minHeight: 8,
                      backgroundColor: Colors.white,
                      valueColor:
                          AlwaysStoppedAnimation(const Color(0xFF06B6D4)),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
