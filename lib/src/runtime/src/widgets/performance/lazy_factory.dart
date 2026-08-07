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
    final onLoad = actionOf(properties['onLoad'], context);
    final onError = actionOf(properties['onError'], context);

    return _LazyWidget(
      childDefinition: child,
      onLoad: onLoad,
      onError: onError,
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
  final Map<String, dynamic>? onLoad;
  final Map<String, dynamic>? onError;
  final String trigger;
  final int? delay;
  final Map<String, dynamic> properties;
  final RenderContext context;
  final WidgetFactory factory;

  const _LazyWidget({
    this.childDefinition,
    this.placeholderDefinition,
    this.onLoad,
    this.onError,
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
    if (_loaded || !mounted) return;
    setState(() {
      _loaded = true;
      final definition = widget.childDefinition;
      if (definition != null) {
        _cachedChild = widget.context.renderer
            .renderWidget(_materialize(definition), widget.context);
      }
    });
    // §10.22: fired after `content` is materialized. It was read and then
    // silenced with an `unused_local_variable` ignore, so a document that
    // declared it waited for something that never came.
    final onLoad = widget.onLoad;
    if (onLoad != null) {
      widget.context.actionHandler.execute(
        onLoad,
        widget.context.createChildContext(
          variables: <String, dynamic>{
            'event': <String, dynamic>{'type': 'load'},
          },
        ),
      );
    }
  }

  /// §10.22 gives `content` two forms: an inline widget, or
  /// `{ source: "ui://..." }` naming a fragment to fetch. Only the first was
  /// implemented — the second was handed to the renderer as-is, which
  /// answered `Widget type is required`, because a source is not a widget.
  ///
  /// Resolution is `view`'s job (§2.13.1) and is not rebuilt here: `lazy`
  /// decides *when* a subtree is built, `view` decides *what* a source
  /// resolves to. Delegating also carries `placeholder` and `onError`
  /// through to the surfaces that already implement them.
  Map<String, dynamic> _materialize(Map<String, dynamic> definition) {
    if (definition.containsKey('type')) return definition;
    if (!definition.containsKey('source')) return definition;
    return <String, dynamic>{
      'type': 'view',
      'source': definition['source'],
      if (definition['props'] != null) 'props': definition['props'],
      if (widget.placeholderDefinition != null)
        'loading': widget.placeholderDefinition,
      if (widget.onError != null) 'onError': widget.onError,
    };
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
