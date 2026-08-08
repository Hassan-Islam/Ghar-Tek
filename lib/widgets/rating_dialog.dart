import 'package:flutter/material.dart';
import '../services/rating_service.dart';

class RatingDialog extends StatefulWidget {
  final String orderId;
  final String userId;
  final String shopId;
  final VoidCallback onSubmitted;

  const RatingDialog({
    super.key,
    required this.orderId,
    required this.userId,
    required this.shopId,
    required this.onSubmitted,
  });

  @override
  State<RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<RatingDialog> {
  int foodRating = 0;
  int packagingRating = 0;
  int riderRating = 0;
  final TextEditingController _reviewController = TextEditingController();
  bool isSubmitting = false;

  Widget _buildStarRow(String title, int currentRating, Function(int) onRatingChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        const SizedBox(height: 4),
        Row(
          children: List.generate(5, (index) {
            return IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: Icon(
                index < currentRating ? Icons.star_rounded : Icons.star_outline_rounded,
                color: const Color(0xFFFF6B00),
                size: 28,
              ),
              onPressed: () => onRatingChanged(index + 1),
            );
          }),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Future<void> _submitReview() async {
    if (foodRating == 0 || packagingRating == 0 || riderRating == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please rate all categories to continue.')),
      );
      return;
    }

    setState(() => isSubmitting = true);
    
    try {
      await RatingService().submitOrderRating(
        orderId: widget.orderId,
        shopId: widget.shopId,
        foodRating: foodRating,
        packagingRating: packagingRating,
        riderRating: riderRating,
        comment: _reviewController.text.trim(),
      );

      widget.onSubmitted();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to submit review: $e')),
      );
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Rate Your Order',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1A1A1A),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'How was your experience?',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 20),
              
              _buildStarRow('Food Quality', foodRating, (r) => setState(() => foodRating = r)),
              _buildStarRow('Packaging', packagingRating, (r) => setState(() => packagingRating = r)),
              _buildStarRow('Rider', riderRating, (r) => setState(() => riderRating = r)),
              
              TextField(
                controller: _reviewController,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Any comments? (Optional)',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: isSubmitting ? null : _submitReview,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B00),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: isSubmitting
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text(
                          'Submit Review',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () {
                    // Ignore rating by marking it rated anyway, or just close
                    widget.onSubmitted();
                  },
                  child: const Text('Maybe Later', style: TextStyle(color: Colors.grey)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
