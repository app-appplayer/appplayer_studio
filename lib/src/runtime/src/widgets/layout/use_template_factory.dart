import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' show PropertyKeys;
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

    return context.renderer.renderWidget(resolved, context);
  }
}
