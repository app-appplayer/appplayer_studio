import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Lazy-loaded widgets (v1.1)
/// Defers loading of content until it becomes visible, showing a placeholder
class LazyWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final placeholder = properties['placeholder'] as Map<String, dynamic>?;
    // Spec §10.21 canonical `child`; `content` kept as legacy alias.
    final child = (properties['child'] ?? properties['content'])
        as Map<String, dynamic>?;
    final trigger = context.resolve<String>(properties['trigger'] ?? 'visible');
    final delay = context.resolve<int?>(properties['delay']);
    // ignore: unused_local_variable
    final onLoad = properties['onLoad'] as Map<String, dynamic>?;
    // ignore: unused_local_variable
    final onError = properties['onError'] as Map<String, dynamic>?;

    return _LazyWidget(
      childDefinition: child,
      placeholderDefinition: placeholder,
      trigger: trigger,
      delay: delay,
      properties: properties,
      context: context,
      factory: this,
    );
  }
}

class _LazyWidget extends StatefulWidget {
  final Map<String, dynamic>? childDefinition;
  final Map<String, dynamic>? placeholderDefinition;
  final String trigger;
  final int? delay;
  final Map<String, dynamic> properties;
  final RenderContext context;
  final WidgetFactory factory;

  const _LazyWidget({
    this.childDefinition,
    this.placeholderDefinition,
    required this.trigger,
    this.delay,
    required this.properties,
    required this.context,
    required this.factory,
  });

  @override
  State<_LazyWidget> createState() => _LazyWidgetState();
}

class _LazyWidgetState extends State<_LazyWidget> {
  bool _loaded = false;
  Widget? _cachedChild;

  @override
  void initState() {
    super.initState();
    if (widget.trigger == 'immediate') {
      _loadContent();
    } else if (widget.trigger == 'delay' && widget.delay != null) {
      Future.delayed(Duration(milliseconds: widget.delay!), () {
        if (mounted) _loadContent();
      });
    }
    // 'visible' trigger is handled by VisibilityDetector in build.
    // 'manual' trigger waits for an external `load()` signal — the
    // child is held in the placeholder state until something explicitly
    // calls into the widget's load action. Implementation of the signal
    // dispatch surface is on a separate track; the case is recognised
    // here so unknown-trigger fall-through does not re-route to default.
  }

  void _loadContent() {
    if (!_loaded && mounted) {
      setState(() {
        _loaded = true;
        if (widget.childDefinition != null) {
          _cachedChild = widget.context.renderer
              .renderWidget(widget.childDefinition!, widget.context);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loaded && _cachedChild != null) {
      return widget.factory
          .applyCommonWrappers(_cachedChild!, widget.properties, widget.context);
    }

    // Show placeholder or default loading indicator
    Widget placeholder;
    if (widget.placeholderDefinition != null) {
      placeholder = widget.context.renderer
          .renderWidget(widget.placeholderDefinition!, widget.context);
    } else {
      placeholder = const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    // For 'visible' trigger, load when widget enters viewport
    if (widget.trigger == 'visible' && !_loaded) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // Trigger load when widget is laid out (approximation of visibility)
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _loadContent();
          });
          return placeholder;
        },
      );
    }

    return placeholder;
  }
}
