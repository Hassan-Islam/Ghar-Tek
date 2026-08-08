import 'package:flutter/material.dart';

class TermsConditionsPage extends StatelessWidget {
  const TermsConditionsPage({super.key});

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
                'Terms & Conditions',
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
                      Icons.description_rounded,
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
                    '1. Acceptance of Terms',
                    'By downloading, installing, or using the GharTek mobile application, you agree to be bound by these Terms and Conditions. If you do not agree to these terms, please do not use our service.',
                    Icons.verified_user_outlined,
                  ),
                  _buildSection(
                    '2. Description of Service',
                    'GharTek is a delivery service platform that connects customers with local businesses and delivery partners. We facilitate the ordering and delivery of various items including food, groceries, medicines, electronics, and other products.',
                    Icons.info_outline_rounded,
                  ),
                  _buildSection(
                    '3. User Account',
                    'To use our service, you must create an account with accurate information. You are responsible for maintaining the confidentiality of your account credentials and for all activities that occur under your account.',
                    Icons.person_outline_rounded,
                  ),
                  _buildSection(
                    '4. Order Processing',
                    'Orders placed through GharTek are subject to acceptance by the merchant. We reserve the right to refuse or cancel any order at our discretion. Payment is processed securely through our platform.',
                    Icons.shopping_bag_outlined,
                  ),
                  _buildSection(
                    '5. Delivery Terms',
                    'Delivery times are estimates and may vary based on location, weather, traffic, and merchant preparation time. We strive to deliver orders as quickly as possible while ensuring quality and safety.',
                    Icons.local_shipping_outlined,
                  ),
                  _buildSection(
                    '6. User Responsibilities',
                    '• Provide accurate delivery information\n• Be available to receive deliveries\n• Treat delivery partners with respect\n• Report any issues promptly\n• Use the service in compliance with applicable laws',
                    Icons.assignment_ind_outlined,
                  ),
                  _buildSection(
                    '7. Prohibited Activities',
                    'Users may not:\n• Use the service for illegal activities\n• Harass or abuse delivery partners\n• Attempt to defraud the system\n• Share account credentials\n• Interfere with the platform\'s operation',
                    Icons.block_rounded,
                  ),
                  _buildSection(
                    '8. Limitation of Liability',
                    'GharTek\'s liability is limited to the amount paid for the specific order in question. We are not liable for indirect, incidental, or consequential damages.',
                    Icons.warning_amber_rounded,
                  ),
                  _buildSection(
                    '9. Privacy',
                    'Your privacy is important to us. Please review our Privacy Policy to understand how we collect, use, and protect your information.',
                    Icons.privacy_tip_outlined,
                  ),
                  _buildSection(
                    '10. Changes to Terms',
                    'We reserve the right to modify these terms at any time. Users will be notified of significant changes through the app or email.',
                    Icons.update_rounded,
                  ),
                  _buildSection(
                    '11. Contact Information',
                    'For questions about these Terms & Conditions, please contact us:\n\nPhone: 03131426498\nEmail: ghartekinfo@gmail.com',
                    Icons.contact_support_outlined,
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


