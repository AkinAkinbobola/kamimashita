import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Minimal, compatible ThemeData for a clean and minimal app style.
class AppTheme {
  AppTheme._();

  static ThemeData get clean {
    final baseText = GoogleFonts.dmSansTextTheme(ThemeData.dark().textTheme);
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0E0F12),
      primaryColor: const Color(0xFF7AA2F7),
      cardColor: const Color(0xFF111216),
      textTheme: baseText,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFF1B1C20),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }
}
