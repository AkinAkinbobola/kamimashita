import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  AppTheme._();

  static const background = Color(0xFF0C0A0B);
  static const surface = Color(0xFF111014);
  static const surfaceRaised = Color(0xFF161214);
  static const border = Color(0xFF1E1A1C);
  static const borderSubtle = Color(0xFF161214);
  static const crimson = Color(0xFF00E5FF);
  static const crimsonDim = Color(0xFF00BCD4);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFAAAAAA);
  static const textMuted = Color(0xFFAAAAAA);

  static ThemeData get crimsonInk {
    final baseText = GoogleFonts.interTextTheme(ThemeData.dark().textTheme);
    final clickableMouseCursor = WidgetStateProperty.resolveWith<MouseCursor>((
      states,
    ) {
      if (states.contains(WidgetState.disabled)) {
        return SystemMouseCursors.basic;
      }
      return SystemMouseCursors.click;
    });

    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      primaryColor: crimson,
      cardColor: surface,
      dividerColor: border,
      textTheme: baseText.copyWith(
        displayLarge: baseText.displayLarge?.copyWith(color: textPrimary),
        displayMedium: baseText.displayMedium?.copyWith(color: textPrimary),
        titleLarge: baseText.titleLarge?.copyWith(
          color: textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.5,
        ),
        titleMedium: baseText.titleMedium?.copyWith(
          color: textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
        bodyLarge: baseText.bodyLarge?.copyWith(
          color: textPrimary,
          fontSize: 14,
        ),
        bodyMedium: baseText.bodyMedium?.copyWith(
          color: textSecondary,
          fontSize: 13,
        ),
        bodySmall: baseText.bodySmall?.copyWith(color: textMuted, fontSize: 11),
        labelSmall: baseText.labelSmall?.copyWith(
          color: textMuted,
          fontSize: 10,
          letterSpacing: 0.08,
        ),
      ),
      colorScheme: const ColorScheme.dark(
        primary: crimson,
        secondary: crimsonDim,
        surface: surface,
        onPrimary: textPrimary,
        onSecondary: textPrimary,
        onSurface: textPrimary,
        error: Color(0xFFE57373),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: const TextStyle(color: textMuted, fontSize: 13),
        prefixIconColor: textMuted,
        suffixIconColor: textMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: border, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: border, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: crimson, width: 0.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: crimson,
        disabledColor: surface,
        labelStyle: const TextStyle(color: textSecondary, fontSize: 11),
        secondaryLabelStyle: const TextStyle(color: textPrimary, fontSize: 11),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: const BorderSide(color: border, width: 0.5),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        toolbarHeight: 52,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: baseText.titleLarge?.copyWith(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
        iconTheme: const IconThemeData(color: textSecondary, size: 20),
        shape: const Border(bottom: BorderSide(color: border, width: 0.5)),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: surfaceRaised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(6)),
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
      dropdownMenuTheme: const DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(surfaceRaised),
          surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          side: WidgetStatePropertyAll(
            BorderSide(color: borderSubtle, width: 0.5),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(6)),
            ),
          ),
        ),
      ),
      scrollbarTheme: const ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(textMuted),
        thickness: WidgetStatePropertyAll(3),
        radius: Radius.circular(2),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(mouseCursor: clickableMouseCursor),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(mouseCursor: clickableMouseCursor),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(mouseCursor: clickableMouseCursor),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(mouseCursor: clickableMouseCursor),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(mouseCursor: clickableMouseCursor),
      ),
    );
  }
}
