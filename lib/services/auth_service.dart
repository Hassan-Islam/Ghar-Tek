import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:flutter/services.dart';
import '../firebase_options.dart';
import 'city_scope_service.dart';
import 'analytics_service.dart';
import 'session_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'email',
      'profile', 
      'openid',
    ],
  );

  static const Set<String> _bootstrapAdminEmails = {
    'qa568581@gmail.com',
    'arshadahsan77900@gmail.com',
    'raf451810@gmail.com',
    'waqaraliwebs@gmail.com',
  };

  static const String _merchantCredPath = 'merchantCredentials';

  String _tenantPath(String path, {String? city}) =>
      CityScopeService.tenantPath(path, city: city);

  Future<void> assignAdminCityScope({
    required String uid,
    required String city,
  }) async {
    final normalized = CityScopeService.normalizeCity(city);
    await _database.ref('users/$uid').update({
      'adminCity': normalized,
      'adminCityAssignedAt': ServerValue.timestamp,
    });
  }

  Future<String?> syncAdminCityScopeForCurrentUser({
    required String uid,
    bool assignFromCurrentIfMissing = true,
  }) async {
    final snap = await _database.ref('users/$uid').get();
    if (!snap.exists || snap.value is! Map) return null;

    final user = Map<String, dynamic>.from(snap.value as Map);
    final role = (user['role'] ?? 'customer').toString();
    if (role != 'admin') return null;

    await CityScopeService.ensureLoaded();

    final currentField = (user['adminCity'] ?? '').toString().trim();
    String resolvedCity;

    if (currentField.isNotEmpty) {
      resolvedCity = CityScopeService.normalizeCity(currentField);
      if (resolvedCity != currentField.toLowerCase()) {
        await assignAdminCityScope(uid: uid, city: resolvedCity);
      }
    } else {
      if (!assignFromCurrentIfMissing) return null;
      resolvedCity = CityScopeService.currentCity;
      await assignAdminCityScope(uid: uid, city: resolvedCity);
    }

    await CityScopeService.setSelectedCity(resolvedCity);
    return resolvedCity;
  }

  Future<void> assignUserCityScope({
    required String uid,
    required String city,
  }) async {
    final normalized = CityScopeService.normalizeCity(city);
    await _database.ref('users/$uid').update({
      'userCity': normalized,
      'userCityAssignedAt': ServerValue.timestamp,
    });
  }

  Future<String?> syncUserCityScopeForCurrentUser({
    required String uid,
    required String role,
    bool assignFromCurrentIfMissing = true,
  }) async {
    final normalizedRole = role.trim().toLowerCase();
    if (normalizedRole == 'admin') {
      return syncAdminCityScopeForCurrentUser(
        uid: uid,
        assignFromCurrentIfMissing: assignFromCurrentIfMissing,
      );
    }

    final snap = await _database.ref('users/$uid').get();
    if (!snap.exists || snap.value is! Map) return null;

    final user = Map<String, dynamic>.from(snap.value as Map);
    await CityScopeService.ensureLoaded();

    final currentField = (user['userCity'] ?? '').toString().trim();
    String resolvedCity;

    if (currentField.isNotEmpty) {
      resolvedCity = CityScopeService.normalizeCity(currentField);
      if (resolvedCity != currentField.toLowerCase()) {
        await assignUserCityScope(uid: uid, city: resolvedCity);
      }
    } else {
      if (!assignFromCurrentIfMissing) return null;
      resolvedCity = CityScopeService.currentCity;
      await assignUserCityScope(uid: uid, city: resolvedCity);
    }

    await CityScopeService.setSelectedCity(resolvedCity);
    return resolvedCity;
  }

  Map<String, dynamic> defaultMerchantPermissions() {
    return {
      'canUpdateOrderStatus': true,
      'canManageProducts': false,
      'canEditPrices': true,
      'canToggleShopOpen': true,
      'canViewRevenue': true,
    };
  }

  Future<void> _ensureCurrentUserIsAdmin() async {
    final adminUser = _auth.currentUser;
    if (adminUser == null) {
      throw Exception('Admin must be logged in.');
    }
    final roleSnap = await _database.ref('users/${adminUser.uid}/role').get();
    if (!roleSnap.exists || roleSnap.value?.toString() != 'admin') {
      throw Exception('Only admin can perform this action.');
    }
  }

  Future<Map<String, dynamic>> _getShopDataOrThrow(
    String shopId, {
    String? city,
  }) async {
    await CityScopeService.ensureLoaded();
    final snap = await _database.ref(_tenantPath('shops/$shopId', city: city)).get();
    if (!snap.exists || snap.value is! Map) {
      throw Exception('Shop not found.');
    }
    return Map<String, dynamic>.from(snap.value as Map);
  }

  String _resolveRoleForEmail(String? email) {
    final normalized = (email ?? '').trim().toLowerCase();
    return _bootstrapAdminEmails.contains(normalized) ? 'admin' : 'customer';
  }

  Map<String, dynamic>? _defaultPermissionsForRole(String role) {
    if (role != 'admin') return null;
    return {
      'orders': true,
      'shops': true,
      'users': true,
      'finance': true,
      'notifications': true,
    };
  }

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Auth state changes stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Sign up with email and password
  Future<UserCredential?> signUpWithEmailAndPassword({
    required String fullName,
    required String email,
    required String phoneNumber,
    required String password,
  }) async {
    try {
      // Create user with email and password
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      User? user = userCredential.user;
      if (user != null) {
        // Update profile with display name
        await user.updateDisplayName(fullName);

        // Send email verification
        try {
          await user.sendEmailVerification();
        } catch (e) {
          print('Could not send verification email: $e');
        }

        // Save user data to Realtime Database
        String userRole = _resolveRoleForEmail(email);
        await CityScopeService.ensureLoaded();
        final selectedCity = CityScopeService.currentCity;
        
        print('Saving user data to Firebase for: $email');
        
        try {
          final userData = {
            'id': user.uid,
            'name': fullName,
            'email': email,
            'phoneNumber': phoneNumber,
            'role': userRole,
            'orders': 0,
            'isBanned': false,
            'createdAt': DateTime.now().toIso8601String(),
            if (userRole == 'admin') 'adminCity': selectedCity,
            if (userRole == 'admin') 'adminCityAssignedAt': ServerValue.timestamp,
            if (userRole != 'admin') 'userCity': selectedCity,
            if (userRole != 'admin') 'userCityAssignedAt': ServerValue.timestamp,
          };
          final permissions = _defaultPermissionsForRole(userRole);
          if (permissions != null) {
            userData['permissions'] = permissions;
          }
          await _database.ref('users/${user.uid}').set(userData);
          
          print('User data saved successfully to Firebase for: $email');
          
          Fluttertoast.showToast(
            msg: "Account created successfully! Please verify your email.",
            toastLength: Toast.LENGTH_LONG,
          );
        } catch (dbError) {
          print('Error saving user data to Firebase: $dbError');
          
          Fluttertoast.showToast(
            msg: "Account created but profile setup failed. Please contact support.",
            toastLength: Toast.LENGTH_LONG,
          );
          
          // Don't throw error, let user continue
        }
        
        await SessionService().updateSessionId();
      }

      return userCredential;
    } on FirebaseAuthException catch (e) {
      String errorMessage = 'An error occurred during sign up';
      
      switch (e.code) {
        case 'weak-password':
          errorMessage = 'The password provided is too weak.';
          break;
        case 'email-already-in-use':
          errorMessage = 'The account already exists for that email.';
          break;
        case 'invalid-email':
          errorMessage = 'The email address is not valid.';
          break;
        case 'operation-not-allowed':
          errorMessage = 'Email/password accounts are not enabled.';
          break;
        default:
          errorMessage = e.message ?? 'An error occurred during sign up';
      }
      
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_LONG,
      );
      throw Exception(errorMessage);
    } catch (e) {
      String errorMessage = 'An unexpected error occurred: $e';
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_LONG,
      );
      throw Exception(errorMessage);
    }
  }

  // Sign in with email and password
  Future<UserCredential?> signInWithEmailAndPassword({
    required String emailOrPhone,
    required String password,
  }) async {
    try {
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: emailOrPhone,
        password: password,
      );

      await SessionService().updateSessionId();

      return userCredential;
    } on FirebaseAuthException catch (e) {
      String errorMessage = 'An error occurred during sign in';
      
      switch (e.code) {
        case 'user-not-found':
          errorMessage = 'No user found for that email.';
          break;
        case 'wrong-password':
          errorMessage = 'Wrong password provided.';
          break;
        case 'invalid-email':
          errorMessage = 'The email address is not valid.';
          break;
        case 'user-disabled':
          errorMessage = 'This user account has been disabled.';
          break;
        case 'too-many-requests':
          errorMessage = 'Too many failed attempts. Please try again later.';
          break;
        default:
          errorMessage = e.message ?? 'An error occurred during sign in';
      }
      
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_LONG,
      );
      throw Exception(errorMessage);
    } catch (e) {
      String errorMessage = 'An unexpected error occurred: $e';
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_LONG,
      );
      throw Exception(errorMessage);
    }
  }

  // Sign in with Google
  Future<UserCredential?> signInWithGoogle() async {
    try {
      print('Starting Google Sign-In process...');
      
      // Trigger the authentication flow
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      print('Google Sign-In account obtained: ${googleUser?.email}');
      
      if (googleUser == null) {
        // User canceled the sign-in
        print('Google Sign-In was cancelled by user');
        return null;
      }

      // Obtain the auth details from the request
      print('Getting Google authentication details...');
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      // Check if we have the required tokens
      if (googleAuth.accessToken == null) {
        print('Failed to obtain Google access token');
        throw Exception('Failed to obtain Google access token');
      }
      
      // For web, ID token might be missing due to configuration issues
      if (googleAuth.idToken == null) {
        print('ID Token is missing - using alternative web authentication method');
        
        // For web, we can try using just the access token with a different approach
        try {
          // Create a credential using only access token (web fallback)
          final credential = GoogleAuthProvider.credential(
            accessToken: googleAuth.accessToken,
          );
          
          print('Signing in to Firebase with access token only...');
          UserCredential userCredential = await _auth.signInWithCredential(credential);
          User? user = userCredential.user;
          
          if (user != null) {
            print('Firebase sign-in successful with access token for: ${user.email}');
            await _handleUserAfterSignIn(user, googleUser);
            return userCredential;
          }
        } catch (webAuthError) {
          print('Web auth fallback failed: $webAuthError');
          
          // If even the fallback fails, show a helpful message
          Fluttertoast.showToast(
            msg: "Google Sign-In issue detected. Please try using email/password login instead.",
            toastLength: Toast.LENGTH_LONG,
          );
          return null;
        }
      }
      
      print('Google authentication tokens obtained successfully');

      // Create a new credential
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      
      print('Signing in to Firebase with Google credential...');

      // Sign in to Firebase with the Google credential
      UserCredential userCredential = await _auth.signInWithCredential(credential);
      User? user = userCredential.user;
      
      print('Firebase sign-in successful for: ${user?.email}');

      if (user != null) {
        await _handleUserAfterSignIn(user, googleUser);
      }

      return userCredential;
    } on PlatformException catch (e) {
      String errorMessage = 'Google Sign-In failed';
      
      switch (e.code) {
        case 'sign_in_canceled':
          errorMessage = 'Google Sign-In was cancelled';
          break;
        case 'sign_in_failed':
          errorMessage = 'Google Sign-In failed. Please try again.';
          break;
        case 'network_error':
          errorMessage = 'Network error. Please check your connection.';
          break;
        default:
          errorMessage = 'Google Sign-In error: ${e.message}';
      }
      
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_SHORT,
      );
      return null;
    } catch (e) {
      String errorMessage = 'Google Sign-In failed: $e';
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_SHORT,
      );
      return null;
    }
  }

  // Helper method to handle user data after Google Sign-In
  Future<void> _handleUserAfterSignIn(User user, GoogleSignInAccount googleUser) async {
    // Check if user exists in database
    print('Checking if user exists in database...');
    DatabaseReference userRef = _database.ref('users/${user.uid}');
    DataSnapshot snapshot = await userRef.get();
    String resolvedRole = 'customer';

    if (!snapshot.exists) {
      // New user, save to database with basic info
      String userRole = _resolveRoleForEmail(user.email ?? googleUser.email);
      resolvedRole = userRole;
      String userEmail = user.email ?? googleUser.email;
      await CityScopeService.ensureLoaded();
      final selectedCity = CityScopeService.currentCity;
      
      print('Saving Google user data to Firebase for: $userEmail');
      
      try {
        final userData = {
          'id': user.uid,
          'name': user.displayName ?? googleUser.displayName ?? 'Google User',
          'email': userEmail,
          'phoneNumber': user.phoneNumber ?? '',
          'role': userRole,
          'orders': 0,
          'isBanned': false,
          'createdAt': DateTime.now().toIso8601String(),
          if (userRole == 'admin') 'adminCity': selectedCity,
          if (userRole == 'admin') 'adminCityAssignedAt': ServerValue.timestamp,
          if (userRole != 'admin') 'userCity': selectedCity,
          if (userRole != 'admin') 'userCityAssignedAt': ServerValue.timestamp,
        };
        final permissions = _defaultPermissionsForRole(userRole);
        if (permissions != null) {
          userData['permissions'] = permissions;
        }
        await userRef.set(userData);
        
        print('Google user data saved successfully to Firebase for: $userEmail');
      } catch (dbError) {
        print('Error saving Google user data to Firebase: $dbError');
      }
    } else {
      // Existing user, update last login
      print('Existing user found, updating last login...');
      Map<dynamic, dynamic> userData = snapshot.value as Map<dynamic, dynamic>;
      resolvedRole = (userData['role'] ?? 'customer').toString();
      
      // Check if user is banned
      if (userData['isBanned'] == true) {
        await signOut();
        throw Exception('Your account has been suspended. Please contact support.');
      }
      
      await userRef.update({
        'lastLogin': DateTime.now().toIso8601String(),
      });
    }

    try {
      await syncUserCityScopeForCurrentUser(
        uid: user.uid,
        role: resolvedRole,
      );
    } catch (_) {}

    await SessionService().updateSessionId();

    // Welcome toast removed per user request
  }

  // Sign out
  Future<void> signOut() async {
    try {
      print('SignOut process started...');
      
      // Sign out from Firebase Auth
      await _auth.signOut();
      print('Firebase Auth signOut completed');
      
      AnalyticsService.reset();
      
      // Sign out from Google Sign-In
      try {
        await _googleSignIn.signOut();
        print('Google SignIn signOut completed');
      } catch (googleError) {
        print('Google SignIn error (continuing anyway): $googleError');
      }
      
      Fluttertoast.showToast(
        msg: "Signed out successfully",
        toastLength: Toast.LENGTH_SHORT,
      );
      
      print('SignOut process completed successfully');
    } catch (e) {
      print('Error signing out: $e');
      
      // Try to force logout even if there's an error
      try {
        await _auth.signOut();
      } catch (authError) {
        print('Force Firebase signOut error: $authError');
      }
      
      Fluttertoast.showToast(
        msg: "Logout completed with warnings",
        toastLength: Toast.LENGTH_SHORT,
      );
    }
  }

  // Reset password
  Future<void> resetPassword(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      
      Fluttertoast.showToast(
        msg: "Password reset email sent to $email",
        toastLength: Toast.LENGTH_LONG,
      );
    } on FirebaseAuthException catch (e) {
      String errorMessage = 'An error occurred';
      
      switch (e.code) {
        case 'user-not-found':
          errorMessage = 'No user found for that email.';
          break;
        case 'invalid-email':
          errorMessage = 'The email address is not valid.';
          break;
        default:
          errorMessage = e.message ?? 'An error occurred';
      }
      
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_LONG,
      );
      throw Exception(errorMessage);
    }
  }

  // Get user data from database
  Future<Map<String, dynamic>?> getUserData(String uid) async {
    try {
      DataSnapshot snapshot = await _database.ref('users/$uid').get();
      
      if (snapshot.exists) {
        return Map<String, dynamic>.from(snapshot.value as Map);
      }
      return null;
    } catch (e) {
      print('Error getting user data: $e');
      return null;
    }
  }

  // Update user profile
  Future<void> updateUserProfile({
    required String uid,
    String? displayName,
    String? phoneNumber,
    String? profileImageUrl,
  }) async {
    try {
      Map<String, dynamic> updates = {};
      
      if (displayName != null) {
        updates['name'] = displayName;
        await currentUser?.updateDisplayName(displayName);
      }
      
      if (phoneNumber != null) {
        updates['phoneNumber'] = phoneNumber;
      }

      if (profileImageUrl != null) {
        updates['profileImageUrl'] = profileImageUrl;
        await currentUser?.updatePhotoURL(profileImageUrl);
      }
      
      if (updates.isNotEmpty) {
        await _database.ref('users/$uid').update(updates);
        
        Fluttertoast.showToast(
          msg: "Profile updated successfully",
          toastLength: Toast.LENGTH_SHORT,
        );
      }
    } catch (e) {
      String errorMessage = 'Failed to update profile: $e';
      Fluttertoast.showToast(
        msg: errorMessage,
        toastLength: Toast.LENGTH_LONG,
      );
      throw Exception(errorMessage);
    }
  }

  // Get user role from Firebase database
  Future<String> getUserRole(String uid, String? userEmail) async {
    try {
      DatabaseReference ref = _database.ref('users/$uid/role');
      DataSnapshot snapshot = await ref.get();
      
      if (snapshot.exists) {
        String role = snapshot.value.toString();
        final expectedRole = _resolveRoleForEmail(userEmail);
        if (expectedRole == 'admin' && role != 'admin') {
          await _database.ref('users/$uid').update({
            'role': 'admin',
            'permissions': _defaultPermissionsForRole('admin'),
          });
          role = 'admin';
        }
        print('User role from Firebase: $role');
        return role;
      } else {
        print('No role found for user, setting default role as customer');
        
        // Set default customer role if not exists in database
        String role = _resolveRoleForEmail(userEmail);
        
        // Save the role to Firebase Database
        await ref.set(role);
        if (role == 'admin') {
          await _database.ref('users/$uid/permissions').set(_defaultPermissionsForRole('admin'));
        }
        print('Role set to: $role for user: $uid');
        
        return role;
      }
    } catch (e) {
      print('Error fetching user role: $e');
      return 'customer'; // Default role on error
    }
  }

  // Check if current user is admin
  Future<bool> isUserAdmin() async {
    User? user = currentUser;
    if (user == null) return false;
    
    String role = await getUserRole(user.uid, user.email);
    return role == 'admin';
  }

  // Add missing user data to Realtime Database (for existing auth users)
  Future<void> addMissingUserData() async {
    User? user = currentUser;
    if (user == null) {
      print('No current user found');
      return;
    }

    try {
      print('Checking user data for: ${user.email}');
      
      // Check if user exists in database
      DataSnapshot snapshot = await _database.ref('users/${user.uid}').get();
      
      if (!snapshot.exists) {
        print('User data missing in Firebase database for: ${user.email}');
        print('Adding missing user data...');
        
        // Create user data with default values
        String userRole = _resolveRoleForEmail(user.email);
        await CityScopeService.ensureLoaded();
        final selectedCity = CityScopeService.currentCity;
        
        final userData = {
          'id': user.uid,
          'name': user.displayName ?? 'User',
          'email': user.email ?? '',
          'phoneNumber': user.phoneNumber ?? '',
          'role': userRole,
          'orders': 0,
          'isBanned': false,
          'createdAt': DateTime.now().toIso8601String(),
          if (userRole == 'admin') 'adminCity': selectedCity,
          if (userRole == 'admin') 'adminCityAssignedAt': ServerValue.timestamp,
          if (userRole != 'admin') 'userCity': selectedCity,
          if (userRole != 'admin') 'userCityAssignedAt': ServerValue.timestamp,
        };
        final permissions = _defaultPermissionsForRole(userRole);
        if (permissions != null) {
          userData['permissions'] = permissions;
        }
        await _database.ref('users/${user.uid}').set(userData);
        
        print('✅ User data added successfully for: ${user.email}');
        
        Fluttertoast.showToast(
          msg: "User profile created successfully",
          toastLength: Toast.LENGTH_SHORT,
        );
      } else {
        print('✅ User data already exists for: ${user.email}');
      }
    } catch (e) {
      print('❌ Error checking/adding user data: $e');
      
      Fluttertoast.showToast(
        msg: "Profile setup issue. Please contact support.",
        toastLength: Toast.LENGTH_SHORT,
      );
    }
  }

  // Re-authenticate with email/password for sensitive operations
  Future<void> reauthenticateWithPassword(String password) async {
    final user = currentUser;
    if (user == null || user.email == null) throw Exception('Not logged in');
    final cred = EmailAuthProvider.credential(email: user.email!, password: password);
    await user.reauthenticateWithCredential(cred);
  }

  // Re-authenticate with Google for sensitive operations
  Future<void> reauthenticateWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) throw Exception('Google sign-in cancelled');
    final googleAuth = await googleUser.authentication;
    final cred = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    await currentUser?.reauthenticateWithCredential(cred);
  }

  // Permanently delete user account and all data
  Future<void> deleteAccountPermanently() async {
    final user = currentUser;
    if (user == null) throw Exception('Not logged in');
    final uid = user.uid;
    // Remove user data from database
    await _database.ref('users/$uid').remove();
    // Delete Firebase Auth account
    await user.delete();
    // Sign out Google
    try { await _googleSignIn.signOut(); } catch (_) {}
  }

  // Create merchant account as admin without signing out current admin session.
  Future<String> createMerchantAccountByAdmin({
    required String ownerName,
    required String email,
    required String phoneNumber,
    required String password,
    required String businessName,
    String? businessAddress,
    String? city,
  }) async {
    final adminUser = _auth.currentUser;
    if (adminUser == null) {
      throw Exception('Admin must be logged in to create merchant account.');
    }

    final adminRoleSnap = await _database.ref('users/${adminUser.uid}/role').get();
    if (!adminRoleSnap.exists || adminRoleSnap.value?.toString() != 'admin') {
      throw Exception('Only admin can create merchant accounts.');
    }
    await CityScopeService.ensureLoaded();
    final selectedCity = CityScopeService.normalizeCity(
      city ?? CityScopeService.currentCity,
    );

    final appName = 'merchant_creator_${DateTime.now().millisecondsSinceEpoch}';
    FirebaseApp? secondaryApp;
    try {
      secondaryApp = await Firebase.initializeApp(
        name: appName,
        options: DefaultFirebaseOptions.currentPlatform,
      );

      final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
      final userCredential = await secondaryAuth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );

      final merchantUser = userCredential.user;
      if (merchantUser == null) {
        throw Exception('Merchant account could not be created.');
      }

      await merchantUser.updateDisplayName(ownerName.trim());

      final uid = merchantUser.uid;
      final now = DateTime.now().toIso8601String();

      final userData = <String, dynamic>{
        'id': uid,
        'name': ownerName.trim(),
        'email': email.trim(),
        'phoneNumber': phoneNumber.trim(),
        'role': 'merchant',
        'userCity': selectedCity,
        'userCityAssignedAt': ServerValue.timestamp,
        'orders': 0,
        'isBanned': false,
        'banned': false,
        'isMerchantActive': true,
        'createdAt': now,
        'createdByAdmin': adminUser.uid,
      };

      final merchantProfile = <String, dynamic>{
        'uid': uid,
        'ownerName': ownerName.trim(),
        'email': email.trim(),
        'phoneNumber': phoneNumber.trim(),
        'businessName': businessName.trim(),
        'businessAddress': (businessAddress ?? '').trim(),
        'city': selectedCity,
        'isActive': true,
        'permissions': defaultMerchantPermissions(),
        'createdAt': now,
        'createdByAdmin': adminUser.uid,
        'assignedShopIds': <String, bool>{},
      };

      await _database.ref('users/$uid').set(userData);
      await _database.ref('merchant_profiles/$uid').set(merchantProfile);

      await secondaryAuth.signOut();
      return uid;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        throw Exception('This email is already in use.');
      }
      throw Exception(e.message ?? 'Unable to create merchant account.');
    } finally {
      try {
        await secondaryApp?.delete();
      } catch (_) {}
    }
  }

  Future<String> createShopLinkedMerchantByAdmin({
    required String shopId,
    required String ownerName,
    required String email,
    required String phoneNumber,
    required String password,
    String? businessAddress,
    String? city,
  }) async {
    await _ensureCurrentUserIsAdmin();
    await CityScopeService.ensureLoaded();

    final selectedCity = CityScopeService.normalizeCity(
      city ?? CityScopeService.currentCity,
    );

    final shop = await _getShopDataOrThrow(shopId, city: selectedCity);
    final existingMerchantId = (shop['merchantId'] ?? '').toString();
    if (existingMerchantId.isNotEmpty) {
      throw Exception('This shop already has a merchant account.');
    }

    final shopName = (shop['name'] ?? 'Shop').toString().trim();
    final resolvedAddress = (businessAddress ?? shop['address'] ?? '').toString().trim();

    final uid = await createMerchantAccountByAdmin(
      ownerName: ownerName,
      email: email,
      phoneNumber: phoneNumber,
      password: password,
      businessName: shopName,
      businessAddress: resolvedAddress,
      city: selectedCity,
    );

    final now = DateTime.now().millisecondsSinceEpoch;

    final profileUpdates = <String, dynamic>{
      'primaryShopId': shopId,
      'businessName': shopName,
      'businessAddress': resolvedAddress,
      'assignedShopIds/$shopId': true,
      'updatedAt': now,
    };

    await Future.wait([
      _database.ref('merchant_profiles/$uid').update(profileUpdates),
      _database
          .ref(_tenantPath('merchant_profiles/$uid', city: selectedCity))
          .update(profileUpdates),
    ]);

    await _database.ref('users/$uid').update({
      'shopId': shopId,
      'updatedAt': now,
    });

    await _database.ref(_tenantPath('shops/$shopId', city: selectedCity)).update({
      'merchantId': uid,
      'merchantName': ownerName.trim(),
      'merchantEmail': email.trim(),
      'merchantPhone': phoneNumber.trim(),
      'hasAccount': true,
      _merchantCredPath: {
        'email': email.trim(),
        'password': password,
        'ownerName': ownerName.trim(),
        'updatedAt': now,
      },
      'merchantLinkedAt': now,
    });

    return uid;
  }

  Future<void> changeShopMerchantPasswordByAdmin({
    required String shopId,
    required String newPassword,
    String? city,
  }) async {
    await _ensureCurrentUserIsAdmin();
    await CityScopeService.ensureLoaded();
    final selectedCity = CityScopeService.normalizeCity(
      city ?? CityScopeService.currentCity,
    );
    if (newPassword.trim().length < 6) {
      throw Exception('Password must be at least 6 characters long.');
    }

    final shop = await _getShopDataOrThrow(shopId, city: selectedCity);
    final merchantId = (shop['merchantId'] ?? '').toString();
    if (merchantId.isEmpty) {
      throw Exception('No merchant account linked with this shop.');
    }

    final email = (shop['merchantEmail'] ?? '').toString().trim();
    if (email.isEmpty) {
      throw Exception('Merchant email is missing for this shop.');
    }

    final creds = shop[_merchantCredPath] is Map
        ? Map<String, dynamic>.from(shop[_merchantCredPath] as Map)
        : <String, dynamic>{};
    final currentPassword = (creds['password'] ?? '').toString();

    if (currentPassword.isEmpty) {
      throw Exception('Current merchant password is not stored. Delete and recreate merchant account.');
    }

    final appName = 'merchant_pwd_${DateTime.now().millisecondsSinceEpoch}';
    FirebaseApp? secondaryApp;
    try {
      secondaryApp = await Firebase.initializeApp(
        name: appName,
        options: DefaultFirebaseOptions.currentPlatform,
      );

      final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
      await secondaryAuth.signInWithEmailAndPassword(
        email: email,
        password: currentPassword,
      );

      final merchantUser = secondaryAuth.currentUser;
      if (merchantUser == null) {
        throw Exception('Unable to access merchant auth account.');
      }

      await merchantUser.updatePassword(newPassword.trim());
      await secondaryAuth.signOut();

      final now = DateTime.now().millisecondsSinceEpoch;
      await _database
          .ref('${_tenantPath('shops/$shopId', city: selectedCity)}/$_merchantCredPath')
          .update({
        'email': email,
        'password': newPassword.trim(),
        'ownerName': (creds['ownerName'] ?? shop['merchantName'] ?? '').toString(),
        'updatedAt': now,
      });

      final profileUpdates = <String, dynamic>{
        'updatedAt': now,
        'passwordChangedAt': now,
      };
      await Future.wait([
        _database.ref('merchant_profiles/$merchantId').update(profileUpdates),
        _database
            .ref(_tenantPath('merchant_profiles/$merchantId', city: selectedCity))
            .update(profileUpdates),
      ]);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        throw Exception('Stored merchant password is outdated. Delete and recreate merchant account.');
      }
      throw Exception(e.message ?? 'Unable to change merchant password.');
    } finally {
      try {
        await secondaryApp?.delete();
      } catch (_) {}
    }
  }

  Future<void> deleteShopMerchantByAdmin({
    required String shopId,
    String? city,
  }) async {
    await _ensureCurrentUserIsAdmin();
    await CityScopeService.ensureLoaded();

    final selectedCity = CityScopeService.normalizeCity(
      city ?? CityScopeService.currentCity,
    );

    final shop = await _getShopDataOrThrow(shopId, city: selectedCity);
    final merchantId = (shop['merchantId'] ?? '').toString();
    if (merchantId.isEmpty) {
      throw Exception('No merchant account linked with this shop.');
    }

    final email = (shop['merchantEmail'] ?? '').toString().trim();
    final creds = shop[_merchantCredPath] is Map
        ? Map<String, dynamic>.from(shop[_merchantCredPath] as Map)
        : <String, dynamic>{};
    final password = (creds['password'] ?? '').toString();

    if (email.isEmpty || password.isEmpty) {
      throw Exception('Merchant credentials are missing. Set password first, then delete account.');
    }

    final appName = 'merchant_delete_${DateTime.now().millisecondsSinceEpoch}';
    FirebaseApp? secondaryApp;
    try {
      secondaryApp = await Firebase.initializeApp(
        name: appName,
        options: DefaultFirebaseOptions.currentPlatform,
      );

      final secondaryAuth = FirebaseAuth.instanceFor(app: secondaryApp);
      await secondaryAuth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      final merchantUser = secondaryAuth.currentUser;
      if (merchantUser == null) {
        throw Exception('Unable to access merchant auth account.');
      }
      await merchantUser.delete();
      await secondaryAuth.signOut();
    } on FirebaseAuthException catch (e) {
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        throw Exception('Stored merchant password is outdated. Delete and recreate merchant account manually.');
      }
      throw Exception(e.message ?? 'Unable to delete merchant auth account.');
    } finally {
      try {
        await secondaryApp?.delete();
      } catch (_) {}
    }

    await _database.ref('users/$merchantId').remove();
    await Future.wait([
      _database.ref('merchant_profiles/$merchantId').remove(),
      _database
          .ref(_tenantPath('merchant_profiles/$merchantId', city: selectedCity))
          .remove(),
    ]);

    final shopsSnap = await _database.ref(_tenantPath('shops', city: selectedCity)).get();
    if (shopsSnap.exists && shopsSnap.value is Map) {
      final shopsMap = shopsSnap.value as Map<dynamic, dynamic>;
      for (final entry in shopsMap.entries) {
        final sid = entry.key.toString();
        if (entry.value is! Map) continue;
        final s = Map<String, dynamic>.from(entry.value as Map);
        if ((s['merchantId'] ?? '').toString() == merchantId) {
          await _database.ref(_tenantPath('shops/$sid', city: selectedCity)).update({
            'merchantId': '',
            'merchantName': '',
            'merchantEmail': '',
            'merchantPhone': '',
            'hasAccount': false,
            _merchantCredPath: {},
            'merchantLinkedAt': null,
          });
        }
      }
    }
  }
}
