/// Data models for the in-frame overlay markup layer.
///
/// Kept as plain value types so MCP push handlers can decode the JSON
/// straight into [OverlaySpec] without per-kind glue. The painters
/// downstream pattern-match on `kind` for rendering.
library;

import 'package:flutter/painting.dart' show Color;

/// Position reference — where to draw an overlay. Five canonical forms.
///
/// 1. **abs** `{x, y, w?, h?}` — absolute logical-pixel coords inside
///    the shell RepaintBoundary. Used for free-floating positions.
/// 2. **element** `"tool:addTool"` — element identifier the host
///    resolves via the chrome bridge (delegates to layout_snapshot).
///    Stable as the UI re-flows.
/// 3. **metadata** `"uid:counter-btn"` — `MetaData(key)` lookup on
///    DSL widgets.
/// 4. **widget** `"chat-input"` — widget-path lookup (Phase 2).
/// 5. **screen** `"window"|"body"|"left_panel"` — shell region tokens.
class PositionRef {
  PositionRef.abs(this.x, this.y, [this.w, this.h])
    : element = null,
      metadata = null,
      widget = null,
      screen = null;
  PositionRef.element(this.element)
    : x = null,
      y = null,
      w = null,
      h = null,
      metadata = null,
      widget = null,
      screen = null;
  PositionRef.metadata(this.metadata)
    : x = null,
      y = null,
      w = null,
      h = null,
      element = null,
      widget = null,
      screen = null;
  PositionRef.widget(this.widget)
    : x = null,
      y = null,
      w = null,
      h = null,
      element = null,
      metadata = null,
      screen = null;
  PositionRef.screen(this.screen)
    : x = null,
      y = null,
      w = null,
      h = null,
      element = null,
      metadata = null,
      widget = null;

  final double? x, y, w, h;
  final String? element;
  final String? metadata;
  final String? widget;
  final String? screen;

  factory PositionRef.fromJson(Object? raw) {
    if (raw is Map) {
      if (raw['abs'] is Map) {
        final m = (raw['abs'] as Map).cast<String, Object?>();
        return PositionRef.abs(
          (m['x'] as num).toDouble(),
          (m['y'] as num).toDouble(),
          (m['w'] as num?)?.toDouble(),
          (m['h'] as num?)?.toDouble(),
        );
      }
      if (raw['element'] is String) {
        return PositionRef.element(raw['element'] as String);
      }
      if (raw['metadata'] is String) {
        return PositionRef.metadata(raw['metadata'] as String);
      }
      if (raw['widget'] is String) {
        return PositionRef.widget(raw['widget'] as String);
      }
      if (raw['screen'] is String) {
        return PositionRef.screen(raw['screen'] as String);
      }
    }
    if (raw is String) {
      // Convenience — bare string interpreted as element id.
      return PositionRef.element(raw);
    }
    return PositionRef.screen('window');
  }

  Map<String, dynamic> toJson() {
    if (x != null) {
      return <String, dynamic>{
        'abs': <String, dynamic>{
          'x': x,
          'y': y,
          if (w != null) 'w': w,
          if (h != null) 'h': h,
        },
      };
    }
    if (element != null) return <String, dynamic>{'element': element};
    if (metadata != null) return <String, dynamic>{'metadata': metadata};
    if (widget != null) return <String, dynamic>{'widget': widget};
    if (screen != null) return <String, dynamic>{'screen': screen};
    return const <String, dynamic>{'screen': 'window'};
  }
}

/// Discriminated overlay kinds. Painters select on this enum.
enum OverlayKind {
  // structural / branding
  titleCard,
  subtitle,
  stepIndicator,
  watermark,
  transition,
  // pointing
  arrowPointer,
  speechBubble,
  pulseDot,
  connectorLine,
  // emphasis
  circleHighlight,
  checkMark,
  crossMark,
  highlighter,
  boxOutline,
  // lecture
  underline,
  strikethrough,
  bracket,
  numberedLabel,
  // media
  floatingIcon,
  floatingImage,
  slide,
  // motion
  cursor,
}

OverlayKind? overlayKindFromString(String s) {
  const map = <String, OverlayKind>{
    'title_card': OverlayKind.titleCard,
    'subtitle': OverlayKind.subtitle,
    'step_indicator': OverlayKind.stepIndicator,
    'watermark': OverlayKind.watermark,
    'transition': OverlayKind.transition,
    'arrow_pointer': OverlayKind.arrowPointer,
    'speech_bubble': OverlayKind.speechBubble,
    'pulse_dot': OverlayKind.pulseDot,
    'connector_line': OverlayKind.connectorLine,
    'circle_highlight': OverlayKind.circleHighlight,
    'check_mark': OverlayKind.checkMark,
    'cross_mark': OverlayKind.crossMark,
    'highlighter': OverlayKind.highlighter,
    'box_outline': OverlayKind.boxOutline,
    'underline': OverlayKind.underline,
    'strikethrough': OverlayKind.strikethrough,
    'bracket': OverlayKind.bracket,
    'numbered_label': OverlayKind.numberedLabel,
    'floating_icon': OverlayKind.floatingIcon,
    'floating_image': OverlayKind.floatingImage,
    'slide': OverlayKind.slide,
    'cursor': OverlayKind.cursor,
    // Natural-name aliases — authors (and LLMs composing scenarios) reach for
    // these everyday words; without the alias an `OverlaySpec.fromJson` throws
    // `unknown overlay kind` which the scenario engine SWALLOWS, silently
    // producing a video with no subtitle and no error. Mirror the alias
    // philosophy in `scenario_models.dart` (caption→label, trail→steps).
    'caption': OverlayKind.subtitle,
    'title': OverlayKind.titleCard,
    'step': OverlayKind.stepIndicator,
    'arrow': OverlayKind.arrowPointer,
    'highlight': OverlayKind.circleHighlight,
    'check': OverlayKind.checkMark,
    'box': OverlayKind.boxOutline,
    'presentation': OverlayKind.slide,
    'logo': OverlayKind.floatingImage,
    'image': OverlayKind.floatingImage,
    'icon': OverlayKind.floatingIcon,
    'mouse': OverlayKind.cursor,
    'pointer': OverlayKind.cursor,
  };
  return map[s];
}

