import 'package:flutter/material.dart';

class RaveStreamerTheme {
  final Color primary;
  final Color secondary;
  final Color scaffoldBackground;
  final Color cardColor;
  final List<Color> bgGradient;

  const RaveStreamerTheme({
    required this.primary,
    required this.secondary,
    required this.scaffoldBackground,
    required this.cardColor,
    required this.bgGradient,
  });
}

const Map<String, RaveStreamerTheme> appThemes = {
  'Dark': RaveStreamerTheme(
    primary: Color(0xFF6C63FF),
    secondary: Color(0xFF00F2FE),
    scaffoldBackground: Color(0xFF0D0B14),
    cardColor: Color(0xFF161426),
    bgGradient: [Color(0xFF0F0C1B), Color(0xFF201A30), Color(0xFF0D0B14)],
  ),
  'Neon Cyan': RaveStreamerTheme(
    primary: Color(0xFF00F2FE),
    secondary: Color(0xFF9B51E0),
    scaffoldBackground: Color(0xFF071215),
    cardColor: Color(0xFF0C2126),
    bgGradient: [Color(0xFF08181C), Color(0xFF0B2C33), Color(0xFF071215)],
  ),
  'Sunset Gold': RaveStreamerTheme(
    primary: Color(0xFFFF9F43),
    secondary: Color(0xFFFF5252),
    scaffoldBackground: Color(0xFF1B0F0F),
    cardColor: Color(0xFF2E1616),
    bgGradient: [Color(0xFF1B0F0F), Color(0xFF381414), Color(0xFF120A0A)],
  ),
  'Retro Purple': RaveStreamerTheme(
    primary: Color(0xFFE84393),
    secondary: Color(0xFF6C63FF),
    scaffoldBackground: Color(0xFF130F1A),
    cardColor: Color(0xFF241635),
    bgGradient: [Color(0xFF130F1A), Color(0xFF2D144A), Color(0xFF0E0B13)],
  ),
};
