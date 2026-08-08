import 'package:flutter/material.dart';

class AboutUsPage extends StatelessWidget {
  const AboutUsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
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
              titlePadding: const EdgeInsets.only(left: 20, bottom: 16, right: 20),
              title: const Text(
                'About GharTek',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
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
                    right: -20,
                    top: -20,
                    child: Icon(
                      Icons.storefront_rounded,
                      size: 200,
                      color: Colors.white.withOpacity(0.15),
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.1),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.delivery_dining_rounded,
                            size: 40,
                            color: Color(0xFFFF6B00),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Your Items, Delivered Fast',
                          style: TextStyle(
                            color: Colors.white,
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w500,
                            fontSize: 16,
                          ),
                        ),
                      ],
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
                  const SizedBox(height: 10),
                  _buildSection(
                    'Our Mission',
                    'At GharTek, we believe that convenience should be accessible to everyone. Our mission is to connect people with their favorite local businesses and provide fast, reliable delivery services that enhance everyday life.',
                    Icons.flag_rounded,
                  ),
                  _buildSection(
                    'What We Do',
                    'GharTek is Pakistan\'s comprehensive delivery platform that brings everything you need right to your doorstep. Whether you\'re craving delicious food, need groceries for the week, require urgent medicines, or want to shop for electronics and other items, we\'ve got you covered.',
                    Icons.store_mall_directory_rounded,
                  ),
                  _buildSection(
                    'Our Services',
                    '🍕 Food Delivery - Fresh meals from your favorite restaurants\n\n🛒 Grocery Delivery - Daily essentials and fresh produce\n\n💊 Medicine Delivery - Prescription and over-the-counter medications\n\n📱 Electronics - Latest gadgets and accessories\n\n🎁 General Items - Everything else you might need',
                    Icons.category_rounded,
                  ),
                  _buildSection(
                    'Why Choose GharTek?',
                    '⚡ Fast Delivery - We prioritize speed without compromising quality\n\n🔒 Secure Platform - Your data and payments are always protected\n\n👥 Trusted Partners - We work with verified local businesses\n\n💯 Reliable Service - Count on us for consistent, dependable delivery\n\n📞 24/7 Support - Our team is here to help whenever you need us',
                    Icons.thumb_up_alt_rounded,
                  ),
                  _buildSection(
                    'Our Vision',
                    'We envision a future where distance is no barrier to accessing quality products and services. Through technology and dedicated service, we aim to transform how people shop and receive their essentials.',
                    Icons.visibility_rounded,
                  ),
                  _buildSection(
                    'Our Values',
                    '🤝 Customer First - Your satisfaction is our top priority\n\n🌟 Quality Service - We maintain high standards in everything we do\n\n🔄 Continuous Improvement - We constantly evolve to serve you better\n\n🌍 Community Focus - Supporting local businesses and communities\n\n💚 Responsibility - Operating ethically and sustainably',
                    Icons.favorite_rounded,
                  ),
                  _buildSection(
                    'Contact Information',
                    'We\'d love to hear from you! Get in touch with our team:\n\n📞 Phone: 03131426498\n📧 Email: ghartekinfo@gmail.com\n\nOur customer support team is available to assist you with any questions, concerns, or feedback you may have.',
                    Icons.contact_mail_rounded,
                  ),
                  _buildSection(
                    'Join Our Community',
                    'Follow us on social media for the latest updates, offers, and announcements. Be part of the GharTek family and help us build a better delivery experience for everyone.',
                    Icons.people_alt_rounded,
                  ),
                  
                  const SizedBox(height: 16),
                  
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.grey.shade200),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.02),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Thank you for choosing GharTek!',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFFFF6B00),
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Order karo, relax karo, aapka saman, hamari delivery.',
                          style: TextStyle(
                            fontStyle: FontStyle.italic,
                            color: Colors.grey[700],
                            fontSize: 15,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        Divider(color: Colors.grey.shade200),
                        const SizedBox(height: 16),
                        Text(
                          '© ${DateTime.now().year} GharTek. All rights reserved.',
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  
                  const SizedBox(height: 30),
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
      margin: const EdgeInsets.only(bottom: 20.0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.shade100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF6B00).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xFFFF6B00), size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A1A),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            content,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }
}