String overlayKindToString(OverlayKind k) {
  switch (k) {
    case OverlayKind.titleCard:
      return 'title_card';
    case OverlayKind.subtitle:
      return 'subtitle';
    case OverlayKind.stepIndicator:
      return 'step_indicator';
    case OverlayKind.watermark:
      return 'watermark';
    case OverlayKind.transition:
      return 'transition';
    case OverlayKind.arrowPointer:
      return 'arrow_pointer';
    case OverlayKind.speechBubble:
      return 'speech_bubble';
    case OverlayKind.pulseDot:
      return 'pulse_dot';
    case OverlayKind.connectorLine:
      return 'connector_line';
    case OverlayKind.circleHighlight:
      return 'circle_highlight';
    case OverlayKind.checkMark:
      return 'check_mark';
    case OverlayKind.crossMark:
      return 'cross_mark';
    case OverlayKind.highlighter:
      return 'highlighter';
    case OverlayKind.boxOutline:
      return 'box_outline';
    case OverlayKind.underline:
      return 'underline';
    case OverlayKind.strikethrough:
      return 'strikethrough';
    case OverlayKind.bracket:
      return 'bracket';
    case OverlayKind.numberedLabel:
      return 'numbered_label';
    case OverlayKind.floatingIcon:
      return 'floating_icon';
    case OverlayKind.floatingImage:
      return 'floating_image';
    case OverlayKind.slide:
      return 'slide';
    case OverlayKind.cursor:
      return 'cursor';
  }
}

/// Single overlay entry held by the controller. `props` carries the
/// per-kind config (e.g. `{text, color, ...}`); kinds without
/// per-instance config keep an empty map.
class OverlaySpec {
  OverlaySpec({
    required this.id,
    required this.kind,
    this.target,
    this.targets,
    this.props = const <String, dynamic>{},
    this.appearMs = 200,
    this.stayMs = 0,
    this.fadeMs = 300,
  });

  final String id;
  final OverlayKind kind;
  final PositionRef? target;
  final List<PositionRef>? targets;
  final Map<String, dynamic> props;
  final int appearMs;
  final int stayMs; // 0 = persist until removed
  final int fadeMs;

  factory OverlaySpec.fromJson(String id, Map<String, dynamic> raw) {
    final kindStr = raw['kind']?.toString() ?? '';
    final kind = overlayKindFromString(kindStr);
    if (kind == null) {
      throw FormatException('unknown overlay kind: $kindStr');
    }
    PositionRef? target;
    if (raw.containsKey('target')) target = PositionRef.fromJson(raw['target']);
    List<PositionRef>? targets;
    if (raw['targets'] is List) {
      targets = <PositionRef>[
        for (final t in raw['targets'] as List) PositionRef.fromJson(t),
      ];
    }
    final props = <String, dynamic>{
      for (final entry in raw.entries)
        if (entry.key != 'kind' &&
            entry.key != 'target' &&
            entry.key != 'targets' &&
            entry.key != 'appearMs' &&
            entry.key != 'stayMs' &&
            entry.key != 'fadeMs')
          entry.key: entry.value,
    };
    return OverlaySpec(
      id: id,
      kind: kind,
      target: target,
      targets: targets,
      props: props,
      appearMs: (raw['appearMs'] as int?) ?? 200,
      stayMs: (raw['stayMs'] as int?) ?? 0,
      fadeMs: (raw['fadeMs'] as int?) ?? 300,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': overlayKindToString(kind),
    if (target != null) 'target': target!.toJson(),
    if (targets != null) 'targets': targets!.map((t) => t.toJson()).toList(),
    'appearMs': appearMs,
    'stayMs': stayMs,
    'fadeMs': fadeMs,
    ...props,
  };
}

/// Helper: parse a `#RRGGBB[AA]` hex color string. Returns null on
/// failure so the caller can fall back to a default.
Color? parseHexColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  var s = hex.replaceFirst('#', '');
  if (s.length == 6) s = 'ff$s';
  if (s.length != 8) return null;
  final v = int.tryParse(s, radix: 16);
  if (v == null) return null;
  return Color(v);
}
