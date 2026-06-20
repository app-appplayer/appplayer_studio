import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../theme/menu_tokens.dart';
import '../widget_factory.dart';

/// Factory for `Dropdown` widgets (value selector).
///
/// Renders a `PopupMenuButton`-backed compact selector: trigger shows
/// the current value's label + a downward chevron, tap pops a menu of
/// `options`. Material's `DropdownButton` ships a fixed 16dp padding +
/// 0 radius which clashes with M3 surfaces; the runtime applies its own
/// compact tokens (resolved through `theme.component.menu` /
/// `theme.shape` with hardcoded compact fallbacks). Per-instance DSL
/// props override the resolved tokens.
class DropdownWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final label = properties['label'] as String?;

    final binding = properties['binding'] as String?;
    final value = binding != null
        ? context.resolve("{{$binding}}")
        : context.resolve(properties['value']);

    // spec v1.0: 'options', legacy: 'items'
    final items = (context
                .resolve<List<dynamic>>(properties['options'] ?? properties['items'])
            as List<dynamic>?) ??
        [];
    // Spec §2.6.5 canonical `placeholder`; `hint` kept as legacy alias.
    final hint = (properties['placeholder'] ?? properties['hint']) as String?;
    final disabledHint = properties['disabledHint'] as String?;
    final isExpanded = properties['isExpanded'] as bool? ?? false;
    final iconSize = properties['iconSize']?.toDouble() ?? 18.0;
    final style = _parseTextStyle(properties['style'], context);

    final onChange =
        (properties['onChange'] ?? properties['change']) as Map<String, dynamic>?;

    // Resolve compact menu tokens. Spec-bound dropdown props are
    // `{type, binding, value, options, items, placeholder, onChange,
    // enabled}` — visual fine-tuning happens through
    // `theme.component.menu.*` (free-form component tokens, spec §5.12)
    // and the runtime's compact defaults. No widget-level non-spec
    // props are read here.
    final tokens = MenuTokens.resolve(
      context.themeManager,
      itemHeight: properties['itemHeight']?.toDouble(),
      elevation: properties['elevation']?.toDouble(),
    );

    // Build a (label, value) pair list for menu items + trigger lookup.
    final entries = items.map((item) {
      if (item is Map<String, dynamic>) {
        final v = item['value'];
        final label = item['text']?.toString() ??
            item['label']?.toString() ??
            v?.toString() ??
            '';
        return MapEntry<dynamic, String>(v, label);
      }
      return MapEntry<dynamic, String>(item, item.toString());
    }).toList();

    String? selectedLabel;
    int? selectedIndex;
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].key == value) {
        selectedLabel = entries[i].value;
        selectedIndex = i;
        break;
      }
    }

    final enabled = onChange != null || binding != null;

    final triggerLabelText = selectedLabel ??
        (enabled ? hint : disabledHint) ??
        hint ??
        '';

    Widget dropdown = Builder(
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final cs = theme.colorScheme;
        // Trigger text — fontSize 13 matches the menu items so the
        // selected value reads at the same weight in both surfaces.
        // Uses bodyMedium for color/family if no DSL `style` override.
        final baseTextStyle = (style ?? theme.textTheme.bodyMedium ?? const TextStyle())
            .copyWith(fontSize: style?.fontSize ?? 13);
        final triggerStyle = selectedLabel != null
            ? baseTextStyle
            : baseTextStyle.copyWith(
                color: enabled ? cs.onSurfaceVariant : theme.disabledColor,
              );

        final trigger = Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(tokens.radius),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Row(
            mainAxisSize: isExpanded ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  triggerLabelText,
                  style: triggerStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down,
                size: iconSize,
                color: enabled ? cs.onSurfaceVariant : theme.disabledColor,
              ),
            ],
          ),
        );

        return PopupMenuButton<int>(
          enabled: enabled,
          initialValue: selectedIndex,
          position: PopupMenuPosition.under,
          menuPadding: tokens.menuPadding,
          padding: EdgeInsets.zero,
          shape: tokens.shape,
          elevation: tokens.elevation,
          popUpAnimationStyle: tokens.popupAnimationStyle,
          tooltip: '',
          itemBuilder: (_) => [
            for (var i = 0; i < entries.length; i++)
              PopupMenuItem<int>(
                value: i,
                // `null` itemHeight = no minimum, so the item height
                // tracks the text's natural size + padding (auto-scales
                // with `style.fontSize`).
                height: tokens.itemHeight ?? 0,
                padding: tokens.itemPadding,
                child: Text(
                  entries[i].value,
                  style: (style ?? const TextStyle()).copyWith(
                    // Menu items inherit `style.fontSize` (DSL spec
                    // prop); 13 is the runtime's compact fallback.
                    fontSize: style?.fontSize ?? 13,
                    color: cs.onSurface,
                  ),
                ),
              ),
          ],
          onSelected: (i) {
            final newValue = entries[i].key;

            if (binding != null) {
              context.setValue(binding, newValue);
            }

            if (onChange != null) {
              final eventContext = context.createChildContext(
                variables: {
                  'event': {
                    'value': newValue,
                    'index': i,
                    'type': 'change',
                  },
                },
              );
              context.actionHandler.execute(onChange, eventContext);
            }
          },
          child: trigger,
        );
      },
    );

    if (label != null) {
      dropdown = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          dropdown,
        ],
      );
    }

    return applyCommonWrappers(dropdown, properties, context);
  }

  TextStyle? _parseTextStyle(
      Map<String, dynamic>? style, RenderContext context) {
    if (style == null) return null;

    return TextStyle(
      color: parseColor(context.resolve(style['color']), context),
      fontSize: style['fontSize']?.toDouble(),
      fontWeight: _parseFontWeight(style['fontWeight']),
      fontStyle: style['italic'] == true ? FontStyle.italic : FontStyle.normal,
      letterSpacing: style['letterSpacing']?.toDouble(),
      wordSpacing: style['wordSpacing']?.toDouble(),
      height: style['height']?.toDouble(),
    );
  }

  FontWeight? _parseFontWeight(String? value) {
    switch (value) {
      case 'bold':
        return FontWeight.bold;
      case 'w100':
        return FontWeight.w100;
      case 'w200':
        return FontWeight.w200;
      case 'w300':
        return FontWeight.w300;
      case 'w400':
        return FontWeight.w400;
      case 'w500':
        return FontWeight.w500;
      case 'w600':
        return FontWeight.w600;
      case 'w700':
        return FontWeight.w700;
      case 'w800':
        return FontWeight.w800;
      case 'w900':
        return FontWeight.w900;
      default:
        return null;
    }
  }
}
