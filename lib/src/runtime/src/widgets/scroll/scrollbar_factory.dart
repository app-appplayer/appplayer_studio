import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for scrollbar widget.
///
/// Per spec §2.9.3 the runtime must provide a shared scroll controller to the
/// Scrollbar and its scrollable child. This factory owns a [ScrollController]
/// and exposes it to the subtree via [PrimaryScrollController] so that the
/// child scroll view (ScrollView, SingleChildScrollView, ListView, etc.)
/// attaches to the same position the Scrollbar is painting against.
class ScrollbarWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Spec §2.9.3: canonical single `child`. Legacy `children` array
    // accepted — first element becomes the scrollable content.
    final childDef = properties['child'] ??
        ((definition['children'] as List<dynamic>?)?.isNotEmpty ?? false
            ? (definition['children'] as List<dynamic>).first
            : null);

    return _ScrollbarHost(
      thumbVisibility: properties['thumbVisibility'] as bool? ?? false,
      trackVisibility: properties['trackVisibility'] as bool? ?? false,
      thickness: properties['thickness']?.toDouble(),
      radius: properties['radius'] != null
          ? Radius.circular(properties['radius'].toDouble())
          : null,
      childDef: childDef as Map<String, dynamic>?,
      context: context,
    );
  }
}

class _ScrollbarHost extends StatefulWidget {
  const _ScrollbarHost({
    required this.thumbVisibility,
    required this.trackVisibility,
    required this.thickness,
    required this.radius,
    required this.childDef,
    required this.context,
  });

  final bool thumbVisibility;
  final bool trackVisibility;
  final double? thickness;
  final Radius? radius;
  final Map<String, dynamic>? childDef;
  final RenderContext context;

  @override
  State<_ScrollbarHost> createState() => _ScrollbarHostState();
}

class _ScrollbarHostState extends State<_ScrollbarHost> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Force the child scroll view to attach to the injected controller.
    // On desktop, scroll views with `primary: null` don't auto-attach to
    // PrimaryScrollController, so we flip `primary: true` on the child
    // definition unless the author explicitly set it.
    final childDef = widget.childDef == null
        ? null
        : _withPrimaryDefault(widget.childDef!);

    final child = childDef != null
        ? widget.context.buildWidget(childDef)
        : const SizedBox.shrink();

    return PrimaryScrollController(
      controller: _controller,
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: widget.thumbVisibility,
        trackVisibility: widget.trackVisibility,
        thickness: widget.thickness,
        radius: widget.radius,
        child: child,
      ),
    );
  }

  Map<String, dynamic> _withPrimaryDefault(Map<String, dynamic> def) {
    const scrollables = {
      'scrollView',
      'singleChildScrollView',
      'list',
      'listView',
      'listview',
      'grid',
      'gridview',
      'pageView',
    };
    if (!scrollables.contains(def['type'])) return def;
    if (def.containsKey('primary')) return def;
    return {...def, 'primary': true};
  }
}
