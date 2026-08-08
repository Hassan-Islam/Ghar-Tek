import 'package:flutter/material.dart';

/// A compact, reusable delivery speed selector card.
/// Used in both checkout and custom order form.
class DeliverySpeedCard extends StatelessWidget {
  final String title;
  final String subtitle; // e.g. "40-60 min"
  final String price;    // e.g. "Rs. 150"
  final bool isSelected;
  final VoidCallback onTap;
  final IconData icon;

  const DeliverySpeedCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.price,
    required this.isSelected,
    required this.onTap,
    required this.icon,
  });

  static const Color _primary = Color(0xFFFF6B00);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFF3E8) : Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? _primary : Colors.grey[200]!,
            width: isSelected ? 2.0 : 1.0,
          ),
          boxShadow: isSelected
              ? [BoxShadow(color: _primary.withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, 3))]
              : null,
        ),
        child: Row(
          children: [
            // Icon
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: isSelected ? _primary.withValues(alpha: 0.14) : Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: isSelected ? _primary : Colors.grey[500], size: 16),
            ),
            const SizedBox(width: 8),
            // Labels
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      color: isSelected ? _primary : const Color(0xFF1A1A1A),
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                  ),
                ],
              ),
            ),
            // Price + radio
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  price,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                    color: isSelected ? _primary : Colors.grey[700],
                  ),
                ),
                const SizedBox(height: 3),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isSelected ? _primary : Colors.transparent,
                    border: Border.all(
                      color: isSelected ? _primary : Colors.grey[350]!,
                      width: 1.5,
                    ),
                  ),
                  child: isSelected
                      ? const Icon(Icons.check, color: Colors.white, size: 10)
                      : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
