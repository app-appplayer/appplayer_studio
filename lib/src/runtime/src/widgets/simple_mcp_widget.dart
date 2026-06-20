import 'package:flutter/material.dart';
import '../renderer/renderer.dart';
import '../runtime/widget_registry.dart';
import '../renderer/render_context.dart';
import '../binding/binding_engine.dart';
import '../actions/action_handler.dart';
import '../state/state_manager.dart';
import 'widget_factory.dart';

/// Simple stateful widget that maintains its own renderer instance and state
class SimpleMCPWidget extends StatefulWidget {
  final Map<String, dynamic> uiDefinition;
  final Map<String, dynamic>? initialState;
  final Map<String, Function>? toolExecutors;
  final ErrorWidgetBuilder? errorBuilder;

  const SimpleMCPWidget({
    super.key,
    required this.uiDefinition,
    this.initialState,
    this.toolExecutors,
    this.errorBuilder,
  });

  @override
  State<SimpleMCPWidget> createState() => _SimpleMCPWidgetState();
}

class _SimpleMCPWidgetState extends State<SimpleMCPWidget> {
  late final Renderer _renderer;
  late final WidgetRegistry _widgetRegistry;
  late final BindingEngine _bindingEngine;
  late final ActionHandler _actionHandler;
  late final StateManager _stateManager;

  @override
  void initState() {
    super.initState();
    _initializeRenderer();
  }

  void _initializeRenderer() {
    _widgetRegistry = WidgetRegistry();
    _bindingEngine = BindingEngine();
    _actionHandler = ActionHandler();
    _stateManager = StateManager();

    _renderer = Renderer(
      widgetRegistry: _widgetRegistry,
      bindingEngine: _bindingEngine,
      actionHandler: _actionHandler,
      stateManager: _stateManager,
    );

    _registerDefaultWidgets();

    // Set up initial state
    if (widget.initialState != null) {
      _stateManager.initialize(widget.initialState!);
    }

    // Set up tool executors
    if (widget.toolExecutors != null) {
      widget.toolExecutors!.forEach((name, executor) {
        _actionHandler.registerToolExecutor(name, executor);
      });
    }

    // Listen to state changes and rebuild
    _stateManager.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _registerDefaultWidgets() {
    _widgetRegistry.register('text', _SimpleTextFactory());
    _widgetRegistry.register('button', _SimpleButtonFactory());
    _widgetRegistry.register('column', _SimpleColumnFactory());
    _widgetRegistry.register('row', _SimpleRowFactory());
    _widgetRegistry.register('container', _SimpleContainerFactory());
  }

  @override
  Widget build(BuildContext context) {
    try {
      // Validate UI definition
      if (!widget.uiDefinition.containsKey('page') &&
          !widget.uiDefinition.containsKey('layout')) {
        throw Exception(
            'UI definition must contain a "page" or "layout" field');
      }

      // Set up bindings
      final bindings = widget.uiDefinition['bindings'] as List<dynamic>?;
      if (bindings != null) {
        for (final binding in bindings) {
          _bindingEngine.registerBinding(binding as Map<String, dynamic>);
        }
      }

      // Render the page or layout
      if (widget.uiDefinition.containsKey('page')) {
        final page = widget.uiDefinition['page'] as Map<String, dynamic>;
        return _renderer.renderPage(page);
      } else {
        final layout = widget.uiDefinition['layout'] as Map<String, dynamic>;
        return _renderer.renderWidget(
            layout, _renderer.createRootContext(context));
      }
    } catch (e, stack) {
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(
          FlutterErrorDetails(
            exception: e,
            stack: stack,
            library: 'flutter_mcp_ui_renderer',
          ),
        );
      }
      return ErrorWidget(e);
    }
  }

  @override
  void dispose() {
    _stateManager.dispose();
    _bindingEngine.dispose();
    super.dispose();
  }
}

// Simple WidgetFactory implementations
class _SimpleTextFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final content = properties['content'] ?? '';
    final resolvedContent = context.resolve<String>(content);

    return Text(resolvedContent);
  }
}

class _SimpleButtonFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final label = properties['label'] ?? '';
    final onTap = (properties['onTap'] ?? properties['click'] ?? properties['onTap']) as Map<String, dynamic>?;

    return ElevatedButton(
      onPressed: onTap != null
          ? () async => await context.actionHandler.execute(onTap, context)
          : null,
      child: Text(label),
    );
  }
}

class _SimpleColumnFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    // Column is a multi-child widget, so children should be at root level
    final children = definition['children'] as List<dynamic>? ?? [];

    return Column(
      children: children
          .map((child) => context.buildWidget(child as Map<String, dynamic>))
          .toList(),
    );
  }
}

class _SimpleRowFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    // Row is a multi-child widget, so children should be at root level
    final children = definition['children'] as List<dynamic>? ?? [];

    return Row(
      children: children
          .map((child) => context.buildWidget(child as Map<String, dynamic>))
          .toList(),
    );
  }
}

class _SimpleContainerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    // Container is a single-child widget, so child should be in properties
    final childDef = properties['child'] as Map<String, dynamic>?;

    return Container(
      padding: const EdgeInsets.all(16),
      child: childDef != null ? context.buildWidget(childDef) : null,
    );
  }
}
