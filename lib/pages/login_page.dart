import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:lottie/lottie.dart';
import '../services/auth_service.dart';
import '../services/city_scope_service.dart';
import 'signup_page.dart';
import 'forgot_password_page.dart';
import 'main_layout.dart';
import 'legal/privacy_policy_page.dart';
import 'legal/terms_conditions_page.dart';
import 'admin_dashboard.dart';
import 'rider_dashboard.dart';
import 'merchant_dashboard.dart';
import '../services/notification_service.dart';
import '../services/analytics_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState(); 
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailOrPhoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final AuthService _authService = AuthService();
  bool _isLoading = false;
  bool _obscurePassword = true;

  static const Color _primary = Color(0xFFFF6B00);

  String _normalizeRole(dynamic raw) {
    final value = (raw ?? '').toString().trim().toLowerCase();
    if (value == 'admin' || value == 'rider' || value == 'merchant') {
      return value;
    }
    return 'customer';
  }

  @override
  void dispose() {
    _emailOrPhoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    try {
      UserCredential? userCredential = await _authService.signInWithEmailAndPassword(
        emailOrPhone: _emailOrPhoneController.text.trim(),
        password: _passwordController.text,
      );
      if (userCredential != null && mounted) {
        AnalyticsService.identifyUser(userCredential.user!.uid, email: userCredential.user!.email);
        await Future.delayed(const Duration(milliseconds: 800));
        String userRole = await _getUserRole(userCredential.user!.uid);
        try {
          if (userRole == 'admin') {
            await _authService.syncAdminCityScopeForCurrentUser(
              uid: userCredential.user!.uid,
            );
          } else if (userRole == 'rider' || userRole == 'merchant') {
            await CityScopeService.syncCityFromUserProfile(
              userCredential.user!.uid,
              role: userRole,
            );
          } else {
            await _authService.syncUserCityScopeForCurrentUser(
              uid: userCredential.user!.uid,
              role: userRole,
            );
          }
        } catch (_) {}
        try {
          await NotificationService().refreshScopeBindings();
        } catch (_) {}
        if (mounted) {
          if (userRole == 'admin') {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => AdminDashboard()),
            );
          } else if (userRole == 'rider') {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const RiderDashboard()),
            );
          } else if (userRole == 'merchant') {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const MerchantDashboard()),
            );
          } else {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => MainLayout()),
            );
          }
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        Fluttertoast.showToast(
          msg: e.message ?? 'Login failed. Please try again.',
          toastLength: Toast.LENGTH_LONG,
        );
      }
    } catch (e) {
      if (mounted) {
        Fluttertoast.showToast(
          msg: 'Login failed: $e',
          toastLength: Toast.LENGTH_LONG,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String> _getUserRole(String userId) async {
    try {
      final snap = await FirebaseDatabase.instance.ref('users/$userId/role').get();
      return _normalizeRole(snap.exists ? snap.value : 'customer');
    } catch (_) {
      return 'customer';
    }
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    try {
      UserCredential? userCredential = await _authService.signInWithGoogle();
      if (userCredential != null && mounted) {
        await Future.delayed(const Duration(milliseconds: 800));
        String userRole = await _getUserRole(userCredential.user!.uid);
        try {
          if (userRole == 'admin') {
            await _authService.syncAdminCityScopeForCurrentUser(
              uid: userCredential.user!.uid,
            );
          } else if (userRole == 'rider' || userRole == 'merchant') {
            await CityScopeService.syncCityFromUserProfile(
              userCredential.user!.uid,
              role: userRole,
            );
          } else {
            await _authService.syncUserCityScopeForCurrentUser(
              uid: userCredential.user!.uid,
              role: userRole,
            );
          }
        } catch (_) {}
        try {
          await NotificationService().refreshScopeBindings();
        } catch (_) {}
        if (mounted) {
          if (userRole == 'admin') {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => AdminDashboard()),
            );
          } else if (userRole == 'rider') {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const RiderDashboard()),
            );
          } else if (userRole == 'merchant') {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const MerchantDashboard()),
            );
          } else {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => MainLayout()),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        Fluttertoast.showToast(
          msg: e.toString().contains('cancel')
              ? 'Google Sign-In was cancelled'
              : 'Google Sign-In failed. Please try again or use email login.',
          toastLength: Toast.LENGTH_LONG,
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
              // ── Welcome header ─────────────────────────────────
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

              const SizedBox(height: 24),

              // ── Google sign-in ──────────────────────────────────
              _buildGoogleButton(),
              const SizedBox(height: 18),

              // ── OR divider ──────────────────────────────────────
              _buildDivider(),
              const SizedBox(height: 18),

              // ── Form fields ─────────────────────────────────────
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    _buildTextField(
                      controller: _emailOrPhoneController,
                      hint: 'Email or Phone Number',
                      icon: Icons.person_outline_rounded,
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Please enter your email or phone'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    _buildTextField(
                      controller: _passwordController,
                      hint: 'Password',
                      icon: Icons.lock_outline_rounded,
                      obscureText: _obscurePassword,
                      suffixIcon: _visibilityToggle(
                        isObscure: _obscurePassword,
                        onTap: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Password is required'
                          : null,
                    ),
                  ],
                ),
              ),

              // ── Forgot password ─────────────────────────────────
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ForgotPasswordPage()),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'Forgot Password?',
                    style: TextStyle(
                      color: _primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // ── Login button ────────────────────────────────────
              _buildPrimaryButton(
                label: 'Login',
                onPressed: _handleLogin,
                isLoading: _isLoading,
              ),
              const SizedBox(height: 26),

              // ── Sign up link ────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Don't have an account? ",
                    style: TextStyle(color: Colors.grey[500], fontSize: 14),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const SignupPage()),
                    ),
                    child: const Text(
                      'Sign Up',
                      style: TextStyle(
                        color: _primary,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),

              // ── Disclaimer ──────────────────────────────────────
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

  // ─── Shared UI helpers ────────────────────────────────────────────

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
              child: CustomPaint(painter: GoogleLogoSVGPainter()),
            ),
            const SizedBox(width: 12),
            const Text(
              'Continue with Google',
              style: TextStyle(
                color: Color(0xFF444444),
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
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
          child: Text(
            'OR',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
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
    bool obscureText = false,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      validator: validator,
      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: Color(0xFF1A1A1A)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
        prefixIcon: Icon(icon, color: _primary, size: 20),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: const Color(0xFFF7F7F7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.grey[100]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: _primary, width: 1.8),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.red),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.red, width: 1.8),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      ),
    );
  }

  Widget _visibilityToggle({required bool isObscure, required VoidCallback onTap}) {
    return IconButton(
      icon: Icon(
        isObscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        color: Colors.grey[400],
        size: 20,
      ),
      onPressed: onTap,
    );
  }

  Widget _buildPrimaryButton({
    required String label,
    required VoidCallback onPressed,
    required bool isLoading,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: _primary,
          foregroundColor: Colors.white,
          elevation: 6,
          shadowColor: _primary.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        child: isLoading
            ? Stack(
                fit: StackFit.expand,
                children: [
                  const Center(
                    child: Text(
                      'Signing in...',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(left: 20),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.4,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : Text(
                label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
      ),
    );
  }
}

// Official Google Logo SVG Painter
class GoogleLogoSVGPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.width / 48.0;
    final Paint paint = Paint()..style = PaintingStyle.fill;

    paint.color = const Color(0xFFEA4335);
    final Path redPath = Path();
    redPath.moveTo(24 * scale, 9.5 * scale);
    redPath.cubicTo(27.54 * scale, 9.5 * scale, 30.71 * scale, 10.72 * scale, 33.21 * scale, 13.1 * scale);
    redPath.lineTo(40.06 * scale, 6.25 * scale);
    redPath.cubicTo(35.9 * scale, 2.38 * scale, 30.47 * scale, 0, 24 * scale, 0);
    redPath.cubicTo(14.62 * scale, 0, 6.51 * scale, 5.38 * scale, 2.56 * scale, 13.22 * scale);
    redPath.lineTo(10.54 * scale, 19.41 * scale);
    redPath.cubicTo(12.43 * scale, 13.72 * scale, 17.74 * scale, 9.5 * scale, 24 * scale, 9.5 * scale);
    redPath.close();
    canvas.drawPath(redPath, paint);

    paint.color = const Color(0xFF4285F4);
    final Path bluePath = Path();
    bluePath.moveTo(46.98 * scale, 24.55 * scale);
    bluePath.cubicTo(46.98 * scale, 22.98 * scale, 46.83 * scale, 21.46 * scale, 46.6 * scale, 20 * scale);
    bluePath.lineTo(24 * scale, 20 * scale);
    bluePath.lineTo(24 * scale, 29.02 * scale);
    bluePath.lineTo(36.94 * scale, 29.02 * scale);
    bluePath.cubicTo(36.36 * scale, 31.98 * scale, 34.68 * scale, 34.5 * scale, 32.16 * scale, 36.2 * scale);
    bluePath.lineTo(39.89 * scale, 42.2 * scale);
    bluePath.cubicTo(44.4 * scale, 38.02 * scale, 46.98 * scale, 31.85 * scale, 46.98 * scale, 24.55 * scale);
    bluePath.close();
    canvas.drawPath(bluePath, paint);

    paint.color = const Color(0xFFFBBC05);
    final Path yellowPath = Path();
    yellowPath.moveTo(10.53 * scale, 28.59 * scale);
    yellowPath.cubicTo(10.05 * scale, 27.14 * scale, 9.77 * scale, 25.6 * scale, 9.77 * scale, 24 * scale);
    yellowPath.cubicTo(9.77 * scale, 22.4 * scale, 10.04 * scale, 20.86 * scale, 10.53 * scale, 19.41 * scale);
    yellowPath.lineTo(2.55 * scale, 13.22 * scale);
    yellowPath.cubicTo(0.92 * scale, 16.46 * scale, 0, 20.12 * scale, 0, 24 * scale);
    yellowPath.cubicTo(0, 27.88 * scale, 0.92 * scale, 31.54 * scale, 2.56 * scale, 34.78 * scale);
    yellowPath.lineTo(10.53 * scale, 28.59 * scale);
    yellowPath.close();
    canvas.drawPath(yellowPath, paint);

    paint.color = const Color(0xFF34A853);
    final Path greenPath = Path();
    greenPath.moveTo(24 * scale, 48 * scale);
    greenPath.cubicTo(30.48 * scale, 48 * scale, 35.93 * scale, 45.87 * scale, 39.89 * scale, 42.19 * scale);
    greenPath.lineTo(32.16 * scale, 36.19 * scale);
    greenPath.cubicTo(30.01 * scale, 37.64 * scale, 27.24 * scale, 38.49 * scale, 24 * scale, 38.49 * scale);
    greenPath.cubicTo(17.74 * scale, 38.49 * scale, 12.43 * scale, 34.27 * scale, 10.53 * scale, 28.58 * scale);
    greenPath.lineTo(2.55 * scale, 34.77 * scale);
    greenPath.cubicTo(6.51 * scale, 42.62 * scale, 14.62 * scale, 48 * scale, 24 * scale, 48 * scale);
    greenPath.close();
    canvas.drawPath(greenPath, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

