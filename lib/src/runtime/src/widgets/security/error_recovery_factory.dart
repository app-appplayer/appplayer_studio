import 'package:flutter/material.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for ErrorRecovery widgets (v1.1)
/// Provides error-type-specific recovery handlers
class ErrorRecoveryWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final child = properties['child'] as Map<String, dynamic>?;
    final handlers =
        properties['handlers'] as Map<String, dynamic>? ?? {};
    final fallback = properties['fallback'] as Map<String, dynamic>?;
    final onError = properties['onError'] as Map<String, dynamic>?;
    final showDetails =
        context.resolve<bool>(properties['showDetails'] ?? false);

    return _ErrorRecoveryWidget(
      childDefinition: child,
      handlers: handlers,
      fallbackDefinition: fallback,
      onError: onError,
      showDetails: showDetails,
      properties: properties,
      context: context,
      factory: this,
    );
  }
}

class _ErrorRecoveryWidget extends StatefulWidget {
  final Map<String, dynamic>? childDefinition;
  final Map<String, dynamic> handlers;
  final Map<String, dynamic>? fallbackDefinition;
  final Map<String, dynamic>? onError;
  final bool showDetails;
  final Map<String, dynamic> properties;
  final RenderContext context;
  final WidgetFactory factory;

  const _ErrorRecoveryWidget({
    this.childDefinition,
    required this.handlers,
    this.fallbackDefinition,
    this.onError,
    required this.showDetails,
    required this.properties,
    required this.context,
    required this.factory,
  });

  @override
  State<_ErrorRecoveryWidget> createState() => _ErrorRecoveryWidgetState();
}

class _ErrorRecoveryWidgetState extends State<_ErrorRecoveryWidget> {
  // `_errorType` retained for `handlers` map routing (Dart runtime type
  // string — orthogonal to the `event` payload below).
  String? _errorType;
  String? _errorMessage;
  String? _errorStack;
  bool _hasError = false;

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return _buildErrorUI();
    }

    // Try to render child
    if (widget.childDefinition != null) {
      try {
        final child = widget.context.renderer
            .renderWidget(widget.childDefinition!, widget.context);
        return widget.factory
            .applyCommonWrappers(child, widget.properties, widget.context);
      } catch (e, st) {
        _errorType = e.runtimeType.toString();
        _errorMessage = e.toString();
        _errorStack = st.toString();
        _hasError = true;

        // Execute onError action with spec §2.13.12 canonical `event`
        // variable (`event.error` / `event.stack`).
        if (widget.onError != null) {
          final eventContext = widget.context.createChildContext(
            variables: {
              'event': {
                'error': _errorMessage,
                'stack': _errorStack,
              },
            },
          );
          widget.context.actionHandler.execute(widget.onError!, eventContext);
        }

        return _buildErrorUI();
      }
    }

    return const SizedBox.shrink();
  }

  Widget _buildErrorUI() {
    // Check for type-specific handler
    if (_errorType != null && widget.handlers.containsKey(_errorType)) {
      final handler = widget.handlers[_errorType];
      if (handler is Map<String, dynamic>) {
        final handlerWidget = handler['widget'] as Map<String, dynamic>?;
        if (handlerWidget != null) {
          return widget.context.renderer
              .renderWidget(handlerWidget, widget.context);
        }
      }
    }

    // Check for fallback
    if (widget.fallbackDefinition != null) {
      return widget.context.renderer
          .renderWidget(widget.fallbackDefinition!, widget.context);
    }

    // Default error UI — use M3 error container slots so the card
    // reads as an error surface in both light and dark themes.
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: cs.error, size: 32),
            const SizedBox(height: 8),
            Text(
              'Something went wrong',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: cs.onErrorContainer,
              ),
            ),
            if (widget.showDetails && _errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onErrorContainer.withValues(alpha: 0.75),
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _hasError = false;
                  _errorType = null;
                  _errorMessage = null;
                  _errorStack = null;
                });
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
