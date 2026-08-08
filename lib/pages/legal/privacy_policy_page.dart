import 'package:flutter/material.dart';

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

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
                'Privacy Policy',
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
                      Icons.security_rounded,
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
                    '1. Information We Collect',
                    'We collect information you provide directly to us, such as:\n\n• Account information (name, email, phone number)\n• Delivery addresses\n• Payment information\n• Order history and preferences\n• Communications with customer support',
                    Icons.person_outline_rounded,
                  ),
                  _buildSection(
                    '2. How We Use Your Information',
                    'We use the information we collect to:\n\n• Process and deliver your orders\n• Communicate with you about your orders\n• Improve our services\n• Send promotional offers (with your consent)\n• Ensure platform security and prevent fraud',
                    Icons.insights_rounded,
                  ),
                  _buildSection(
                    '3. Information Sharing',
                    'We may share your information with:\n\n• Delivery partners (only necessary delivery information)\n• Merchants (order details only)\n• Payment processors (for transaction processing)\n• Service providers who assist our operations\n• Law enforcement when required by law',
                    Icons.share_outlined,
                  ),
                  _buildSection(
                    '4. Data Security',
                    'We implement appropriate security measures to protect your personal information against unauthorized access, alteration, disclosure, or destruction. However, no method of transmission over the internet is 100% secure.',
                    Icons.shield_outlined,
                  ),
                  _buildSection(
                    '5. Location Information',
                    'We collect location data to:\n\n• Provide accurate delivery services\n• Show nearby restaurants and shops\n• Calculate delivery fees and time estimates\n• Improve our service coverage',
                    Icons.location_on_outlined,
                  ),
                  _buildSection(
                    '6. Cookies and Tracking',
                    'We use cookies and similar tracking technologies to:\n\n• Remember your preferences\n• Analyze usage patterns\n• Personalize your experience\n• Improve our services',
                    Icons.cookie_outlined,
                  ),
                  _buildSection(
                    '7. Your Rights',
                    'You have the right to:\n\n• Access your personal information\n• Update or correct your information\n• Delete your account and associated data\n• Opt out of promotional communications\n• Request a copy of your data',
                    Icons.fact_check_outlined,
                  ),
                  _buildSection(
                    '8. Children\'s Privacy',
                    'Our service is not intended for children under 13 years of age. We do not knowingly collect personal information from children under 13.',
                    Icons.child_care_rounded,
                  ),
                  _buildSection(
                    '9. International Transfers',
                    'Your information may be transferred to and processed in countries other than your own. We ensure appropriate safeguards are in place for such transfers.',
                    Icons.public_rounded,
                  ),
                  _buildSection(
                    '10. Changes to This Policy',
                    'We may update this Privacy Policy from time to time. We will notify you of any material changes through the app or via email.',
                    Icons.update_rounded,
                  ),
                  _buildSection(
                    '11. Contact Us',
                    'If you have any questions about this Privacy Policy, please contact us:\n\nPhone: 03131426498\nEmail: ghartekinfo@gmail.com',
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


