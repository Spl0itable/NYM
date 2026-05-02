import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nym_bar/theme.dart';
import 'package:nym_bar/screens/webview_screen.dart';
import 'package:nym_bar/services/notification_service.dart';
import 'package:nym_bar/utils/webview_platform_initializer.dart';

// App theme colors
const Color kDarkBackgroundColor = Color(0xFF0A0A0F);
const Color kLightBackgroundColor = Color(0xFFF5F5F2);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureWebViewPlatform();
  
  // Initialize local notifications (works on all devices without Google Play Services)
  await NotificationService().initialize();
  
  // Set edge-to-edge display mode for immersive experience
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  
  // Initial system UI style will be updated dynamically based on theme
  // Start with system preference
  final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
  final isLight = brightness == Brightness.light;
  final bgColor = isLight ? kLightBackgroundColor : kDarkBackgroundColor;
  
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: bgColor,
    statusBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
    statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
    systemNavigationBarColor: bgColor,
    systemNavigationBarIconBrightness: isLight ? Brightness.dark : Brightness.light,
    systemNavigationBarDividerColor: bgColor,
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
      themeMode: ThemeMode.system, // Respond to system light/dark mode
      home: const WebViewScreen(),
    );
  }
}
