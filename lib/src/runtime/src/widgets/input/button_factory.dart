import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' as core;

import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';

/// Factory for Button widgets
class ButtonWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract button properties.
    // Canonical key is `label` per spec 17_Naming §17.3.2; `text` is a legacy
    // alias on the button widget.
    final label = context.resolve<String>(
        properties[core.PropertyKeys.label] ??
            properties[core.PropertyKeys.text] ??
            '');
    final iconValue = properties[core.PropertyKeys.icon];
    final icon = iconValue is String ? iconValue : null;
    final iconPosValue = properties['iconPosition'];
    final iconPosition = iconPosValue is String ? iconPosValue : 'start';

    // Canonical `variant` (spec v1.0); §17.3.2 legacy alias `style`.
    final variantValue = properties['variant'] ?? properties['style'];
    final variant = variantValue is String ? variantValue : 'elevated';

    final sizeValue = properties['size'];
    final size = sizeValue is String ? sizeValue : 'medium';
    final fullWidthValue = properties['fullWidth'];
    final fullWidth = fullWidthValue is bool ? fullWidthValue : false;
    final loading = context.resolve<bool>(properties['loading'] ?? false);
    // Design doc uses 'disabled'; support legacy 'enabled' with inversion
    final bool disabled;
    if (properties.containsKey('disabled')) {
      disabled = context.resolve<bool>(properties['disabled']);
    } else if (properties['enabled'] != null) {
      final enabled = context.resolve<bool>(properties['enabled']);
      disabled = !enabled;
    } else {
      disabled = false;
    }

    // Extract style properties from the properties directly. `elevation`
    // accepts an M3 token shorthand — `elevation: "level1"` resolves via
    // `theme.elevation.level1.shadow`. Numeric form is preserved.
    final backgroundColor = properties['backgroundColor'];
    final foregroundColor = properties['foregroundColor'];
    final rawElevation = context.resolve(properties['elevation']);
    final num? elevation = rawElevation is String
        ? parseElevationToken(rawElevation, context)
        : rawElevation as num?;
    final borderColor = properties['borderColor'];
    final borderWidth = properties['borderWidth'];

    // MCP UI DSL callback properties (on + PascalCase, event name fallback)
    final onTap =
        (properties[core.PropertyKeys.onTap] ?? properties[core.PropertyKeys.click]) as Map<String, dynamic>?;
    final onDoubleTap =
        (properties[core.PropertyKeys.onDoubleTap] ?? properties[core.PropertyKeys.doubleClick] ??
            properties[core.PropertyKeys.doubleClickLegacy])
            as Map<String, dynamic>?;
    final onLongPress =
        (properties[core.PropertyKeys.onLongPress] ?? properties[core.PropertyKeys.longPress] ??
            properties[core.PropertyKeys.longPressLegacy])
            as Map<String, dynamic>?;
    final submit = (properties['onSubmit'] ?? properties['submit']) as Map<String, dynamic>?;

    // Use click or submit action
    final primaryAction = onTap ?? submit;

    // Build button content
    Widget buttonChild;
    if (loading) {
      buttonChild = _buildLoadingContent(size);
    } else if (icon != null) {
      buttonChild = _buildIconContent(label, icon, iconPosition);
    } else {
      buttonChild = Text(label);
    }

    // Get aria-label for semantic override
    final ariaLabel = context.resolve<String?>(
        properties['ariaLabel'] ?? properties['aria-label']);

    // Build button
    Widget button;

    // Special case for icon variant - create IconButton
    if (variant == 'icon' && icon != null) {
      button = IconButton(
        icon: Icon(_parseIcon(icon)),
        onPressed: !loading && !disabled
            ? (primaryAction != null
                ? () async {
                    await context.handleAction(primaryAction);
                  }
                : () {}) // Empty handler when no action but not disabled
            : null,
        color: foregroundColor != null ? parseColor(foregroundColor, context) : null,
        iconSize: _getIconSize(size),
        tooltip: ariaLabel ?? label,
      );
    } else {
      button = _buildButton(
        style: variant,
        child: buttonChild,
        onPressed: !loading && !disabled
            ? (primaryAction != null
                ? () async {
                    // Handle special submit action
                    if (primaryAction['type'] == 'submit') {
                      // Look for form key and submit action in parent context
                      final formKey =
                          context.getValue<GlobalKey<FormState>>('_formKey');
                      final submitAction = context
                          .getValue<Map<String, dynamic>>('_formSubmitAction');

                      if (formKey != null && formKey.currentState != null) {
                        final formState = formKey.currentState!;
                        if (formState.validate()) {
                          formState.save();
                          // Execute the form's submit action if available
                          if (submitAction != null) {
                            await context.handleAction(submitAction);
                          }
                        }
                      }
                    } else {
                      // Regular action
                      // Regular action - use existing context
                      await context.handleAction(primaryAction);
                    }
                  }
                : () {}) // Empty handler when no action but not disabled
            : null,
        size: size,
        context: context,
        semanticLabel: ariaLabel,
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        elevation: elevation,
        borderColor: borderColor,
        borderWidth: borderWidth,
      );
    }

    // Wrap with gesture detector for additional events
    if (onDoubleTap != null || onLongPress != null) {
      button = GestureDetector(
        onDoubleTap: onDoubleTap != null && !loading && !disabled
            ? () async => await context.handleAction(onDoubleTap)
            : null,
        onLongPress: onLongPress != null && !loading && !disabled
            ? () async => await context.handleAction(onLongPress)
            : null,
        child: button,
      );
    }

    // Apply full width if needed
    if (fullWidth) {
      button = SizedBox(
        width: double.infinity,
        child: button,
      );
    }

    // If aria-label was already applied, remove it from properties to avoid double application
    final propsForWrapper = ariaLabel != null
        ? (Map<String, dynamic>.from(properties)
          ..remove('ariaLabel')
          ..remove('aria-label'))
        : properties;

    return applyCommonWrappers(button, propsForWrapper, context);
  }

  Widget _buildButton({
    required String style,
    required Widget child,
    required VoidCallback? onPressed,
    required String size,
    required RenderContext context,
    String? semanticLabel,
    dynamic backgroundColor,
    dynamic foregroundColor,
    dynamic elevation,
    dynamic borderColor,
    dynamic borderWidth,
  }) {
    final padding = _getButtonPadding(size);

    switch (style) {
      case 'elevated':
        final button = ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            padding: padding,
            backgroundColor:
                backgroundColor != null ? parseColor(backgroundColor, context) : null,
            foregroundColor:
                foregroundColor != null ? parseColor(foregroundColor, context) : null,
            elevation: elevation?.toDouble(),
            side: borderColor != null || borderWidth != null
                ? BorderSide(
                    color: borderColor != null
                        ? parseColor(borderColor, context)!
                        : Colors.transparent,
                    width: borderWidth?.toDouble() ?? 1.0,
                  )
                : null,
          ),
          child: child,
        );
        return semanticLabel != null
            ? Semantics(
                label: semanticLabel,
                button: true,
                child: ExcludeSemantics(child: button),
              )
            : button;

      case 'filled':
        final button = FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            padding: padding,
            backgroundColor:
                backgroundColor != null ? parseColor(backgroundColor, context) : null,
            foregroundColor:
                foregroundColor != null ? parseColor(foregroundColor, context) : null,
            elevation: elevation?.toDouble(),
            side: borderColor != null || borderWidth != null
                ? BorderSide(
                    color: borderColor != null
                        ? parseColor(borderColor, context)!
                        : Colors.transparent,
                    width: borderWidth?.toDouble() ?? 1.0,
                  )
                : null,
          ),
          child: child,
        );
        return semanticLabel != null
            ? Semantics(
                label: semanticLabel,
                button: true,
                child: ExcludeSemantics(child: button),
              )
            : button;

      case 'outlined':
        final button = OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: padding,
            backgroundColor:
                backgroundColor != null ? parseColor(backgroundColor, context) : null,
            foregroundColor:
                foregroundColor != null ? parseColor(foregroundColor, context) : null,
            elevation: elevation?.toDouble(),
            side: borderColor != null || borderWidth != null
                ? BorderSide(
                    color: borderColor != null
                        ? parseColor(borderColor, context)!
                        : (context.themeManager.getColorValue('outlineVariant') ??
                            Colors.grey),
                    width: borderWidth?.toDouble() ?? 1.0,
                  )
                : null,
          ),
          child: child,
        );
        return semanticLabel != null
            ? Semantics(
                label: semanticLabel,
                button: true,
                child: ExcludeSemantics(child: button),
              )
            : button;

      case 'text':
        final button = TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            padding: padding,
            backgroundColor:
                backgroundColor != null ? parseColor(backgroundColor, context) : null,
            foregroundColor:
                foregroundColor != null ? parseColor(foregroundColor, context) : null,
            elevation: elevation?.toDouble(),
            side: borderColor != null || borderWidth != null
                ? BorderSide(
                    color: borderColor != null
                        ? parseColor(borderColor, context)!
                        : Colors.transparent,
                    width: borderWidth?.toDouble() ?? 1.0,
                  )
                : null,
          ),
          child: child,
        );
        return semanticLabel != null
            ? Semantics(
                label: semanticLabel,
                button: true,
                child: ExcludeSemantics(child: button),
              )
            : button;

      default:
        final button = ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            padding: padding,
            backgroundColor:
                backgroundColor != null ? parseColor(backgroundColor, context) : null,
            foregroundColor:
                foregroundColor != null ? parseColor(foregroundColor, context) : null,
            elevation: elevation?.toDouble(),
            side: borderColor != null || borderWidth != null
                ? BorderSide(
                    color: borderColor != null
                        ? parseColor(borderColor, context)!
                        : Colors.transparent,
                    width: borderWidth?.toDouble() ?? 1.0,
                  )
                : null,
          ),
          child: child,
        );
        return semanticLabel != null
            ? Semantics(
                label: semanticLabel,
                button: true,
                child: ExcludeSemantics(child: button),
              )
            : button;
    }
  }

  Widget _buildLoadingContent(String size) {
    final indicatorSize = _getLoadingSize(size);
    // Spinner colour reads `onPrimary` from the active theme — the
    // loading indicator sits on a filled primary surface, so hardcoding
    // white would invert wrongly against alternate brand schemes.
    return SizedBox(
      width: indicatorSize,
      height: indicatorSize,
      child: Builder(
        builder: (bctx) => CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(
            Theme.of(bctx).colorScheme.onPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildIconContent(String label, String iconName, String position) {
    final icon = Icon(_parseIcon(iconName), size: 18);

    if (label.isEmpty) {
      return icon;
    }

    const spacing = SizedBox(width: 8);

    if (position == 'end') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          spacing,
          icon,
        ],
      );
    } else {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          spacing,
          Text(label),
        ],
      );
    }
  }

  EdgeInsets _getButtonPadding(String size) {
    switch (size) {
      case 'small':
        return const EdgeInsets.symmetric(horizontal: 12, vertical: 6);
      case 'large':
        return const EdgeInsets.symmetric(horizontal: 24, vertical: 16);
      case 'medium':
      default:
        return const EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    }
  }

  double _getLoadingSize(String size) {
    switch (size) {
      case 'small':
        return 14;
      case 'large':
        return 24;
      case 'medium':
      default:
        return 18;
    }
  }

  double _getIconSize(String size) {
    switch (size) {
      case 'small':
        return 18;
      case 'large':
        return 28;
      case 'medium':
      default:
        return 24;
    }
  }

  IconData _parseIcon(String iconName) => resolveIconData(iconName);
}
