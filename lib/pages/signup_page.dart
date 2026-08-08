import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import 'login_page.dart';
import 'main_layout.dart';
import 'legal/privacy_policy_page.dart';
import 'legal/terms_conditions_page.dart';
import '../services/notification_service.dart';

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final _formKey = GlobalKey<FormState>();
  final _fullNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final AuthService _authService = AuthService();
  bool _isLoading = false;
  bool _obscurePassword = true;

  static const Color _primary = Color(0xFFFF6B00);

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleSignup() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    try {
      UserCredential? userCredential = await _authService.signUpWithEmailAndPassword(
        fullName: _fullNameController.text.trim(),
        email: _emailController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
        password: _passwordController.text,
      );
      if (userCredential != null && mounted) {
        try {
          await NotificationService().refreshScopeBindings();
        } catch (_) {}
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainLayout()),
        );
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      UserCredential? userCredential = await _authService.signInWithGoogle();
      if (userCredential != null && mounted) {
        try {
          await NotificationService().refreshScopeBindings();
        } catch (_) {}
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainLayout()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Google Sign-In failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String? _validatePhone(String? v) {
    if (v == null || v.trim().isEmpty) return 'Phone number is required';
    if (!RegExp(r'^03\d{9}$').hasMatch(v.trim())) {
      return 'Enter a valid 11-digit number starting with 03';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Welcome header ────────────────────────────────────
              const SizedBox(height: 48),
              Center(
                child: Column(
                  children: [
                    RichText(
                      textAlign: TextAlign.center,
                      text: const TextSpan(
                        children: [
                          TextSpan(
                            text: 'Welcome to\n',
                            style: TextStyle(
                              fontSize: 40,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF1A1A1A),
                              height: 1.2,
                            ),
                          ),
                          TextSpan(
                            text: 'GharTek',
                            style: TextStyle(
                              fontSize: 40,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFFFF6B00),
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Order your favourite Meals and Grocery',
                      style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),

              // ── Google button ─────────────────────────────
              _buildGoogleButton(),
                  const SizedBox(height: 18),

                  // ── OR divider ────────────────────────────────────
                  _buildDivider(),
                  const SizedBox(height: 18),

                  // ── Form fields ───────────────────────────────────
                  Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        _buildTextField(
                          controller: _fullNameController,
                          hint: 'Full Name',
                          icon: Icons.person_rounded,
                          keyboardType: TextInputType.name,
                          textCapitalization: TextCapitalization.words,
                          validator: (v) => (v == null || v.trim().length < 2)
                              ? 'Full name must be at least 2 characters'
                              : null,
                        ),
                        const SizedBox(height: 13),
                        _buildTextField(
                          controller: _emailController,
                          hint: 'Email Address',
                          icon: Icons.email_outlined,
                          keyboardType: TextInputType.emailAddress,
                          validator: (v) {
                            if (v == null || v.trim().isEmpty) return 'Please enter your email';
                            if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(v.trim())) {
                              return 'Enter a valid email address';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 13),
                        _buildTextField(
                          controller: _phoneController,
                          hint: '03001234567',
                          icon: Icons.phone_outlined,
                          keyboardType: TextInputType.phone,
                          maxLength: 11,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(11)],
                          validator: _validatePhone,
                        ),
                        const SizedBox(height: 13),
                        _buildTextField(
                          controller: _passwordController,
                          hint: 'Password (min 8 chars)',
                          icon: Icons.lock_outlined,
                          obscureText: _obscurePassword,
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                              color: Colors.grey[400],
                              size: 20,
                            ),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                          validator: (v) => (v == null || v.length < 8)
                              ? 'Password must be at least 8 characters'
                              : null,
                        ),
                        const SizedBox(height: 22),

                        // Create account button
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _handleSignup,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primary,
                              foregroundColor: Colors.white,
                              elevation: 6,
                              shadowColor: _primary.withValues(alpha: 0.4),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16)),
                            ),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        color: Colors.white, strokeWidth: 2.5),
                                  )
                                : const Text('Create Account',
                                    style: TextStyle(
                                        fontSize: 16, fontWeight: FontWeight.w800)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 26),

                  // ── Login link ────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Already have an account? ',
                          style: TextStyle(color: Colors.grey[500], fontSize: 14)),
                      GestureDetector(
                        onTap: () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (_) => const LoginPage()),
                        ),
                        child: const Text(
                          'Sign In',
                          style: TextStyle(
                              color: _primary, fontSize: 16, fontWeight: FontWeight.w900),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),

                  // ── Disclaimer ────────────────────────────────────
                  _buildDisclaimer(context),
                ],
              ),
          ),
        ),
    );
  }

  Widget _buildDisclaimer(BuildContext context) {
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        children: [
          Text(
            'By continuing, you agree to our ',
            style: TextStyle(fontSize: 11.5, color: Colors.grey[500]),
          ),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TermsConditionsPage()),
            ),
            child: const Text(
              'Terms & Conditions',
              style: TextStyle(
                fontSize: 11.5,
                color: _primary,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
                decorationColor: _primary,
              ),
            ),
          ),
          Text(
            ' and ',
            style: TextStyle(fontSize: 11.5, color: Colors.grey[500]),
          ),
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),
            ),
            child: const Text(
              'Privacy Policy',
              style: TextStyle(
                fontSize: 11.5,
                color: _primary,
                fontWeight: FontWeight.w600,
                decoration: TextDecoration.underline,
                decorationColor: _primary,
              ),
            ),
          ),
          Text(
            '.',
            style: TextStyle(fontSize: 11.5, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildGoogleButton() {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        onPressed: _isLoading ? null : _handleGoogleSignIn,
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.grey[200]!),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: Colors.white,
          elevation: 1,
          shadowColor: Colors.black12,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CustomPaint(painter: _GoogleLogoPainter()),
            ),
            const SizedBox(width: 12),
            const Text(
              'Continue with Google',
              style: TextStyle(color: Color(0xFF444444), fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider() {
    return Row(
      children: [
        Expanded(child: Divider(color: Colors.grey[200], height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Text('OR',
              style: TextStyle(
                  color: Colors.grey[400], fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1)),
        ),
        Expanded(child: Divider(color: Colors.grey[200], height: 1)),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
    TextCapitalization textCapitalization = TextCapitalization.none,
    bool obscureText = false,
    Widget? suffixIcon,
    int? maxLength,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      obscureText: obscureText,
      maxLength: maxLength,
      buildCounter: maxLength != null
          ? (_, {required currentLength, required isFocused, maxLength}) => null
          : null,
      inputFormatters: inputFormatters,
      validator: validator,
      style: const TextStyle(
          fontSize: 14.5, fontWeight: FontWeight.w500, color: Color(0xFF1A1A1A)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
        prefixIcon: Icon(icon, color: _primary, size: 20),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: const Color(0xFFF7F7F7),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide(color: Colors.grey[100]!)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: _primary, width: 1.8)),
        errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Colors.red)),
        focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Colors.red, width: 1.8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      ),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 48.0;
    final Paint p = Paint()..style = PaintingStyle.fill;
    p.color = const Color(0xFFEA4335);
    final r = Path()
      ..moveTo(24 * s, 9.5 * s)
      ..cubicTo(27.54 * s, 9.5 * s, 30.71 * s, 10.72 * s, 33.21 * s, 13.1 * s)
      ..lineTo(40.06 * s, 6.25 * s)
      ..cubicTo(35.9 * s, 2.38 * s, 30.47 * s, 0, 24 * s, 0)
      ..cubicTo(14.62 * s, 0, 6.51 * s, 5.38 * s, 2.56 * s, 13.22 * s)
      ..lineTo(10.54 * s, 19.41 * s)
      ..cubicTo(12.43 * s, 13.72 * s, 17.74 * s, 9.5 * s, 24 * s, 9.5 * s)
      ..close();
    canvas.drawPath(r, p);
    p.color = const Color(0xFF4285F4);
    final b = Path()
      ..moveTo(46.98 * s, 24.55 * s)
      ..cubicTo(46.98 * s, 22.98 * s, 46.83 * s, 21.46 * s, 46.6 * s, 20 * s)
      ..lineTo(24 * s, 20 * s)
      ..lineTo(24 * s, 29.02 * s)
      ..lineTo(36.94 * s, 29.02 * s)
      ..cubicTo(36.36 * s, 31.98 * s, 34.68 * s, 34.5 * s, 32.16 * s, 36.2 * s)
      ..lineTo(39.89 * s, 42.2 * s)
      ..cubicTo(44.4 * s, 38.02 * s, 46.98 * s, 31.85 * s, 46.98 * s, 24.55 * s)
      ..close();
    canvas.drawPath(b, p);
    p.color = const Color(0xFFFBBC05);
    final y = Path()
      ..moveTo(10.53 * s, 28.59 * s)
      ..cubicTo(10.05 * s, 27.14 * s, 9.77 * s, 25.6 * s, 9.77 * s, 24 * s)
      ..cubicTo(9.77 * s, 22.4 * s, 10.04 * s, 20.86 * s, 10.53 * s, 19.41 * s)
      ..lineTo(2.55 * s, 13.22 * s)
      ..cubicTo(0.92 * s, 16.46 * s, 0, 20.12 * s, 0, 24 * s)
      ..cubicTo(0, 27.88 * s, 0.92 * s, 31.54 * s, 2.56 * s, 34.78 * s)
      ..lineTo(10.53 * s, 28.59 * s)
      ..close();
    canvas.drawPath(y, p);
    p.color = const Color(0xFF34A853);
    final g = Path()
      ..moveTo(24 * s, 48 * s)
      ..cubicTo(30.48 * s, 48 * s, 35.93 * s, 45.87 * s, 39.89 * s, 42.19 * s)
      ..lineTo(32.16 * s, 36.19 * s)
      ..cubicTo(30.01 * s, 37.64 * s, 27.24 * s, 38.49 * s, 24 * s, 38.49 * s)
      ..cubicTo(17.74 * s, 38.49 * s, 12.43 * s, 34.27 * s, 10.53 * s, 28.58 * s)
      ..lineTo(2.55 * s, 34.77 * s)
      ..cubicTo(6.51 * s, 42.62 * s, 14.62 * s, 48 * s, 24 * s, 48 * s)
      ..close();
    canvas.drawPath(g, p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Keep old class alias for backward compatibility
class GoogleSVGPainter extends _GoogleLogoPainter {}
