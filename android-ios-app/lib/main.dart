import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nym_bar/theme.dart';
import 'package:nym_bar/screens/webview_screen.dart';
import 'package:nym_bar/services/notification_service.dart';
import 'package:nym_bar/services/firebase_messaging_service.dart';
import 'package:nym_bar/utils/webview_platform_initializer.dart';

// App theme color to match the PWA dark mode default (--bg: #0a0a0f)
const Color kAppBackgroundColor = Color(0xFF0A0A0F);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureWebViewPlatform();
  
  // Initialize local notifications (works on all devices without Google Play Services)
  await NotificationService().initialize();
  
  // Initialize Firebase Messaging placeholder (no actual Firebase dependency)
  await FirebaseMessagingService().initialize();
  
  // Set edge-to-edge display mode for immersive experience
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  
  // Configure status bar and navigation bar to match the PWA theme
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    // Status bar (top)
    statusBarColor: kAppBackgroundColor,
    statusBarIconBrightness: Brightness.light, // Light icons on dark background
    statusBarBrightness: Brightness.dark, // iOS: dark status bar background
    // Navigation bar (bottom - Android)
    systemNavigationBarColor: kAppBackgroundColor,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: kAppBackgroundColor,
  ));
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nymchat',
      debugShowCheckedModeBanner: false,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.dark,
      home: const WebViewScreen(),
    );
  }
}
