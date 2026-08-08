import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'admin_dashboard.dart';
import '../services/notification_service.dart';

class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key});

  @override
  State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  
  bool _isLoading = false;
  bool _obscurePassword = true;

  Future<void> _adminLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final email = _emailController.text.trim();
      final password = _passwordController.text.trim();

      print('Admin login attempt for: $email');

      // Only Firebase authentication - no hardcoded credentials
      try {
        UserCredential userCredential = await FirebaseAuth.instance
            .signInWithEmailAndPassword(email: email, password: password);
        
        User? user = userCredential.user;
        if (user == null) {
          throw Exception('Authentication failed');
        }

        try {
          await NotificationService().refreshScopeBindings();
        } catch (_) {}

        // ── Email verification check ──────────────────────────────────────
        await user.reload();
        user = FirebaseAuth.instance.currentUser;
        if (user != null && !user.emailVerified) {
          await FirebaseAuth.instance.signOut();
          if (mounted) {
            setState(() => _isLoading = false);
            showDialog(
              context: context,
              builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                title: Row(children: const [
                  Icon(Icons.mark_email_unread_rounded, color: Color(0xFFFF6B00)),
                  SizedBox(width: 8),
                  Text('Email Not Verified'),
                ]),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your email ${user?.email ?? ''} is not verified.'),
                    const SizedBox(height: 8),
                    const Text('Please check your inbox and click the verification link before logging in.',
                        style: TextStyle(color: Colors.grey)),
                  ],
                ),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.send_rounded, size: 16),
                    label: const Text('Resend Email'),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B00), foregroundColor: Colors.white),
                    onPressed: () async {
                      try {
                        // Re-authenticate briefly to resend
                        final cred = await FirebaseAuth.instance
                            .signInWithEmailAndPassword(email: email, password: password);
                        await cred.user?.sendEmailVerification();
                        await FirebaseAuth.instance.signOut();
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Verification email sent!'),
                            backgroundColor: Colors.green,
                          ));
                        }
                      } catch (_) {
                        if (ctx.mounted) Navigator.pop(ctx);
                      }
                    },
                  ),
                ],
              ),
            );
          }
          return;
        }
        // ──────────────────────────────────────────────────────────────────

        print('Firebase auth successful for: ${user?.email}');
        
        // Check if user is admin in Firebase database
        final database = FirebaseDatabase.instance.ref();
        
        // Check users table for role
        final userRoleSnapshot = await database
            .child('users')
            .child(user!.uid)
            .child('role')
            .get();
            
        print('Role check for user: ${user.uid}');
        
        if (userRoleSnapshot.exists && userRoleSnapshot.value == 'admin') {
          print('User is admin, showing OTP verification');
          if (mounted) {
            await _showOtpVerification(user);
          }
          return;
        }
        
        print('Checking legacy admin table');
        // Also check legacy admin table
        final adminSnapshot = await database
            .child('admins')
            .child(user.uid)
            .get();

        if (adminSnapshot.exists) {
          print('User found in admin table, showing OTP verification');
          if (mounted) {
            await _showOtpVerification(user);
          }
          return;
        }
        
        print('User is not admin, signing out');
        // Not an admin
        await FirebaseAuth.instance.signOut();
        throw Exception('Access denied. Only admin users can login here.');
      } catch (authError) {
        throw Exception('Invalid credentials or access denied');
      }

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Login failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _showOtpVerification(User user) async {
    // Generate a 6-digit OTP
    final code = (Random().nextInt(900000) + 100000).toString();
    final expiry = DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch;

    // Save OTP to Firebase
    await FirebaseDatabase.instance.ref('admin-otp/${user.uid}').set({
      'code': code,
      'expiresAt': expiry,
    });

    // Send via local notification
    NotificationService().showNotification(
      title: '🔐 Admin Login Code',
      body: 'Your verification code: $code (expires in 5 min)',
    );

    if (!mounted) return;

    final otpController = TextEditingController();
    bool verifying = false;
    String? errorText;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(children: const [
            Icon(Icons.security_rounded, color: Color(0xFFFF6B00)),
            SizedBox(width: 10),
            Text('2-Step Verification'),
          ]),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'A 6-digit code has been sent via notification. Enter it below to continue.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: otpController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 8),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '------',
                  hintStyle: TextStyle(
                      color: Colors.grey[300], letterSpacing: 8, fontSize: 28),
                  errorText: errorText,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14)),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(
                        color: Color(0xFFFF6B00), width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text('Code expires in 5 minutes',
                  style: TextStyle(
                      fontSize: 11, color: Colors.orange[600])),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await FirebaseDatabase.instance
                    .ref('admin-otp/${user.uid}')
                    .remove();
                await FirebaseAuth.instance.signOut();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B00),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              onPressed: verifying
                  ? null
                  : () async {
                      setS(() { verifying = true; errorText = null; });
                      try {
                        final snap = await FirebaseDatabase.instance
                            .ref('admin-otp/${user.uid}')
                            .get();
                        if (!snap.exists) {
                          setS(() {
                            errorText = 'Code expired. Please login again.';
                            verifying = false;
                          });
                          return;
                        }
                        final data =
                            Map<String, dynamic>.from(snap.value as Map);
                        final storedCode = data['code']?.toString() ?? '';
                        final expiresAt =
                            int.tryParse(data['expiresAt'].toString()) ?? 0;
                        final now = DateTime.now().millisecondsSinceEpoch;
                        if (now > expiresAt) {
                          await FirebaseDatabase.instance
                              .ref('admin-otp/${user.uid}')
                              .remove();
                          setS(() {
                            errorText = 'Code expired. Please login again.';
                            verifying = false;
                          });
                          return;
                        }
                        if (otpController.text.trim() != storedCode) {
                          setS(() {
                            errorText = 'Incorrect code. Try again.';
                            verifying = false;
                          });
                          return;
                        }
                        // Correct! Clean up and navigate
                        await FirebaseDatabase.instance
                            .ref('admin-otp/${user.uid}')
                            .remove();
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          Navigator.pushAndRemoveUntil(
                            context,
                            MaterialPageRoute(
                                builder: (_) => const AdminDashboard()),
                            (route) => false,
                          );
                        }
                      } catch (e) {
                        setS(() {
                          errorText = 'Verification error. Try again.';
                          verifying = false;
                        });
                      }
                    },
              child: verifying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Text('Verify'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5EFFF), // Very light cyan
      appBar: AppBar(
        title: const Text('Admin Login'),
        backgroundColor: const Color(0xFFFF6B00), // Teal
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Admin Icon
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFFF6B00), // Teal
                          Color(0xFFFF6B00), // Light blue
                        ],
                      ),
                      borderRadius: BorderRadius.circular(50),
                    ),
                    child: const Icon(
                      Icons.admin_panel_settings,
                      size: 50,
                      color: Colors.white,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Title
                  Text(
                    'Admin Dashboard',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFFFF6B00), // Teal
                    ),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    'Please login to access admin panel',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600]!,
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Login Form Card
                  Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          // Email Field
                          TextFormField(
                            controller: _emailController,
                            decoration: InputDecoration(
                              labelText: 'Admin Email',
                              hintText: 'Enter admin email',
                              prefixIcon: const Icon(Icons.email, color: Color(0xFFFF6B00)), // Teal
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFFFF6B00), width: 2), // Teal
                              ),
                              filled: true,
                              fillColor: const Color(0xFFF5EFFF), // Very light cyan
                            ),
                            keyboardType: TextInputType.emailAddress,
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'Email is required';
                              }
                              if (!value.contains('@')) {
                                return 'Enter a valid email';
                              }
                              return null;
                            },
                          ),

                          const SizedBox(height: 20),

                          // Password Field
                          TextFormField(
                            controller: _passwordController,
                            decoration: InputDecoration(
                              labelText: 'Password',
                              hintText: 'Enter password',
                              prefixIcon: const Icon(Icons.lock, color: Color(0xFFFF6B00)), // Teal
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePassword ? Icons.visibility : Icons.visibility_off,
                                  color: Colors.grey,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFFFF6B00), width: 2), // Teal
                              ),
                              filled: true,
                              fillColor: const Color(0xFFF5EFFF), // Very light cyan
                            ),
                            obscureText: _obscurePassword,
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'Password is required';
                              }
                              return null;
                            },
                          ),

                          const SizedBox(height: 32),

                          // Login Button
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _adminLogin,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFFF6B00), // Teal
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                elevation: 2,
                              ),
                              child: _isLoading
                                  ? const CircularProgressIndicator(color: Colors.white)
                                  : Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        const Icon(Icons.login),
                                        const SizedBox(width: 8),
                                        const Text(
                                          'Login as Admin',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
