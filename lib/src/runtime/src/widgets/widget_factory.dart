import 'package:flutter/material.dart';

import '../renderer/render_context.dart';

/// Base class for widget factories
abstract class WidgetFactory {
  /// Build a widget from definition and context
  Widget build(
    Map<String, dynamic> definition,
    RenderContext context,
  );

  /// Extract common properties
  Map<String, dynamic> extractProperties(Map<String, dynamic> definition) {
    // With the new flat structure, properties are at the top level
    // We create a copy of the definition without the 'type' key
    final properties = Map<String, dynamic>.from(definition);
    properties.remove('type'); // Remove the type key as it's not a property
    return properties;
  }

  /// Apply common widget wrappers (visibility, tooltip, accessibility, etc.)
  Widget applyCommonWrappers(
    Widget widget,
    Map<String, dynamic> properties,
    RenderContext context,
  ) {
    // Handle visibility
    final visible = context.resolve<bool>(properties['visible'] ?? true);
    if (!visible) {
      return const SizedBox.shrink();
    }

    // Handle tooltip
    final tooltip = context.resolve<String?>(properties['tooltip']);
    if (tooltip != null && tooltip.isNotEmpty) {
      widget = Tooltip(
        message: tooltip,
        child: widget,
      );
    }

    // Handle click — spec 1.3.4 common property §2.2. Wraps any widget in a
    // gesture surface and dispatches the bound action on tap. Widget-local
    // activation slots (button.onTap, iconButton.onTap, richText.spans[].onTap,
    // ...) remain canonical for those widgets; `click` is the universal
    // fallback for pure layout / decoration widgets (box, card, linear, ...).
    // Applied BEFORE the enabled wrap so `enabled: false` (IgnorePointer)
    // suppresses the gesture surface alongside the underlying widget.
    // The action payload is resolved through the binding engine so authors
    // may inject `{{...}}`-bound action maps.
    var clickWrapped = false;
    final rawClick = properties['click'];
    if (rawClick != null) {
      final resolvedClick = context.resolve(rawClick);
      if (resolvedClick is Map) {
        final clickAction = Map<String, dynamic>.from(resolvedClick);
        widget = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.actionHandler.execute(clickAction, context),
          child: widget,
        );
        clickWrapped = true;
      }
    }

    // Handle enabled state - skip for widgets that handle it internally
    // Button widgets handle enabled state by setting onPressed to null.
    // A GestureDetector produced by the `click` wrap above is NOT
    // self-disabling, so the IgnorePointer must wrap it when `enabled: false`.
    final isButtonWidget = !clickWrapped &&
        (widget is ElevatedButton ||
            widget is TextButton ||
            widget is OutlinedButton ||
            widget is FilledButton ||
            widget is IconButton ||
            widget is GestureDetector ||
            widget is SizedBox &&
                (widget.child is ElevatedButton ||
                    widget.child is TextButton ||
                    widget.child is OutlinedButton ||
                    widget.child is FilledButton ||
                    widget.child is IconButton));

    if (!isButtonWidget) {
      final enabled = context.resolve<bool>(properties['enabled'] ?? true);
      if (!enabled) {
        widget = IgnorePointer(
          child: Opacity(
            opacity: 0.6,
            child: widget,
          ),
        );
      }
    }

    // Handle accessibility (MCP UI DSL v1.0)
    widget = _applyAccessibility(widget, properties, context);

    // Handle key / testKey — wrap with KeyedSubtree for widget identity
    // testKey takes precedence over key (design doc: testKey is for testing)
    final testKey = properties['testKey'] as String?;
    final keyProp = properties['key'] as String?;
    final widgetKey = testKey ?? keyProp;
    if (widgetKey != null) {
      widget = KeyedSubtree(
        key: ValueKey(widgetKey),
        child: widget,
      );
    }

