import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class LightModeColors {
  static const lightPrimary = Color(0xFF00FF41);
  static const lightOnPrimary = Color(0xFF000000);
  static const lightPrimaryContainer = Color(0xFFE8F5E9);
  static const lightOnPrimaryContainer = Color(0xFF003D14);
  static const lightSecondary = Color(0xFF1A1A1A);
  static const lightOnSecondary = Color(0xFF00FF41);
  static const lightTertiary = Color(0xFF00C853);
  static const lightOnTertiary = Color(0xFF000000);
  static const lightError = Color(0xFFD32F2F);
  static const lightOnError = Color(0xFFFFFFFF);
  static const lightErrorContainer = Color(0xFFFFCDD2);
  static const lightOnErrorContainer = Color(0xFF5F0000);
  static const lightInversePrimary = Color(0xFF69F0AE);
  static const lightShadow = Color(0xFF000000);
  static const lightSurface = Color(0xFFF5F5F5);
  static const lightOnSurface = Color(0xFF0D0D0D);
  static const lightAppBarBackground = Color(0xFF1A1A1A);
}

class DarkModeColors {
  static const darkPrimary = Color(0xFF00FF41);
  static const darkOnPrimary = Color(0xFF000000);
  static const darkPrimaryContainer = Color(0xFF003D14);
  static const darkOnPrimaryContainer = Color(0xFF69F0AE);
  static const darkSecondary = Color(0xFF69F0AE);
  static const darkOnSecondary = Color(0xFF0D0D0D);
  static const darkTertiary = Color(0xFF00C853);
  static const darkOnTertiary = Color(0xFF000000);
  static const darkError = Color(0xFFEF5350);
  static const darkOnError = Color(0xFF000000);
  static const darkErrorContainer = Color(0xFF5F0000);
  static const darkOnErrorContainer = Color(0xFFFFCDD2);
  static const darkInversePrimary = Color(0xFF00C853);
  static const darkShadow = Color(0xFF000000);
  static const darkSurface = Color(0xFF0D0D0D);
  static const darkOnSurface = Color(0xFF00FF41);
  static const darkAppBarBackground = Color(0xFF000000);
}

class FontSizes {
  static const double displayLarge = 57.0;
  static const double displayMedium = 45.0;
  static const double displaySmall = 36.0;
  static const double headlineLarge = 32.0;
  static const double headlineMedium = 24.0;
  static const double headlineSmall = 22.0;
  static const double titleLarge = 22.0;
  static const double titleMedium = 18.0;
  static const double titleSmall = 16.0;
  static const double labelLarge = 16.0;
  static const double labelMedium = 14.0;
  static const double labelSmall = 12.0;
  static const double bodyLarge = 16.0;
  static const double bodyMedium = 14.0;
  static const double bodySmall = 12.0;
}

