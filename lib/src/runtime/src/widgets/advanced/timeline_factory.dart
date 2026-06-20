import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';

/// Factory for Timeline widgets
class TimelineWidgetFactory extends WidgetFactory {
  IconData _parseIcon(String iconName) => resolveIconData(iconName);

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final items = context.resolve<List<dynamic>>(properties['items'] ?? [])
            as List<dynamic>? ??
        [];
    final orientation = properties['orientation'] as String? ?? 'vertical';
    final lineColor =
        parseColor(context.resolve(properties['lineColor']), context) ??
            context.themeManager.getColorValue('outlineVariant') ??
            Colors.grey;
    final onSurface =
        context.themeManager.getColorValue('onSurface') ?? Colors.black87;
    final lineWidth = properties['lineWidth']?.toDouble() ?? 2.0;
    final nodeSize = properties['nodeSize']?.toDouble() ?? 20.0;
    final spacing = properties['spacing']?.toDouble() ?? 20.0;
    final itemTemplate =
        properties['itemTemplate'] as Map<String, dynamic>?;

    // Build timeline items
    final List<Widget> timelineItems = [];

    for (int i = 0; i < items.length; i++) {
      final item = items[i] as Map<String, dynamic>;
      final isLast = i == items.length - 1;

      // Extract item properties
      final title = context.resolve(item['title'] ?? '') as String;
      final subtitle = context.resolve(item['subtitle'] ?? '') as String?;
      final time = context.resolve(item['time'] ?? '') as String?;
      final icon = item['icon'] as String?;
      final color = parseColor(context.resolve(item['color']), context) ?? Colors.blue;

      // Build content widget - use itemTemplate if provided
      Widget contentWidget;
      if (itemTemplate != null) {
        final childContext = context.createChildContext(
          variables: {
            'item': item,
            'index': i,
            'isFirst': i == 0,
            'isLast': isLast,
          },
        );
        contentWidget = context.renderer.renderWidget(itemTemplate, childContext);
      } else {
        contentWidget = Column(
          crossAxisAlignment: orientation == 'vertical'
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            if (time != null)
              Text(
                time,
                style: TextStyle(
                  fontSize: 12,
                  color: onSurface.withValues(alpha: 0.6),
                ),
              ),
            Text(
              title,
              style: TextStyle(
                fontSize: orientation == 'vertical' ? 16 : 14,
                fontWeight: FontWeight.w600,
              ),
              textAlign:
                  orientation == 'vertical' ? null : TextAlign.center,
            ),
            if (subtitle != null)
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: orientation == 'vertical' ? 14 : 12,
                  color: onSurface.withValues(alpha: 0.7),
                ),
                textAlign:
                    orientation == 'vertical' ? null : TextAlign.center,
              ),
          ],
        );
      }

      Widget timelineItem;

      if (orientation == 'vertical') {
        timelineItem = IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Timeline line and node
              Column(
                children: [
                  // Node
                  Container(
                    width: nodeSize,
                    height: nodeSize,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                    child: icon != null
                        ? Icon(
                            _parseIcon(icon),
                            size: nodeSize * 0.6,
                            color: Colors.white,
                          )
                        : null,
                  ),
                  // Line
                  if (!isLast)
                    Expanded(
                      child: Container(
                        width: lineWidth,
                        color: lineColor,
                      ),
                    ),
                ],
              ),
              SizedBox(width: spacing),
              // Content
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: isLast ? 0 : spacing),
                  child: contentWidget,
                ),
              ),
            ],
          ),
        );
      } else {
        // Horizontal timeline
        timelineItem = IntrinsicWidth(
          child: Column(
            children: [
              // Timeline line and node
              Row(
                children: [
                  if (i != 0)
                    Expanded(
                      child: Container(
                        height: lineWidth,
                        color: lineColor,
                      ),
                    ),
                  // Node
                  Container(
                    width: nodeSize,
                    height: nodeSize,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                    child: icon != null
                        ? Icon(
                            _parseIcon(icon),
                            size: nodeSize * 0.6,
                            color: Colors.white,
                          )
                        : null,
                  ),
                  if (!isLast)
                    Expanded(
                      child: Container(
                        height: lineWidth,
                        color: lineColor,
                      ),
                    ),
                ],
              ),
              SizedBox(height: spacing),
              // Content
              contentWidget,
            ],
          ),
        );
      }

      timelineItems.add(timelineItem);
    }

    Widget timeline;
    if (orientation == 'vertical') {
      timeline = Column(
        children: timelineItems,
      );
    } else {
      timeline = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: timelineItems,
        ),
      );
    }

    return applyCommonWrappers(timeline, properties, context);
  }
}
