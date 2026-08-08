import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:ghartek_flutter_app/config/app_env.dart';
import 'package:ghartek_flutter_app/services/db/app_database.dart';
import 'firebase_options.dart';
import 'pages/splash_screen.dart';
import 'services/background_timer_service.dart';
import 'services/notification_service.dart';
import 'services/theme_service.dart';
import 'services/analytics_service.dart';
import 'services/session_service.dart';
import 'services/db/app_db_bootstrap.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  // Initialize Firebase with error handling
  try {
    if (Firebase.apps.isEmpty) {
      if (kIsWeb) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      } else {
        try {
          await Firebase.initializeApp();
        } on FirebaseException {
          await Firebase.initializeApp(
            options: DefaultFirebaseOptions.currentPlatform,
          );
        }
      }
    }

    // Initialize secondary app for ratings
    bool isRatingsAppInitialized = false;
    for (var app in Firebase.apps) {
      if (app.name == 'ratingsApp') {
        isRatingsAppInitialized = true;
        break;
      }
    }

    if (!isRatingsAppInitialized) {
      await Firebase.initializeApp(
        name: 'ratingsApp',
        options: FirebaseOptions(
          apiKey: AppEnv.ratingsFirebaseApiKey,
          appId: AppEnv.ratingsFirebaseAppId,
          messagingSenderId: AppEnv.ratingsFirebaseMessagingSenderId,
          projectId: AppEnv.ratingsFirebaseProjectId,
          databaseURL: AppEnv.ratingsFirebaseDatabaseUrl,
        ),
      );
    }

    if (!kIsWeb) {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    }

    // Start background timer service
    BackgroundTimerService().startBackgroundTracking();

    // Initialize session tracking
    SessionService().init();

    debugPrint('Firebase initialized successfully');
  } catch (e) {
    debugPrint('Firebase initialization error: $e');
  }

  // PostgreSQL backend (auto-fallback to Firebase RTDB if backend unreachable).
  await configureAppDatabase();

  // Initialize Mixpanel Analytics
  await AnalyticsService.init();
  AnalyticsService.appOpen();
  AnalyticsService.sessionStart();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, mode, __) => MaterialApp(
        navigatorKey: NotificationService.navigatorKey,
        title: 'GharTek',
        debugShowCheckedModeBanner: false,
        themeMode: mode,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFFF6B00),
            brightness: Brightness.light,
            primary: const Color(0xFFFF6B00),
            secondary: const Color(0xFFFF6B00),
            surface: const Color(0xFFFCFAF8),
          ),
          useMaterial3: true,
          fontFamily: 'Roboto',
          scaffoldBackgroundColor: Colors.white,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
            backgroundColor: Color(0xFFFF6B00),
            foregroundColor: Colors.white,
          ),
          cardTheme: CardThemeData(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            color: Colors.white,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B00),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFF6B00),
              side: const BorderSide(color: Color(0xFFFF6B00)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFFF6B00),
            brightness: Brightness.dark,
            primary: const Color(0xFFFF6B00),
            secondary: const Color(0xFFFF6B00),
          ),
          useMaterial3: true,
          fontFamily: 'Roboto',
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
            backgroundColor: Color(0xFFFF6B00),
            foregroundColor: Colors.white,
          ),
          cardTheme: CardThemeData(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        builder: (context, child) => child ?? const SizedBox(),
        home: const SplashScreen(),
      ),
    );
  }
}
