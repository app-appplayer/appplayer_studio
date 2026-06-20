import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';
import '../../accessibility/live_regions.dart';

/// Factory for creating accessible wrapper widgets
class AccessibleWrapperFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Get child widget
    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef == null) {
      return const SizedBox.shrink();
    }

    Widget child = context.renderer.renderWidget(childDef, context);

    // Apply focus management if specified
    final focusGroup = properties['focusGroup'] as String?;
    final focusOrder = properties['focusOrder'] as int?;
    final autoFocus = properties['autoFocus'] as bool? ?? false;

    if (focusGroup != null || focusOrder != null) {
      // Create a focus node for this widget
      final focusNode = FocusNode();

      // Register with MCPFocusManager if group is specified
      if (focusGroup != null) {
        // Focus groups are managed by FocusScope widgets
        // The MCPFocusManager can be used to traverse groups
      }

      child = Focus(
        focusNode: focusNode,
        autofocus: autoFocus,
        child: child,
      );

      // Add focus order if specified
      if (focusOrder != null) {
        child = FocusTraversalOrder(
          order: NumericFocusOrder(focusOrder.toDouble()),
          child: child,
        );
      }
    }

    // Apply live region if specified
    final liveRegion = properties['liveRegion'] as String?;
    final announceOnChange = properties['announceOnChange'] as bool? ?? false;

    if (liveRegion != null) {
      final liveRegionType = _parseLiveRegionType(liveRegion);

      if (announceOnChange) {
        // Monitor for changes and announce
        final watchPath = properties['watchPath'] as String?;
        if (watchPath != null) {
          // Create a stateful widget that watches for changes
          child = _LiveRegionWatcher(
            path: watchPath,
            liveRegionType: liveRegionType,
            context: context,
            child: child,
          );
        }
      }

      // Wrap with semantics for live region
      child = Semantics(
        liveRegion: true,
        child: child,
      );
    }

    // Apply navigation announcements if specified
    final announceNavigation =
        properties['announceNavigation'] as bool? ?? false;
    if (announceNavigation) {
      final message = properties['navigationMessage'] as String?;
      if (message != null) {
        // Announce when widget is built
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Create a temporary region for navigation announcements
          const navRegionId = '_navigation_announce';
          LiveRegionManager.instance
              .createRegion(navRegionId, LiveRegionType.polite);
          LiveRegionManager.instance.announce(navRegionId, message);
          // Clean up after announcement
          Future.delayed(const Duration(milliseconds: 100), () {
            LiveRegionManager.instance.removeRegion(navRegionId);
          });
        });
      }
    }

    return applyCommonWrappers(child, properties, context);
  }

  LiveRegionType _parseLiveRegionType(String type) {
    switch (type) {
      case 'assertive':
        return LiveRegionType.assertive;
      case 'status':
        return LiveRegionType.status;
      case 'alert':
        return LiveRegionType.alert;
      default:
        return LiveRegionType.polite;
    }
  }
}

/// Stateful widget that watches for changes and announces them
class _LiveRegionWatcher extends StatefulWidget {
  final String path;
  final LiveRegionType liveRegionType;
  final RenderContext context;
  final Widget child;

  const _LiveRegionWatcher({
    required this.path,
    required this.liveRegionType,
    required this.context,
    required this.child,
  });

  @override
  State<_LiveRegionWatcher> createState() => _LiveRegionWatcherState();
}

class _LiveRegionWatcherState extends State<_LiveRegionWatcher> {
  dynamic _lastValue;

  @override
  void initState() {
    super.initState();
    _lastValue = widget.context.getValue(widget.path);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _checkForChanges();
  }

  void _checkForChanges() {
    final currentValue = widget.context.getValue(widget.path);
    if (currentValue != _lastValue && currentValue != null) {
      // Create a region if it doesn't exist
      final regionId = 'watch_${widget.path}';
      LiveRegionManager.instance.createRegion(regionId, widget.liveRegionType);
      LiveRegionManager.instance.announce(regionId, currentValue.toString());
      _lastValue = currentValue;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Check for changes on each build
    _checkForChanges();
    return widget.child;
  }
}
