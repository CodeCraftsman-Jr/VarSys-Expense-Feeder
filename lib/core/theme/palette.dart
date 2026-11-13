import 'package:flutter/material.dart';

/// VarSys brand + semantic colors: zinc (dark) and slate (light) neutrals
/// with one blue accent, the same tokens as the VarSys web dashboards
/// (varsys-ui/dashboard/theme.css). Green, red and amber mean status only.
/// Category colors are tuned to stay distinct from each other on both the
/// dark and light surfaces.
abstract final class Palette {
  // Brand: VarSys blue. [brand] is the mid tone used for icons and tints on
  // either surface; the theme picks [brandLight] / [brandDark] for filled
  // controls so their labels keep enough contrast.
  static const brand = Color(0xFF3B82F6); // blue-500
  static const brandLight = Color(0xFF2563EB); // blue-600, white text
  static const brandDark = Color(0xFF60A5FA); // blue-400, dark text
  static const brandDeep = Color(0xFF1E3A8A); // blue-900, summary cards with white text
  static const brandNavy = Color(0xFF0B1220); // VarSys mark backdrop

  // Status
  static const green = Color(0xFF22C55E);
  static const red = Color(0xFFEF4444);
  static const amber = Color(0xFFF59E0B);

  // Dark surfaces (zinc)
  static const ink = Color(0xFF09090B);
  static const inkRaised = Color(0xFF18181B);
  static const inkHigh = Color(0xFF27272A);
  static const inkLine = Color(0xFF2F2F35);

  // Light surfaces (slate)
  static const paper = Color(0xFFF8FAFC);
  static const paperRaised = Color(0xFFFFFFFF);
  static const paperHigh = Color(0xFFF1F5F9);
  static const paperLine = Color(0xFFE2E8F0);

  static const income = green;
  static const expense = red;

  /// Validated categorical set (dataviz validator: lightness band, chroma,
  /// CVD + normal-vision separation, 3:1 contrast — passes on both surfaces).
  /// Order is fixed; colors follow the category, never its rank.
  static const categories = <Color>[
    Color(0xFF3B82F6), // blue
    Color(0xFFE0662C), // orange
    Color(0xFF14A37F), // teal
    Color(0xFFBD8400), // amber
    Color(0xFFD9559B), // pink
    Color(0xFF5E9E1A), // green
    Color(0xFF8577EE), // violet
    Color(0xFF1AA0C4), // cyan
  ];

  /// Catch-all buckets ("Other", transfers, people) — deliberately not a hue.
  static const neutral = Color(0xFF8A90A0);
}
