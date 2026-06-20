import 'dart:async';

import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Dashboard widgets (v1.3)
///
/// Compact rendering mode for embedding app summaries in multi-app contexts.
/// Supports content widget tree, auto-refresh interval, and onTap action.
class DashboardWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract dashboard content
    final contentDef = properties['content'] as Map<String, dynamic>?;
    final refreshInterval = (properties['refreshInterval'] as num?)?.toInt();
    final onTapAction = properties['onTap'] as Map<String, dynamic>?;

    // Build content widget
    Widget child = contentDef != null
        ? context.buildWidget(contentDef)
        : const SizedBox.shrink();

    // Wrap with refresh if interval specified
    if (refreshInterval != null && refreshInterval > 0) {
      child = _RefreshableWidget(
        interval: Duration(milliseconds: refreshInterval),
        builder: () => contentDef != null
            ? context.buildWidget(contentDef)
            : const SizedBox.shrink(),
      );
    }

    // Wrap with tap handler if onTap specified
    if (onTapAction != null) {
      child = GestureDetector(
        onTap: () => context.handleAction(onTapAction),
        child: child,
      );
    }

    return applyCommonWrappers(child, properties, context);
  }
}

/// Stateful widget that rebuilds its child on a periodic timer
class _RefreshableWidget extends StatefulWidget {
  const _RefreshableWidget({
    required this.interval,
    required this.builder,
  });

  final Duration interval;
  final Widget Function() builder;

  @override
  State<_RefreshableWidget> createState() => _RefreshableWidgetState();
}

class _RefreshableWidgetState extends State<_RefreshableWidget> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder();
  }
}
