import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' show PropertyKeys;
import '../../models/ui_definition.dart' show LifecycleDefinition;
import '../lifecycle_host.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';
import '../../templates/template_registry.dart';

/// Factory for `use` widget type that resolves template instances (TM-01)
///
/// Usage in DSL:
/// ```json
/// {
///   "type": "use",
///   "template": "myTemplate",
///   "params": { "title": "Hello" },
///   "slots": { "content": { "type": "text", "content": "World" } }
/// }
/// ```
class UseTemplateFactory extends WidgetFactory {
  final TemplateRegistry templateRegistry;

  UseTemplateFactory({required this.templateRegistry});

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final resolved = templateRegistry.resolve(definition);

    if (resolved == null) {
      final templateName = definition[PropertyKeys.template] ?? 'unknown';
      return Builder(
        builder: (bctx) => Center(
          child: Text(
            'Template not found: $templateName',
            style: TextStyle(color: Theme.of(bctx).colorScheme.error),
          ),
        ),
      );
    }

    // §9.9.1: a template definition's own `onMount` / `onUnmount` fire once
    // PER INSTANCE, after `stateDefaults` initialization. §18 makes running
    // `onUnmount` a MUST. Nothing ran them before — a template could declare
    // both and be rendered with neither.
    //
    // The hooks live on the template definition, so they are read from the
    // resolved template, not from the `use` invocation.
    final hooks = LifecycleDefinition.fromDefinition(resolved);
    final rendered = context.renderer.renderWidget(resolved, context);
    if (hooks.isEmpty) return rendered;
    return LifecycleHost(
      hooks: hooks,
      context: context,
      label: 'template ${definition[PropertyKeys.template] ?? ''}',
      child: rendered,
    );
  }
}
