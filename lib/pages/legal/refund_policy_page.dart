import 'package:flutter/material.dart';

class RefundPolicyPage extends StatelessWidget {
  const RefundPolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 220.0,
            floating: false,
            pinned: true,
            elevation: 0,
            backgroundColor: const Color(0xFFFF6B00),
            foregroundColor: Colors.white,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 24, bottom: 20, right: 24),
              title: const Text(
                'Refund Policy',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 22, letterSpacing: -0.5, shadows: [Shadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2))],
                  color: Colors.white,
                ),
              ),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFFFF8B3D), Color(0xFFFF6B00)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                  Positioned(
                    right: -50,
                    top: -50,
                    child: Icon(
                      Icons.currency_exchange_rounded,
                      size: 220,
                      color: Colors.white.withOpacity(0.1),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Last updated: ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 24),
                  
                  _buildSection(
                    '1. Refund Eligibility',
                    'Refunds may be issued in the following circumstances:\n\n• Order was cancelled by the merchant\n• Order was not delivered within the promised timeframe\n• Items received were damaged or incorrect\n• Quality issues with food items\n• Technical errors in payment processing',
                    Icons.check_circle_outline_rounded,
                  ),
                  _buildSection(
                    '2. Food Orders',
                    'For food delivery orders:\n\n• Refunds available if food is significantly delayed (over 60 minutes past estimated time)\n• Quality issues must be reported within 30 minutes of delivery\n• Partial refunds may be issued for missing items\n• No refunds for change of mind after order confirmation',
                    Icons.restaurant_menu_rounded,
                  ),
                  _buildSection(
                    '3. Grocery & Medicine Orders',
                    'For grocery and medicine deliveries:\n\n• Refunds available for damaged or expired products\n• Wrong items delivered will be replaced or refunded\n• Temperature-sensitive items must be reported immediately\n• Prescription medicines cannot be returned once delivered',
                    Icons.local_grocery_store_outlined,
                  ),
                  _buildSection(
                    '4. Electronics & General Items',
                    'For electronics and other items:\n\n• Refunds available within 24 hours for damaged items\n• Items must be in original packaging for return\n• Electronics warranty issues handled by manufacturer\n• Custom or personalized items are non-refundable',
                    Icons.devices_other_rounded,
                  ),
                  _buildSection(
                    '5. Refund Process',
                    'To request a refund:\n\n1. Contact customer support immediately\n2. Provide order details and reason for refund\n3. Submit photos if items are damaged\n4. Our team will review your request within 24 hours\n5. Approved refunds processed within 3-7 business days',
                    Icons.support_agent_rounded,
                  ),
                  _buildSection(
                    '6. Refund Methods',
                    'Refunds will be processed to:\n\n• Original payment method (credit/debit card)\n• Bank account (for cash on delivery orders)\n• Digital wallet (if originally paid through wallet)\n• Store credit (in some cases)',
                    Icons.account_balance_wallet_outlined,
                  ),
                  _buildSection(
                    '7. Non-Refundable Items',
                    'The following items are not eligible for refunds:\n\n• Perishable food items (unless quality issues)\n• Personal care products that have been opened\n• Digital products or services\n• Gift cards and vouchers\n• Items damaged due to misuse',
                    Icons.do_not_disturb_alt_rounded,
                  ),
                  _buildSection(
                    '8. Delivery Fee Refunds',
                    'Delivery fees may be refunded if:\n\n• Order was cancelled by merchant\n• Significant delivery delays\n• Failed delivery attempts (merchant\'s fault)\n• Technical errors in the system',
                    Icons.local_shipping_outlined,
                  ),
                  _buildSection(
                    '9. Cancellation Policy',
                    'Order cancellations:\n\n• Free cancellation within 2 minutes of placing order\n• After preparation starts, cancellation fees may apply\n• Full refund if merchant cancels the order\n• No refund for orders already out for delivery',
                    Icons.cancel_outlined,
                  ),
                  _buildSection(
                    '10. Dispute Resolution',
                    'If you\'re not satisfied with our refund decision:\n\n• Escalate to our senior support team\n• Provide additional evidence if available\n• Final decisions made within 7 business days\n• External dispute resolution available if needed',
                    Icons.gavel_rounded,
                  ),
                  _buildSection(
                    '11. Contact for Refunds',
                    'For refund requests and queries:\n\n📞 Customer Support: 03131426498\n📧 Email: ghartekinfo@gmail.com\n\nOur support team is available to assist you with refund requests and will work to resolve any issues promptly.',
                    Icons.contact_support_outlined,
                  ),
                  
                  const SizedBox(height: 16),
                  
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.orange[50],
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFFF6B00).withOpacity(0.3)),
                    ),
                    child: Column(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          color: Color(0xFFFF6B00),
                          size: 32,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Need Help?',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFFF6B00),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Our customer support team is here to help resolve any issues with your orders. Don\'t hesitate to reach out!',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.orange[900],
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 32),
                  Center(
                    child: Text(
                      '© ${DateTime.now().year} GharTek. All rights reserved.',
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, String content, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(bottom: 24.0),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF6B00).withOpacity(0.06),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.shade50, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFFFF6B00).withOpacity(0.15),
                      const Color(0xFFFF8B3D).withOpacity(0.05),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFFF6B00).withOpacity(0.1)),
                ),
                child: Icon(icon, color: const Color(0xFFFF6B00), size: 22),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF1A1A1A),
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            content,
            style: TextStyle(
              fontSize: 15,
              height: 1.7,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}