ThemeData get lightTheme => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.light(
    primary: LightModeColors.lightPrimary,
    onPrimary: LightModeColors.lightOnPrimary,
    primaryContainer: LightModeColors.lightPrimaryContainer,
    onPrimaryContainer: LightModeColors.lightOnPrimaryContainer,
    secondary: LightModeColors.lightSecondary,
    onSecondary: LightModeColors.lightOnSecondary,
    tertiary: LightModeColors.lightTertiary,
    onTertiary: LightModeColors.lightOnTertiary,
    error: LightModeColors.lightError,
    onError: LightModeColors.lightOnError,
    errorContainer: LightModeColors.lightErrorContainer,
    onErrorContainer: LightModeColors.lightOnErrorContainer,
    inversePrimary: LightModeColors.lightInversePrimary,
    shadow: LightModeColors.lightShadow,
    surface: LightModeColors.lightSurface,
    onSurface: LightModeColors.lightOnSurface,
  ),
  brightness: Brightness.light,
  appBarTheme: AppBarTheme(
    backgroundColor: LightModeColors.lightAppBarBackground,
    foregroundColor: LightModeColors.lightOnPrimaryContainer,
    elevation: 0,
  ),
  textTheme: TextTheme(
    displayLarge: GoogleFonts.orbitron(
      fontSize: FontSizes.displayLarge,
      fontWeight: FontWeight.bold,
    ),
    displayMedium: GoogleFonts.orbitron(
      fontSize: FontSizes.displayMedium,
      fontWeight: FontWeight.w600,
    ),
    displaySmall: GoogleFonts.orbitron(
      fontSize: FontSizes.displaySmall,
      fontWeight: FontWeight.w600,
    ),
    headlineLarge: GoogleFonts.rajdhani(
      fontSize: FontSizes.headlineLarge,
      fontWeight: FontWeight.bold,
    ),
    headlineMedium: GoogleFonts.rajdhani(
      fontSize: FontSizes.headlineMedium,
      fontWeight: FontWeight.w600,
    ),
    headlineSmall: GoogleFonts.rajdhani(
      fontSize: FontSizes.headlineSmall,
      fontWeight: FontWeight.bold,
    ),
    titleLarge: GoogleFonts.rajdhani(
      fontSize: FontSizes.titleLarge,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: GoogleFonts.rajdhani(
      fontSize: FontSizes.titleMedium,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: GoogleFonts.rajdhani(
      fontSize: FontSizes.titleSmall,
      fontWeight: FontWeight.w600,
    ),
    labelLarge: GoogleFonts.robotoMono(
      fontSize: FontSizes.labelLarge,
      fontWeight: FontWeight.w500,
    ),
    labelMedium: GoogleFonts.robotoMono(
      fontSize: FontSizes.labelMedium,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: GoogleFonts.robotoMono(
      fontSize: FontSizes.labelSmall,
      fontWeight: FontWeight.w500,
    ),
    bodyLarge: GoogleFonts.roboto(
      fontSize: FontSizes.bodyLarge,
      fontWeight: FontWeight.normal,
    ),
    bodyMedium: GoogleFonts.roboto(
      fontSize: FontSizes.bodyMedium,
      fontWeight: FontWeight.normal,
    ),
    bodySmall: GoogleFonts.roboto(
      fontSize: FontSizes.bodySmall,
      fontWeight: FontWeight.normal,
    ),
  ),
);

ThemeData get darkTheme => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.dark(
    primary: DarkModeColors.darkPrimary,
    onPrimary: DarkModeColors.darkOnPrimary,
    primaryContainer: DarkModeColors.darkPrimaryContainer,
    onPrimaryContainer: DarkModeColors.darkOnPrimaryContainer,
    secondary: DarkModeColors.darkSecondary,
    onSecondary: DarkModeColors.darkOnSecondary,
    tertiary: DarkModeColors.darkTertiary,
    onTertiary: DarkModeColors.darkOnTertiary,
    error: DarkModeColors.darkError,
    onError: DarkModeColors.darkOnError,
    errorContainer: DarkModeColors.darkErrorContainer,
    onErrorContainer: DarkModeColors.darkOnErrorContainer,
    inversePrimary: DarkModeColors.darkInversePrimary,
    shadow: DarkModeColors.darkShadow,
    surface: DarkModeColors.darkSurface,
    onSurface: DarkModeColors.darkOnSurface,
  ),
  brightness: Brightness.dark,
  appBarTheme: AppBarTheme(
    backgroundColor: DarkModeColors.darkAppBarBackground,
    foregroundColor: DarkModeColors.darkOnPrimaryContainer,
    elevation: 0,
  ),
  textTheme: TextTheme(
    displayLarge: GoogleFonts.orbitron(
      fontSize: FontSizes.displayLarge,
      fontWeight: FontWeight.bold,
    ),
    displayMedium: GoogleFonts.orbitron(
      fontSize: FontSizes.displayMedium,
      fontWeight: FontWeight.w600,
    ),
    displaySmall: GoogleFonts.orbitron(
      fontSize: FontSizes.displaySmall,
      fontWeight: FontWeight.w600,
    ),
    headlineLarge: GoogleFonts.rajdhani(
      fontSize: FontSizes.headlineLarge,
      fontWeight: FontWeight.bold,
    ),
    headlineMedium: GoogleFonts.rajdhani(
      fontSize: FontSizes.headlineMedium,
      fontWeight: FontWeight.w600,
    ),
    headlineSmall: GoogleFonts.rajdhani(
      fontSize: FontSizes.headlineSmall,
      fontWeight: FontWeight.bold,
    ),
    titleLarge: GoogleFonts.rajdhani(
      fontSize: FontSizes.titleLarge,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: GoogleFonts.rajdhani(
      fontSize: FontSizes.titleMedium,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: GoogleFonts.rajdhani(
      fontSize: FontSizes.titleSmall,
      fontWeight: FontWeight.w600,
    ),
    labelLarge: GoogleFonts.robotoMono(
      fontSize: FontSizes.labelLarge,
      fontWeight: FontWeight.w500,
    ),
    labelMedium: GoogleFonts.robotoMono(
      fontSize: FontSizes.labelMedium,
      fontWeight: FontWeight.w500,
    ),
    labelSmall: GoogleFonts.robotoMono(
      fontSize: FontSizes.labelSmall,
      fontWeight: FontWeight.w500,
    ),
    bodyLarge: GoogleFonts.roboto(
      fontSize: FontSizes.bodyLarge,
      fontWeight: FontWeight.normal,
    ),
    bodyMedium: GoogleFonts.roboto(
      fontSize: FontSizes.bodyMedium,
      fontWeight: FontWeight.normal,
    ),
    bodySmall: GoogleFonts.roboto(
      fontSize: FontSizes.bodySmall,
      fontWeight: FontWeight.normal,
    ),
  ),
);
