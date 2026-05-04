import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Minimal, custom ThemeData for a clean and minimal app style.
/// This avoids Material 3 color scheme defaults and builds the theme from explicit values.
class AppTheme {
  AppTheme._();

  static ThemeData get clean {
    // Core palette
    const background = Color(0xFF0E0F12); // very dark
    const surface = Color(0xFF111216);
    const subtle = Color(0xFF1B1C20);
    const mutedText = Color(0xFFBFC5CC);
    const accent = Color(0xFF7AA2F7); // soft blue accent

    final baseText = GoogleFonts.dmSansTextTheme(const TextTheme(
      bodySmall: TextStyle(color: mutedText, fontSize: 12),
      bodyMedium: TextStyle(color: mutedText, fontSize: 14),
      bodyLarge: TextStyle(color: mutedText, fontSize: 16),
      titleLarge: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
      labelLarge: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500),
    ));

    return ThemeData(
      // Do not opt into Material 3; keep classic theming behavior
      useMaterial3: false,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      backgroundColor: background,
      canvasColor: background,
      cardColor: surface,
      // Primary colors (explicit, not via ColorScheme)
      primaryColor: accent,
      hintColor: mutedText,

      // Typography
      textTheme: baseText,
      primaryTextTheme: baseText,
      // AppBar
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: baseText.titleLarge?.copyWith(color: Colors.white),
        iconTheme: const IconThemeData(color: Colors.white70),
        toolbarTextStyle: baseText.bodyMedium,
      ),

      // Cards and surfaces
      cardTheme: CardTheme(
        color: surface,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14.0)),
      ),

      // Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          textStyle: baseText.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: mutedText, textStyle: baseText.bodyMedium),
      ),

      // Inputs
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: subtle,
        hintStyle: TextStyle(color: mutedText.withOpacity(0.7)),
        border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      ),

      // Chips
      chipTheme: ChipThemeData(
        backgroundColor: subtle,
        selectedColor: accent.withOpacity(0.14),
        labelStyle: baseText.bodySmall!.copyWith(color: Colors.white70),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        secondaryLabelStyle: baseText.bodySmall!.copyWith(color: Colors.white70),
        brightness: Brightness.dark,
      ),

      // Icons
      iconTheme: const IconThemeData(color: Colors.white70, size: 20),

      // Bottom app bar / navigation
      bottomAppBarTheme: const BottomAppBarTheme(color: Color(0x00111116)),

      // Dialogs
      dialogTheme: DialogTheme(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        titleTextStyle: baseText.titleLarge?.copyWith(color: Colors.white),
        contentTextStyle: baseText.bodyMedium,
      ),

      // Misc
      dividerColor: Colors.white10,
      focusColor: accent.withOpacity(0.2),
      hoverColor: Colors.white10,
    );
  }
}
