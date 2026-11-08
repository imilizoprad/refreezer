import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

/// Design tokens: OBSIDIAN × AUDIOPHILE × EDITORIAL.
///
/// The tokens are derived from the ambient [Theme] (brightness + user accent colour) instead of
/// replacing the app theme, so every existing screen keeps working and the user's colour choice
/// stays authoritative. Use `RfTokens.of(context)` in new/updated widgets.
@immutable
class RfTokens {
  const RfTokens({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.scrim,
    required this.hairline,
    required this.hairlineStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.danger,
  });

  final Brightness brightness;

  /// Page background (obsidian in dark mode, warm paper in light mode).
  final Color background;

  /// Cards, rows, sheets.
  final Color surface;

  /// Raised/selected surface.
  final Color surfaceHigh;

  /// Dialog barrier.
  final Color scrim;

  /// 1px separators.
  final Color hairline;
  final Color hairlineStrong;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// User accent, used sparingly (rules, active markers, single primary action).
  final Color accent;
  final Color accentSoft;

  final Color success;
  final Color warning;
  final Color danger;

  bool get isDark => brightness == Brightness.dark;

  // --- spacing scale (4pt grid) ---
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;
  static const double s7 = 48;

  // --- radii: editorial, not everything is a pill ---
  static const double rXs = 3;
  static const double rSm = 6;
  static const double rMd = 10;
  static const double rLg = 16;

  // --- layout ---
  static const double gutter = 20;
  static const double rowMinHeight = 68;
  static const double artworkSm = 44;
  static const double artworkMd = 56;

  static const Duration fast = Duration(milliseconds: 140);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);

  static const Curve emphasis = Curves.easeOutCubic;

  /// Respect the platform "remove animations" setting.
  static bool reducedMotion(BuildContext context) {
    final MediaQueryData? data = MediaQuery.maybeOf(context);
    return data?.disableAnimations ?? false;
  }

  static Duration motion(BuildContext context, Duration base) =>
      reducedMotion(context) ? Duration.zero : base;

  static RfTokens of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool dark = theme.brightness == Brightness.dark;
    final Color accent = theme.colorScheme.primary;
    if (dark) {
      return RfTokens(
        brightness: Brightness.dark,
        background: const Color(0xFF0A0A0B),
        surface: const Color(0xFF121214),
        surfaceHigh: const Color(0xFF1B1B1F),
        scrim: const Color(0xCC000000),
        hairline: const Color(0x14FFFFFF),
        hairlineStrong: const Color(0x26FFFFFF),
        textPrimary: const Color(0xFFF2F1EE),
        textSecondary: const Color(0xFFA8A6A1),
        textTertiary: const Color(0xFF6E6C68),
        accent: accent,
        accentSoft: Color.alphaBlend(accent.withOpacity(0.18), const Color(0xFF121214)),
        success: const Color(0xFF7FB98A),
        warning: const Color(0xFFD8B26A),
        danger: const Color(0xFFD97B6C),
      );
    }
    return RfTokens(
      brightness: Brightness.light,
      background: const Color(0xFFF6F4F0),
      surface: const Color(0xFFFFFFFF),
      surfaceHigh: const Color(0xFFEFEBE4),
      scrim: const Color(0x8A000000),
      hairline: const Color(0x1A000000),
      hairlineStrong: const Color(0x33000000),
      textPrimary: const Color(0xFF15140F),
      textSecondary: const Color(0xFF5C5A53),
      textTertiary: const Color(0xFF8B887F),
      accent: accent,
      accentSoft: Color.alphaBlend(accent.withOpacity(0.12), const Color(0xFFFFFFFF)),
      success: const Color(0xFF3F7A4C),
      warning: const Color(0xFF8A6218),
      danger: const Color(0xFF9B3B2C),
    );
  }

  // --- typography ---
  // Editorial hierarchy: a tight display face, quiet body, and small-caps labels.

  TextStyle get display => TextStyle(
        fontSize: 30,
        height: 1.12,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.6,
        color: textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  TextStyle get title => TextStyle(
        fontSize: 19,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: textPrimary,
      );

  TextStyle get rowTitle => TextStyle(
        fontSize: 15,
        height: 1.3,
        fontWeight: FontWeight.w500,
        color: textPrimary,
      );

  TextStyle get body => TextStyle(
        fontSize: 14,
        height: 1.45,
        color: textSecondary,
      );

  TextStyle get caption => TextStyle(
        fontSize: 12,
        height: 1.35,
        color: textSecondary,
      );

  /// Uppercase micro-label used above sections ("QUEUE", "FINISHED").
  TextStyle get overline => TextStyle(
        fontSize: 10.5,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.7,
        color: textTertiary,
      );

  /// Tabular numbers for sizes, speeds and durations.
  TextStyle get numeric => TextStyle(
        fontSize: 12,
        height: 1.3,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
        color: textSecondary,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}
