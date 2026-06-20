import 'package:flutter/material.dart';

import '../../actions/action_handler.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for AppBar widgets
class AppBarWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    return Builder(builder: (buildContext) {
      return _buildAppBar(properties, context, buildContext);
    });
  }

  Widget _buildAppBar(
      Map<String, dynamic> properties, RenderContext context, BuildContext buildContext) {

    // Extract properties
    final titleData = properties['title'];
    final centerTitle = properties['centerTitle'] as bool?;
    final automaticallyImplyLeading =
        properties['automaticallyImplyLeading'] as bool? ?? true;
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context);
    final foregroundColor =
        parseColor(context.resolve(properties['foregroundColor']), context);
    final elevation = parseDimension(properties['elevation']);
    final shadowColor = parseColor(context.resolve(properties['shadowColor']), context);
    final shape = _parseShapeBorder(properties['shape']);
    final toolbarHeight = parseDimension(properties['toolbarHeight']);
    final toolbarOpacity = parseDimension(properties['toolbarOpacity']) ?? 1.0;
    final bottomOpacity = parseDimension(properties['bottomOpacity']) ?? 1.0;

    // Build leading widget
    Widget? leading;
    if (properties['leading'] != null) {
      leading = _buildWidget(properties['leading'], context);
    }

    // Build actions
    List<Widget>? actions;
    final actionsData = properties['actions'] as List<dynamic>?;
    if (actionsData != null) {
      actions = actionsData
          .map((action) => _buildWidget(action, context))
          .where((widget) => widget != null)
          .cast<Widget>()
          .toList();
    }

    // Spec §2.8.1 / §4.3.2: append host close button on the root route when
    // `onExit` is registered and `exitButton != false`.
    final exitButtonConfig = properties['exitButton'];
    final exitButtonSuppressed = exitButtonConfig == false;
    final isRoot = !Navigator.of(buildContext).canPop();
    if (!exitButtonSuppressed &&
        NavigationActionExecutor.hasOnExit &&
        isRoot) {
      final buttonCfg = exitButtonConfig is Map<String, dynamic>
          ? exitButtonConfig
          : const <String, dynamic>{};
      final iconName = buttonCfg['icon'] as String? ?? 'close';
      final tooltip = buttonCfg['tooltip'] as String? ?? 'Close';
      final colorStr = buttonCfg['color'];
      actions = [
        ...(actions ?? const <Widget>[]),
        IconButton(
          icon: Icon(_parseExitIcon(iconName),
              color: colorStr != null ? parseColor(colorStr, context) : null),
          tooltip: tooltip,
          onPressed: NavigationActionExecutor.invokeOnExit,
        ),
      ];
    }

    // Build bottom (TabBar, etc.)
    PreferredSizeWidget? bottom;
    if (properties['bottom'] != null) {
      final bottomWidget = _buildWidget(properties['bottom'], context);
      if (bottomWidget != null) {
        bottom = PreferredSize(
          preferredSize:
              Size.fromHeight(parseDimension(properties['bottomHeight']) ?? 48.0),
          child: bottomWidget,
        );
      }
    }

    // Build flexible space
    Widget? flexibleSpace;
    if (properties['flexibleSpace'] != null) {
      flexibleSpace = _buildWidget(properties['flexibleSpace'], context);
    }

    // Build title widget
    Widget? titleWidget;
    if (titleData != null) {
      if (titleData is String) {
        titleWidget = Text(titleData);
      } else if (titleData is Map<String, dynamic>) {
        titleWidget = _buildWidget(titleData, context);
      }
    }

    Widget appBar = AppBar(
      leading: leading,
      automaticallyImplyLeading: automaticallyImplyLeading,
      title: titleWidget,
      actions: actions,
      flexibleSpace: flexibleSpace,
      bottom: bottom,
      elevation: elevation,
      shadowColor: shadowColor,
      shape: shape,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      toolbarHeight: toolbarHeight,
      toolbarOpacity: toolbarOpacity,
      bottomOpacity: bottomOpacity,
      centerTitle: centerTitle,
    );

    return appBar;
  }

  IconData _parseExitIcon(String name) {
    switch (name) {
      case 'close':
        return Icons.close;
      case 'exit_to_app':
        return Icons.exit_to_app;
      case 'logout':
        return Icons.logout;
      case 'arrow_back':
        return Icons.arrow_back;
      default:
        return Icons.close;
    }
  }

  Widget? _buildWidget(dynamic widgetDef, RenderContext context) {
    if (widgetDef == null) return null;

    if (widgetDef is Map<String, dynamic>) {
      return context.renderer.renderWidget(widgetDef, context);
    }

    return null;
  }

  ShapeBorder? _parseShapeBorder(Map<String, dynamic>? shape) {
    if (shape == null) return null;

    final type = shape['type'] as String?;
    switch (type) {
      case 'rounded':
        final radius = shape['radius']?.toDouble() ?? 8.0;
        return RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            bottom: Radius.circular(radius),
          ),
        );
      default:
        return null;
    }
  }
}
