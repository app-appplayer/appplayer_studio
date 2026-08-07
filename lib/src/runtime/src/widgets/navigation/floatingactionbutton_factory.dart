import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../utils/icon_resolver.dart';
import '../widget_factory.dart';

/// Factory for FloatingActionButton widgets
class FloatingActionButtonWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final tooltip = context.resolve<String?>(properties['tooltip']);
    final foregroundColor =
        parseColor(context.resolve(properties['foregroundColor']), context);
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final focusColor = parseColor(context.resolve(properties['focusColor']), context);
    final hoverColor = parseColor(context.resolve(properties['hoverColor']), context);
    final splashColor = parseColor(context.resolve(properties['splashColor']), context);
    final heroTag = properties['heroTag'];
    final elevation = numberOf(properties['elevation'], context);
    final focusElevation = numberOf(properties['focusElevation'], context);
    final hoverElevation = numberOf(properties['hoverElevation'], context);
    final highlightElevation = numberOf(properties['highlightElevation'], context);
    final disabledElevation = numberOf(properties['disabledElevation'], context);
    final mini = boolOf(properties['mini'], context) ?? false;
    final shape = _parseShapeBorder(properties['shape']);
    final clipBehavior = _parseClip(properties['clipBehavior']) ?? Clip.none;
    final autofocus = boolOf(properties['autofocus'], context) ?? false;
    final materialTapTargetSize =
        _parseMaterialTapTargetSize(properties['materialTapTargetSize']);
    // §2.8.7 documents `label` as "Extended FAB label" and declares no
    // `isExtended` at all: a document that supplies a label is asking for the
    // extended form. Requiring an undeclared flag on top meant the label was
    // accepted, validated, and never drawn. `isExtended` still wins when set,
    // so a document can ask for the compact form with a label present.
    final declaredExtended = boolOf(properties['isExtended'], context);
    final isExtended = declaredExtended ??
        (context.resolve<String?>(properties['label'])?.isNotEmpty ?? false);

    // Extract child widget or icon/label (support 'child' and 'children')
    final childDef = (properties['child'] ?? definition['child'])
        as Map<String, dynamic>?;
    final childrenDef = properties['children'] as List<dynamic>? ??
        definition['children'] as List<dynamic>?;
    Widget? child;
    if (childDef != null) {
      child = context.buildWidget(childDef);
    } else if (childrenDef != null && childrenDef.isNotEmpty) {
      child = context.buildWidget(childrenDef.first as Map<String, dynamic>);
    } else {
      // Build from icon and label
      final icon = properties['icon'] == null
          ? null
          : resolveIconRef(context.resolve<Object?>(properties['icon']));
      final label = context.resolve<String?>(properties['label']);

      if (isExtended && label != null) {
        child = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) Icon(icon),
            if (icon != null && label.isNotEmpty) const SizedBox(width: 8),
            if (label.isNotEmpty) Text(label),
          ],
        );
      } else if (icon != null) {
        child = Icon(icon);
      }
    }

    // Extract action handler
    final onPressed = actionOf(properties['onTap'] ?? properties['click'] ?? properties['onPressed'], context);
    final onLongPress = actionOf(properties['onLongPress'] ?? properties['long-press'] ?? properties['longPress'], context);

    Widget fab;

    if (isExtended) {
      fab = FloatingActionButton.extended(
        onPressed: onPressed != null
            ? () {
                context.actionHandler.execute(onPressed, context);
              }
            : null,
        tooltip: tooltip,
        foregroundColor: foregroundColor,
        backgroundColor: backgroundColor,
        focusColor: focusColor,
        hoverColor: hoverColor,
        splashColor: splashColor,
        heroTag: heroTag,
        elevation: elevation,
        focusElevation: focusElevation,
        hoverElevation: hoverElevation,
        highlightElevation: highlightElevation,
        disabledElevation: disabledElevation,
        shape: shape,
        clipBehavior: clipBehavior,
        autofocus: autofocus,
        materialTapTargetSize: materialTapTargetSize,
        label:
            Text(context.resolve<String?>(properties['label']) ?? ''),
        icon: properties['icon'] != null
            ? Icon(resolveIconRef(context.resolve<Object?>(properties['icon'])))
            : null,
      );
    } else {
      fab = FloatingActionButton(
        onPressed: onPressed != null
            ? () {
                context.actionHandler.execute(onPressed, context);
              }
            : null,
        // onLongPress is not available for FloatingActionButton
        tooltip: tooltip,
        foregroundColor: foregroundColor,
        backgroundColor: backgroundColor,
        focusColor: focusColor,
        hoverColor: hoverColor,
        splashColor: splashColor,
        heroTag: heroTag,
        elevation: elevation,
        focusElevation: focusElevation,
        hoverElevation: hoverElevation,
        highlightElevation: highlightElevation,
        disabledElevation: disabledElevation,
        mini: mini,
        shape: shape,
        clipBehavior: clipBehavior,
        autofocus: autofocus,
        materialTapTargetSize: materialTapTargetSize,
        child: child,
      );
    }

    // Wrap with GestureDetector if onLongPress is specified
    if (onLongPress != null) {
      fab = GestureDetector(
        onLongPress: () {
          context.actionHandler.execute(onLongPress, context);
        },
        child: fab,
      );
    }

    return applyCommonWrappers(fab, properties, context);
  }


  ShapeBorder? _parseShapeBorder(dynamic shape) {
    if (shape == null) return null;

    if (shape is Map<String, dynamic>) {
      final type = shape['type'] as String?;
      switch (type) {
        case 'circle':
          return const CircleBorder();
        case 'rounded':
          final radius = shape['radius']?.toDouble() ?? 8.0;
          return RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          );
        case 'stadium':
          return const StadiumBorder();
        default:
          return null;
      }
    }

    return null;
  }

  Clip? _parseClip(String? value) {
    switch (value) {
      case 'none':
        return Clip.none;
      case 'hardEdge':
        return Clip.hardEdge;
      case 'antiAlias':
        return Clip.antiAlias;
      case 'antiAliasWithSaveLayer':
        return Clip.antiAliasWithSaveLayer;
      default:
        return null;
    }
  }

  MaterialTapTargetSize? _parseMaterialTapTargetSize(String? value) {
    switch (value) {
      case 'padded':
        return MaterialTapTargetSize.padded;
      case 'shrinkWrap':
        return MaterialTapTargetSize.shrinkWrap;
      default:
        return null;
    }
  }
}