    return widget;
  }

  /// Apply accessibility properties to widget
  Widget _applyAccessibility(
    Widget widget,
    Map<String, dynamic> properties,
    RenderContext context,
  ) {
    // Get accessibility properties
    // Canonical camelCase keys with kebab-case fallback (backward compatibility)
    final ariaLabel = context.resolve<String?>(
        properties['ariaLabel'] ?? properties['aria-label']);
    final ariaHidden = context.resolve<bool>(
        properties['ariaHidden'] ?? properties['aria-hidden'] ?? false);
    final ariaRole = context.resolve<String?>(
        properties['ariaRole'] ?? properties['aria-role']);
    final ariaDescription = context.resolve<String?>(
        properties['ariaDescription'] ?? properties['aria-description']);
    final ariaLiveRegion = context.resolve<String?>(
        properties['ariaLive'] ?? properties['aria-live']);

    // If aria-hidden is true, exclude from semantics tree
    if (ariaHidden) {
      return ExcludeSemantics(
        child: widget,
      );
    }

    // Apply semantic properties if any are specified
    if (ariaLabel != null ||
        ariaRole != null ||
        ariaDescription != null ||
        ariaLiveRegion != null) {
      // Convert aria-live to Flutter's liveness
      bool? isLiveRegion;
      if (ariaLiveRegion != null) {
        isLiveRegion =
            ariaLiveRegion == 'polite' || ariaLiveRegion == 'assertive';
      }

      widget = Semantics(
        label: ariaLabel,
        hint: ariaDescription,
        liveRegion: isLiveRegion,
        // Map common ARIA roles to Flutter semantic properties
        button: ariaRole == 'button',
        link: ariaRole == 'link',
        header: ariaRole == 'heading',
        textField: ariaRole == 'textbox',
        image: ariaRole == 'img',
        slider: ariaRole == 'slider',
        checked: ariaRole == 'checkbox'
            ? null
            : null, // Checkbox state handled by widget itself
        child: widget,
      );
    }

    return widget;
  }

  /// Parse EdgeInsets
  EdgeInsets? parseEdgeInsets(dynamic value) {
    if (value == null) return null;

    if (value is Map<String, dynamic>) {
      if (value.containsKey('all')) {
        return EdgeInsets.all(parseDimension(value['all']) ?? 0);
      }

      if (value.containsKey('horizontal') || value.containsKey('vertical')) {
        return EdgeInsets.symmetric(
          horizontal: parseDimension(value['horizontal']) ?? 0,
          vertical: parseDimension(value['vertical']) ?? 0,
        );
      }

      return EdgeInsets.only(
        left: parseDimension(value['left']) ?? 0,
        top: parseDimension(value['top']) ?? 0,
        right: parseDimension(value['right']) ?? 0,
        bottom: parseDimension(value['bottom']) ?? 0,
      );
    }

    if (value is num) {
      return EdgeInsets.all(value.toDouble());
    }

    return null;
  }

  /// Resolve Color (alias for parseColor). Prefer passing [context] so
  /// semantic theme slots (`primary`, `surface`, …) resolve against the
  /// active light/dark scheme; otherwise only hex + Material names work.
  Color? resolveColor(dynamic value, [RenderContext? context]) {
    return parseColor(value, context);
  }

  /// Resolve EdgeInsets (alias for parseEdgeInsets)
  EdgeInsets? resolveEdgeInsets(dynamic value) {
    return parseEdgeInsets(value);
  }

  /// Resolve Alignment (alias for parseAlignment)
  Alignment? resolveAlignment(dynamic value) {
    return parseAlignment(value);
  }

  /// Canonical M3 28-role color slot names resolved by [parseColor] when a
  /// [RenderContext] is provided. Spec §5.3 — `theme.color.<slot>`.
  static const Set<String> _themeSlotNames = <String>{
    // Primary family
    'primary',
    'onPrimary',
    'primaryContainer',
    'onPrimaryContainer',
    // Secondary family
    'secondary',
    'onSecondary',
    'secondaryContainer',
    'onSecondaryContainer',
    // Tertiary family
    'tertiary',
    'onTertiary',
    'tertiaryContainer',
    'onTertiaryContainer',
    // Error family
    'error',
    'onError',
    'errorContainer',
    'onErrorContainer',
    // Surface family
    'surface',
    'onSurface',
    'onSurfaceVariant',
    'surfaceTint',
    'surfaceBright',
    'surfaceDim',
    'surfaceContainerLowest',
    'surfaceContainerLow',
    'surfaceContainer',
    'surfaceContainerHigh',
    'surfaceContainerHighest',
    // Outline / inverse / misc
    'outline',
    'outlineVariant',
    'inverseSurface',
    'onInverseSurface',
    'inversePrimary',
    'scrim',
    'shadow',
    // Semantic (additions beyond M3).
    'success',
    'onSuccess',
    'warning',
    'onWarning',
    'info',
    'onInfo',
  };

  /// Parse a DSL color value into a Flutter [Color].
  ///
  /// Supported forms (spec §5 + FR-THEME-002):
  ///   * 6-digit hex `#RRGGBB`
  ///   * 8-digit hex `#AARRGGBB`
  ///   * 3-digit hex shorthand `#RGB`
  ///   * Material color names (`red`, `blue`, `grey` …) — 10 well-known names
  ///   * Semantic theme slots (`primary`, `onSurface`, `error` …) — resolved
  ///     against [RenderContext.themeManager] at the active light/dark mode.
  ///     Requires [context] to be supplied; without it, slot names return
  ///     null so the widget falls back to its Flutter default. This path
  ///     is what makes dark-mode adapt for author-specified colors — DSL
  ///     authors should prefer slots over literal hex for any color that
  ///     needs to track theme.
  Color? parseColor(dynamic value, [RenderContext? context]) {
    if (value == null) return null;

    if (value is String) {
      if (value.startsWith('#')) {
        String hex = value.substring(1);

        try {
          // 8-digit AARRGGBB format
          if (hex.length == 8) {
            return Color(int.parse(hex, radix: 16));
          }
          // 6-digit RRGGBB format (add alpha channel FF)
          else if (hex.length == 6) {
            return Color(int.parse('FF$hex', radix: 16));
          }
          // 3-digit RGB shorthand
          else if (hex.length == 3) {
            String expanded = hex.split('').map((c) => '$c$c').join();
            return Color(int.parse('FF$expanded', radix: 16));
          }
        } catch (e) {
          // Return null if hex contains invalid characters
          return null;
        }

        return null;
      }

      // Named colors
      switch (value.toLowerCase()) {
        case 'red':
          return Colors.red;
        case 'blue':
          return Colors.blue;
        case 'green':
          return Colors.green;
        case 'yellow':
          return Colors.yellow;
        case 'orange':
          return Colors.orange;
        case 'purple':
          return Colors.purple;
        case 'black':
          return Colors.black;
        case 'white':
          return Colors.white;
        case 'grey':
        case 'gray':
          return Colors.grey;
      }

      // Spec §5.3 canonical scheme slot — adapts to the active
      // light / dark mode of the host theme. Token names are matched
      // case-sensitively to mirror the binding path `theme.colorScheme.<slot>`.
      if (context != null && _themeSlotNames.contains(value)) {
        return context.themeManager.getColorValue(value);
      }

      return null;
    }

    return null;
  }

  /// Parse Alignment
  Alignment? parseAlignment(dynamic value) {
    if (value == null) return null;

    if (value is String) {
      switch (value) {
        // Spec § Alignment primitive — directional canonical
        // (topStart / topEnd / bottomStart / bottomEnd, RTL-aware
        // per Material 3). Visual aliases (topLeft / topRight /
        // bottomLeft / bottomRight) are accepted at runtime for
        // backward compat with bundles authored against pre-1.3
        // spec drafts; the schema only validates the directional
        // form.
        case 'topStart':
        case 'topLeft':
          return Alignment.topLeft;
        case 'topCenter':
          return Alignment.topCenter;
        case 'topEnd':
        case 'topRight':
          return Alignment.topRight;
        case 'centerStart':
        case 'centerLeft':
          return Alignment.centerLeft;
        case 'center':
          return Alignment.center;
        case 'centerEnd':
        case 'centerRight':
          return Alignment.centerRight;
        case 'bottomStart':
        case 'bottomLeft':
          return Alignment.bottomLeft;
        case 'bottomCenter':
          return Alignment.bottomCenter;
        case 'bottomEnd':
        case 'bottomRight':
          return Alignment.bottomRight;
        default:
          return null;
      }
    }

    return null;
  }

  /// Parse dimension value - supports both direct numbers and MCP UI DSL v1.0 format
  /// MCP UI DSL v1.0 format: {"value": 100, "unit": "px"}
  /// Also supports direct numbers for backward compatibility
  double? parseDimension(dynamic value) {
    if (value == null) return null;
    
    // Direct number format
    if (value is num) {
      return value.toDouble();
    }
    
    // MCP UI DSL v1.0 format: {"value": 100, "unit": "px"}
    if (value is Map<String, dynamic>) {
      final dimensionValue = value['value'];
      if (dimensionValue is num) {
        return dimensionValue.toDouble();
      }
    }
    
    return null;
  }

  /// Parse BoxConstraints
  BoxConstraints? parseConstraints(dynamic value) {
    if (value == null) return null;

    if (value is Map<String, dynamic>) {
      return BoxConstraints(
        minWidth: parseDimension(value['minWidth']) ?? 0.0,
        minHeight: parseDimension(value['minHeight']) ?? 0.0,
        maxWidth: parseDimension(value['maxWidth']) ?? double.infinity,
        maxHeight: parseDimension(value['maxHeight']) ?? double.infinity,
      );
    }

    return null;
  }

  // ===== M3 token shorthand resolvers =====================================
  //
  // These helpers translate the spec's token shorthand strings into concrete
  // Flutter values by reading the active theme. They accept the raw DSL
  // value (already past binding resolution) so factories can simply call
  // `parseSpacingToken('md', context)` from a property they expose.
  //
  // Spec § 5.4 (typography), § 5.5 (spacing), § 5.6 (shape), § 5.7
  // (elevation). Returning `null` on unknown tokens lets callers fall back
  // to numeric / object forms without throwing on bad bundle input.

  /// Resolve an M3 spacing token (`xxs` / `xs` / `sm` / `md` / `lg` / `xl` /
  /// `2xl` / `3xl` / `4xl`, or any custom slot defined in
  /// `theme.spacing`) to its numeric dp value.
  double? parseSpacingToken(String? token, RenderContext context) {
    if (token == null || token.isEmpty) return null;
    final raw = context.themeManager.getThemeValue('spacing.$token');
    if (raw is num) return raw.toDouble();
    return null;
  }

  /// Resolve an M3 shape family (`none` / `extraSmall` / `small` / `medium`
  /// / `large` / `extraLarge` / `full`) to a [ShapeBorder]. The corner is
  /// applied uniformly via [BorderRadius.circular]; per-corner shapes
  /// remain object-form.
  ShapeBorder? parseShapeToken(String? token, RenderContext context) {
    if (token == null || token.isEmpty) return null;
    final entry = context.themeManager.getThemeValue('shape.$token');
    if (entry is num) {
      return RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(entry.toDouble()),
      );
    }
    if (entry is Map) {
      return parseThemeShapeMap(Map<String, dynamic>.from(entry));
    }
    return null;
  }

  /// Build a [ShapeBorder] from the theme's stored shape map form —
  /// either `{uniform: N}` for uniform corner radius or per-corner
  /// (`topStart/topEnd/bottomStart/bottomEnd`, RTL-aware aliases). Used
  /// both for `theme.shape.<token>` lookups and when the DSL author
  /// supplies a shape Map directly via a binding expression.
  ShapeBorder? parseThemeShapeMap(Map<String, dynamic>? shape) {
    if (shape == null) return null;
    final uniform = shape['uniform'];
    if (uniform is num) {
      return RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(uniform.toDouble()),
      );
    }
    final tl = (shape['topStart'] ?? shape['topLeft']) as num?;
    final tr = (shape['topEnd'] ?? shape['topRight']) as num?;
    final bl = (shape['bottomStart'] ?? shape['bottomLeft']) as num?;
    final br = (shape['bottomEnd'] ?? shape['bottomRight']) as num?;
    if (tl != null || tr != null || bl != null || br != null) {
      return RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(tl?.toDouble() ?? 0),
          topRight: Radius.circular(tr?.toDouble() ?? 0),
          bottomLeft: Radius.circular(bl?.toDouble() ?? 0),
          bottomRight: Radius.circular(br?.toDouble() ?? 0),
        ),
      );
    }
    return null;
  }

  /// Resolve an M3 elevation level token (`level0` … `level5`) to its
  /// shadow dp value. Returns `null` for unknown tokens so callers can
  /// fall back to numeric form.
  double? parseElevationToken(String? token, RenderContext context) {
    if (token == null || token.isEmpty) return null;
    final entry = context.themeManager.getThemeValue('elevation.$token');
    if (entry is num) return entry.toDouble();
    if (entry is Map) {
      final shadow = entry['shadow'];
      if (shadow is num) return shadow.toDouble();
    }
    return null;
  }
}
