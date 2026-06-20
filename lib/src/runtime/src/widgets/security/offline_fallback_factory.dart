import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for OfflineFallback widgets (v1.1)
/// Shows alternative content when network is unavailable
class OfflineFallbackWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final online = properties['online'] as Map<String, dynamic>?;
    final offline = properties['offline'] as Map<String, dynamic>?;
    final message = context.resolve<String?>(properties['message']);
    final icon = properties['icon'] as String?;
    final showRetry = context.resolve<bool>(properties['showRetry'] ?? true);
    final onRetry = properties['onRetry'] as Map<String, dynamic>?;

    // Check connectivity binding
    final isOnline = context.resolve<bool?>(properties['isOnline']);

    // If online content exists and we're online (or connectivity unknown), show it
    if (isOnline != false && online != null) {
      return applyCommonWrappers(
        context.renderer.renderWidget(online, context),
        properties,
        context,
      );
    }

    // Show offline content or default fallback
    if (offline != null) {
      return applyCommonWrappers(
        context.renderer.renderWidget(offline, context),
        properties,
        context,
      );
    }

    // Default offline fallback UI — muted icon/text pulled from the
    // active theme so the card reads as a dim, inactive state in both
    // light and dark modes.
    final onSurface = context.themeManager.getColorValue('onSurface');
    Widget fallback = Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon == 'wifi_off' ? Icons.wifi_off : Icons.cloud_off,
              size: 48,
              color: onSurface?.withValues(alpha: 0.38) ??
                  Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              message ?? 'Content unavailable offline',
              style: TextStyle(
                fontSize: 16,
                color: onSurface?.withValues(alpha: 0.6) ??
                    Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
            if (showRetry && onRetry != null) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: () {
                  context.actionHandler.execute(onRetry, context);
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );

    return applyCommonWrappers(fallback, properties, context);
  }
}
