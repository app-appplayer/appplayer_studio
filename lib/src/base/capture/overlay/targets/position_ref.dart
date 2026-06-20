/// Resolve a [PositionRef] to a concrete [Rect] in the shell's
/// coordinate space. Used by every painter that targets a UI element.
///
/// Resolution strategies:
/// - `abs` → straight rect from x/y/w/h
/// - `screen` → known shell regions (full / body / left_panel) — the
///   host computes these from the captureRootKey's RenderObject size
/// - `element` → host bridge looks the element up in the layout-snapshot
///   cache (delegates to `chromeBridge.captureLayoutSnapshot`)
/// - `metadata` → walks the render tree for `MetaData(key: ...)`
/// - `widget` → path-based lookup (Phase 2, unimplemented)
///
/// Returns `null` when resolution fails so the painter can skip
/// drawing rather than crashing.
library;

import 'dart:ui';

import '../overlay_models.dart';

typedef RectResolver = Rect? Function(PositionRef ref);

/// Resolve an abs ref to a rect. Trivial — kept here so painters get a
/// uniform API even for the cheapest case.
Rect? resolveAbs(PositionRef ref) {
  final x = ref.x;
  final y = ref.y;
  if (x == null || y == null) return null;
  final w = ref.w ?? 0;
  final h = ref.h ?? 0;
  return Rect.fromLTWH(x, y, w, h);
}
