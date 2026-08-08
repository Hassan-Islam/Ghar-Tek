import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Animated header widget for Login & Signup pages.
/// Uses app theme colors: primary orange [0xFFFF6B00] and white.
class AuthAnimationHeader extends StatefulWidget {
  final double height;
  final String title;
  final String subtitle;
  final Widget? icon;

  const AuthAnimationHeader({
    super.key,
    this.height = 240,
    required this.title,
    required this.subtitle,
    this.icon,
  });

  @override
  State<AuthAnimationHeader> createState() => _AuthAnimationHeaderState();
}

class _AuthAnimationHeaderState extends State<AuthAnimationHeader>
    with TickerProviderStateMixin {
  late final AnimationController _sparkController;
  late final AnimationController _bgController;

  late final Animation<double> _sparkOpacity;
  late final Animation<double> _bgWave;

  @override
  void initState() {
    super.initState();

    // Spark/star twinkle
    _sparkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _sparkOpacity = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _sparkController, curve: Curves.easeInOut),
    );

    // Background wave pulse
    _bgController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat(reverse: true);

    _bgWave = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _bgController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _sparkController.dispose();
    _bgController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: widget.height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF6B00), Color(0xFFFF9A3D)],
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(40),
          bottomRight: Radius.circular(40),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([
            _sparkController,
            _bgController,
          ]),
          // Lottie passed as child so it is NOT rebuilt on every animation tick
          child: Center(
            child: Lottie.asset(
              'assets/animations/login_animation.json',
              width: widget.height * 0.72,
              height: widget.height * 0.72,
              fit: BoxFit.contain,
              repeat: true,
            ),
          ),
          builder: (context, lottieChild) {
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                // Background decorative circles
                _buildBgCircle(right: -20, top: 10, size: 90, opacity: 0.12 + _bgWave.value * 0.08),
                _buildBgCircle(left: -15, bottom: 20, size: 70, opacity: 0.10 + _bgWave.value * 0.06),
                _buildBgCircle(right: 60, bottom: -10, size: 50, opacity: 0.08 + _bgWave.value * 0.05),

                // Sparkling stars
                _buildStar(left: 28, top: 34, size: 10, opacity: _sparkOpacity.value),
                _buildStar(right: 44, top: 28, size: 8, opacity: 1 - _sparkOpacity.value * 0.5),
                _buildStar(left: 60, bottom: 30, size: 6, opacity: _sparkOpacity.value * 0.8),
                _buildStar(right: 80, bottom: 50, size: 9, opacity: 1 - _sparkOpacity.value),

                // Lottie animation (stable child — not rebuilt each frame)
                lottieChild!,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildBgCircle({
    double? left,
    double? right,
    double? top,
    double? bottom,
    required double size,
    required double opacity,
  }) {
    return Positioned(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: opacity),
        ),
      ),
    );
  }

  Widget _buildStar({
    double? left,
    double? right,
    double? top,
    double? bottom,
    required double size,
    required double opacity,
  }) {
    return Positioned(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Icon(
          Icons.star_rounded,
          color: Colors.yellow[200],
          size: size,
        ),
      ),
    );
  }
}
