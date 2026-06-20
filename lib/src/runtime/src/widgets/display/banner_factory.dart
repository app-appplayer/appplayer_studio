import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Banner widgets
///
/// Design spec properties:
/// - message (required): Banner message text
/// - severity: 'info' | 'success' | 'warning' | 'error' (default: 'info')
/// - actions: Action[] optional action buttons
class BannerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final message = properties['message'] != null
        ? context.resolve<String>(properties['message'])
        : '';
    final severity = properties['severity'] != null
        ? context.resolve<String>(properties['severity'])
        : 'info';

    // actions: list of {label, click} objects
    final actionsDef = properties['actions'] as List<dynamic>?;

    // Builder gives us a BuildContext under the current Theme so the
    // severity palette can adapt to light / dark mode. Severity styling
    // previously used hardcoded Material-2 pastels that looked foreign
    // against dark chrome.
    Widget banner = Builder(
      builder: (bctx) {
        final severityStyle = _getSeverityStyle(severity, bctx);
        final actionWidgets = <Widget>[];
        if (actionsDef != null) {
          for (final actionDef in actionsDef) {
            if (actionDef is Map<String, dynamic>) {
              final label = actionDef['label'] != null
                  ? context.resolve<String>(actionDef['label'])
                  : '';
              final clickAction = actionDef['click'] as Map<String, dynamic>?;
              actionWidgets.add(
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: severityStyle.foregroundColor,
                  ),
                  onPressed: clickAction != null
                      ? () => context.actionHandler.execute(clickAction, context)
                      : null,
                  child: Text(label),
                ),
              );
            }
          }
        }
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: severityStyle.backgroundColor,
            border: Border(
              left: BorderSide(color: severityStyle.accentColor, width: 4),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(severityStyle.icon,
                  color: severityStyle.accentColor, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: severityStyle.foregroundColor),
                ),
              ),
              if (actionWidgets.isNotEmpty) ...actionWidgets,
            ],
          ),
        );
      },
    );

    return applyCommonWrappers(banner, properties, context);
  }

  /// Build severity palette from the active theme. `error` / `info` map to
  /// Material 3 container slots (`errorContainer` / `primaryContainer`);
  /// `success` / `warning` have no canonical M3 slots, so the accent is
  /// fixed (green / amber) and the background / foreground swap to the
  /// appropriate shade for the current brightness.
  _SeverityStyle _getSeverityStyle(String severity, BuildContext bctx) {
    final cs = Theme.of(bctx).colorScheme;
    final isDark = Theme.of(bctx).brightness == Brightness.dark;
    switch (severity) {
      case 'success':
        return _SeverityStyle(
          backgroundColor:
              isDark ? const Color(0xFF1F3A24) : const Color(0xFFE8F5E9),
          accentColor: const Color(0xFF4CAF50),
          foregroundColor:
              isDark ? const Color(0xFFA5D6A7) : const Color(0xFF1B5E20),
          icon: Icons.check_circle_outline,
        );
      case 'warning':
        return _SeverityStyle(
          backgroundColor:
              isDark ? const Color(0xFF3E2F13) : const Color(0xFFFFF8E1),
          accentColor: const Color(0xFFFFC107),
          foregroundColor:
              isDark ? const Color(0xFFFFE082) : const Color(0xFF7B5800),
          icon: Icons.warning_amber_outlined,
        );
      case 'error':
        return _SeverityStyle(
          backgroundColor: cs.errorContainer,
          accentColor: cs.error,
          foregroundColor: cs.onErrorContainer,
          icon: Icons.error_outline,
        );
      case 'info':
      default:
        return _SeverityStyle(
          backgroundColor: cs.primaryContainer,
          accentColor: cs.primary,
          foregroundColor: cs.onPrimaryContainer,
          icon: Icons.info_outline,
        );
    }
  }
}

class _SeverityStyle {
  final Color backgroundColor;
  final Color accentColor;
  final Color foregroundColor;
  final IconData icon;

  const _SeverityStyle({
    required this.backgroundColor,
    required this.accentColor,
    required this.foregroundColor,
    required this.icon,
  });
}
