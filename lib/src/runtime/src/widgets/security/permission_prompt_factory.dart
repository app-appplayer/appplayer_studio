import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for PermissionPrompt widgets (v1.1)
/// Renders a permission request UI that can be modal, inline, or banner style
class PermissionPromptWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final permissions = context.resolve<List<dynamic>>(
            properties['permissions'] ?? []) as List<dynamic>? ??
        [];
    final style =
        context.resolve<String>(properties['style'] ?? 'inline');
    final title = context.resolve<String?>(properties['title']);
    final description =
        context.resolve<String?>(properties['description']);
    final icon = properties['icon'] as String?;
    final onAllow = properties['onAllow'] as Map<String, dynamic>?;
    final onDeny = properties['onDeny'] as Map<String, dynamic>?;
    final allowPartial =
        context.resolve<bool>(properties['allowPartial'] ?? false);

    Widget prompt;

    switch (style) {
      case 'banner':
        prompt = _buildBannerPrompt(
          context, title, description, permissions, icon,
          onAllow, onDeny, allowPartial,
        );
        break;
      case 'modal':
      case 'inline':
      default:
        prompt = _buildInlinePrompt(
          context, title, description, permissions, icon,
          onAllow, onDeny, allowPartial,
        );
        break;
    }

    return applyCommonWrappers(prompt, properties, context);
  }

  Widget _buildInlinePrompt(
    RenderContext renderContext,
    String? title,
    String? description,
    List<dynamic> permissions,
    String? icon,
    Map<String, dynamic>? onAllow,
    Map<String, dynamic>? onDeny,
    bool allowPartial,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon == 'security' ? Icons.security : Icons.lock_outline,
                  color: renderContext.themeManager.getColorValue('error') ??
                      Colors.orange,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title ?? 'Permission Required',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(
                description,
                style: TextStyle(
                  fontSize: 14,
                  color: (renderContext.themeManager.getColorValue('onSurface') ??
                          Colors.black87)
                      .withValues(alpha: 0.6),
                ),
              ),
            ],
            if (permissions.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...permissions.map((p) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 16,
                            color: renderContext.themeManager
                                    .getColorValue('primary') ??
                                Colors.blue),
                        const SizedBox(width: 8),
                        Text(p.toString(),
                            style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  )),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onDeny != null)
                  TextButton(
                    onPressed: () {
                      renderContext.actionHandler.execute(onDeny, renderContext);
                    },
                    child: const Text('Deny'),
                  ),
                const SizedBox(width: 8),
                if (onAllow != null)
                  ElevatedButton(
                    onPressed: () {
                      renderContext.actionHandler.execute(onAllow, renderContext);
                    },
                    child: const Text('Allow'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBannerPrompt(
    RenderContext renderContext,
    String? title,
    String? description,
    List<dynamic> permissions,
    String? icon,
    Map<String, dynamic>? onAllow,
    Map<String, dynamic>? onDeny,
    bool allowPartial,
  ) {
    return MaterialBanner(
      leading: Icon(
        icon == 'security' ? Icons.security : Icons.lock_outline,
        color: renderContext.themeManager.getColorValue('error') ??
            Colors.orange,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title ?? 'Permission Required',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          if (description != null)
            Text(description, style: const TextStyle(fontSize: 13)),
        ],
      ),
      actions: [
        if (onDeny != null)
          TextButton(
            onPressed: () {
              renderContext.actionHandler.execute(onDeny, renderContext);
            },
            child: const Text('Deny'),
          ),
        if (onAllow != null)
          TextButton(
            onPressed: () {
              renderContext.actionHandler.execute(onAllow, renderContext);
            },
            child: const Text('Allow'),
          ),
      ],
    );
  }
}
