import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nym_bar/theme.dart';
import 'package:nym_bar/screens/webview_screen.dart';
import 'package:nym_bar/services/notification_service.dart';
import 'package:nym_bar/services/firebase_messaging_service.dart';
import 'package:nym_bar/utils/webview_platform_initializer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureWebViewPlatform();
  
  // Initialize local notifications (works on all devices without Google Play Services)
  await NotificationService().initialize();
  
  // Initialize Firebase Messaging placeholder (no actual Firebase dependency)
  await FirebaseMessagingService().initialize();
  
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
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
