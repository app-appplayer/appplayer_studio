/// Shared helpers for overlay painters — color parsing, draw-on path
/// extraction, common Paint factories.
library;

import 'dart:ui';

import 'package:flutter/material.dart';

/// Default accent color (mint) — matches the chrome's `c.mint` token.
const Color kAccentMint = Color(0xff4ECDC4);
const Color kAccentRed = Color(0xffE74C3C);
const Color kAccentYellow = Color(0xffF1C40F);
const Color kAccentGreen = Color(0xff2ECC71);
const Color kBgScrim = Color(0xb0000000);
const Color kTextOnDark = Color(0xfff5f5f5);

Color colorFromProps(Map<String, dynamic> props, String key, Color fallback) {
  final v = props[key];
  if (v is String) {
    final s = v.replaceFirst('#', '');
    final hex = s.length == 6 ? 'ff$s' : s;
    if (hex.length == 8) {
      final n = int.tryParse(hex, radix: 16);
      if (n != null) return Color(n);
    }
  }
  return fallback;
}

double doubleProp(Map<String, dynamic> props, String key, double fallback) {
  final v = props[key];
  if (v is num) return v.toDouble();
  return fallback;
}

String stringProp(Map<String, dynamic> props, String key, String fallback) {
  final v = props[key];
  if (v is String) return v;
  return fallback;
}

int intProp(Map<String, dynamic> props, String key, int fallback) {
  final v = props[key];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return fallback;
}

/// Slice a [Path] to a fractional progress (0–1). Used by draw-on
/// animations — extracts the leading `progress * totalLength` worth
/// of the path so the line appears to draw itself.
Path slicePath(Path source, double progress) {
  final out = Path();
  final metrics = source.computeMetrics();
  for (final m in metrics) {
    final len = m.length * progress.clamp(0.0, 1.0);
    out.addPath(m.extractPath(0, len), Offset.zero);
  }
  return out;
}
