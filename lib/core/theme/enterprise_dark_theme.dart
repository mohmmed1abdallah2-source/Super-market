import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Defines the fixed dark visual language used throughout the supermarket ERP.
class EnterpriseDarkTheme {
  EnterpriseDarkTheme._();

  static const Color background = Color(0xFF121212);
  static const Color surface = Color(0xFF1E1E1E);
  static const Color field = Color(0xFF262626);
  static const Color outline = Color(0xFF333333);
  static const Color primary = Color(0xFF4DB6AC);
  static const Color success = Color(0xFF66BB6A);
  static const Color warning = Color(0xFFFFB74D);
  static const Color danger = Color(0xFFEF5350);
  static const Color muted = Color(0xFF9E9E9E);

  /// Builds the Material 3 dark theme with the project's RTL-friendly colors.
  static ThemeData build() {
    final scheme = const ColorScheme.dark(
      primary: primary,
      secondary: success,
      surface: surface,
      error: danger,
      onPrimary: background,
      onSecondary: background,
      onSurface: Colors.white,
      onError: Colors.white,
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      cardColor: surface,
      dividerColor: outline,
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: Colors.white,
        centerTitle: false,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: field,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: outline),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: background,
          minimumSize: const Size(48, 46),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      textTheme: const TextTheme(
        headlineSmall: TextStyle(fontWeight: FontWeight.w700),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(height: 1.45),
      ),
    );
  }
}

/// Formats monetary values consistently without floating-point currency arithmetic.
class MoneyFormatter {
  MoneyFormatter({this.locale = 'ar', this.currencySymbol = 'ر.ي'})
      : _format = NumberFormat('#,##0.00', locale);

  final String locale;
  final String currencySymbol;
  final NumberFormat _format;

  /// Returns a localized display string; calculations must remain outside formatting.
  String format(num amount, {bool includeCurrency = true}) {
    final value = _format.format(amount);
    return includeCurrency ? '$value $currencySymbol' : value;
  }

  /// Parses a user-entered decimal after removing grouping separators.
  double? parse(String input) {
    final normalized = input
        .trim()
        .replaceAll(',', '')
        .replaceAll('٬', '')
        .replaceAll('٫', '.');
    return double.tryParse(normalized);
  }
}