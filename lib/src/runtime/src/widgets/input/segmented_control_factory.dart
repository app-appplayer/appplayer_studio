import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating segmented control widgets
class SegmentedControlFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final label = properties['label'] as String?;
    final binding = properties['binding'] as String?;
    final options = properties['options'] as List<dynamic>? ?? [];
    final enabled = context.resolve(properties['enabled'] ?? true) as bool;
    // Spec §2.6.19 — the three variants render differently. They used to all
    // resolve to SegmentedButton, so a document declaring `tabs` or `buttons`
    // got the same control and the declaration meant nothing.
    final variant = context.resolve<String?>(properties['variant']) ?? 'segmented';

    // Get current value
    final currentValue =
        binding != null ? context.resolve("{{$binding}}") : properties['value'];

    // Build segments
    final segments = <String, Widget>{};
    for (final option in options) {
      String value;
      Widget child;

      if (option is Map<String, dynamic>) {
        value = option['value']?.toString() ?? '';

        // Check for icon
        final iconName = option['icon'] as String?;
        final label = option['label']?.toString() ?? value;

        if (iconName != null) {
          // Try to parse icon
          final iconData = _parseIcon(iconName);
          if (iconData != null) {
            child = Icon(iconData, size: 20);
          } else {
            child = Text(label);
          }
        } else {
          child = Text(label);
        }
      } else {
        value = option.toString();
        child = Text(value);
      }

      segments[value] = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: child,
      );
    }

    void select(String value) {
      if (binding != null) context.setValue(binding, value);
    }

    final selectedValue = currentValue?.toString();
    final keys = segments.keys.toList();

    Widget segmentedControl;
    switch (variant) {
      case 'tabs':
        // Underlined tab strip: the same selection, presented as navigation
        // rather than as a control.
        segmentedControl = Builder(
          builder: (ctx) {
            final scheme = Theme.of(ctx).colorScheme;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final key in keys)
                  InkWell(
                    onTap: enabled ? () => select(key) : null,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: 2,
                            color: key == selectedValue
                                ? scheme.primary
                                : Colors.transparent,
                          ),
                        ),
                      ),
                      child: segments[key],
                    ),
                  ),
              ],
            );
          },
        );
        break;
      case 'buttons':
        // Discrete toggle buttons — each keeps its own edge rather than
        // sharing one joined outline.
        segmentedControl = Wrap(
          spacing: 8,
          children: [
            for (final key in keys)
              key == selectedValue
                  ? FilledButton(
                      onPressed: enabled ? () => select(key) : null,
                      child: segments[key]!,
                    )
                  : OutlinedButton(
                      onPressed: enabled ? () => select(key) : null,
                      child: segments[key]!,
                    ),
          ],
        );
        break;
      case 'segmented':
      default:
        segmentedControl = SegmentedButton<String>(
          segments: segments.entries
              .map((entry) => ButtonSegment<String>(
                    value: entry.key,
                    label: entry.value,
                  ))
              .toList(),
          selected: selectedValue != null ? {selectedValue} : {},
          // A document may bind the selection to state that has no value yet
          // — §2.6.0 does not require an initial one. Without this
          // `SegmentedButton` asserts and the whole page fails to draw.
          emptySelectionAllowed: selectedValue == null,
          onSelectionChanged: enabled
              ? (Set<String> selection) {
                  if (selection.isNotEmpty) select(selection.first);
                }
              : null,
          multiSelectionEnabled: false,
        );
    }

    // Add label if provided
    if (label != null) {
      segmentedControl = Column(
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
          segmentedControl,
        ],
      );
    }

    return applyCommonWrappers(segmentedControl, properties, context);
  }

  IconData? _parseIcon(String iconName) {
    // Common material icons mapping
    final iconMap = {
      'format_align_left': Icons.format_align_left,
      'format_align_center': Icons.format_align_center,
      'format_align_right': Icons.format_align_right,
      'format_align_justify': Icons.format_align_justify,
      'add': Icons.add,
      'remove': Icons.remove,
      'edit': Icons.edit,
      'delete': Icons.delete,
      'home': Icons.home,
      'settings': Icons.settings,
      'search': Icons.search,
      'favorite': Icons.favorite,
      'star': Icons.star,
      'check': Icons.check,
      'close': Icons.close,
      'arrow_back': Icons.arrow_back,
      'arrow_forward': Icons.arrow_forward,
      'more_vert': Icons.more_vert,
      'more_horiz': Icons.more_horiz,
    };

    return iconMap[iconName];
  }
}
