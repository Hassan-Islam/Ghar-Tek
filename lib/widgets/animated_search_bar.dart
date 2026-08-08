import 'dart:async';
import 'package:flutter/material.dart';

class AnimatedSearchBar extends StatefulWidget {
  final VoidCallback onTap;
  
  const AnimatedSearchBar({super.key, required this.onTap});

  @override
  State<AnimatedSearchBar> createState() => _AnimatedSearchBarState();
}

class _AnimatedSearchBarState extends State<AnimatedSearchBar> {
  final List<String> _searchHints = [
    'Search For Biryani',
    'Search For Burger',
    'Search For FastFood',
    'Search For Pizza',
    'Search For Chinese',
    'Search For Sweets',
    'Search For Restaurants',
    'Search For Groceries',
  ];
  int _currentIndex = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (mounted) {
        setState(() {
          _currentIndex = (_currentIndex + 1) % _searchHints.length;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.black12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, color: Color(0xFFFF6B00), size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                  return Stack(
                    alignment: Alignment.centerLeft,
                    children: <Widget>[
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  );
                },
                transitionBuilder: (Widget child, Animation<double> animation) {
                  final isIncoming = child.key == ValueKey<int>(_currentIndex);
                  if (!isIncoming) {
                    return const SizedBox.shrink();
                  }

                  final tween = Tween<Offset>(
                    begin: const Offset(0.0, 0.4),
                    end: Offset.zero,
                  );
                  final curvedAnimation = CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  );
                  return FadeTransition(
                    opacity: curvedAnimation,
                    child: SlideTransition(
                      position: tween.animate(curvedAnimation),
                      child: child,
                    ),
                  );
                },
                child: Align(
                  key: ValueKey<int>(_currentIndex),
                  alignment: Alignment.centerLeft,
                  child: RichText(
                    text: TextSpan(
                      text: 'Search For ',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        fontFamily: 'Inter',
                      ),
                      children: [
                        TextSpan(
                          text: _searchHints[_currentIndex].replaceFirst('Search For ', ''),
                          style: const TextStyle(
                            color: Color(0xFFFF6B00),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
