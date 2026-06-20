import 'package:flutter/material.dart';
import '../widget_factory.dart';
import '../../renderer/render_context.dart';

/// Factory for creating error boundary widgets (WC-10)
///
/// Wraps child content with error handling, displaying a fallback
/// widget when an error occurs during rendering.
class ErrorBoundaryFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final child = definition['content'] ?? definition['child'];
    final fallback = definition['fallback'];
    final onError = definition['onError'] as Map<String, dynamic>?;

    if (child == null) {
      return const SizedBox.shrink();
    }

    return _ErrorBoundaryWidget(
      child: child,
      fallback: fallback,
      onError: onError,
      context: context,
    );
  }
}

class _ErrorBoundaryWidget extends StatefulWidget {
  final dynamic child;
  final dynamic fallback;
  final Map<String, dynamic>? onError;
  final RenderContext context;

  const _ErrorBoundaryWidget({
    required this.child,
    this.fallback,
    this.onError,
    required this.context,
  });

  @override
  State<_ErrorBoundaryWidget> createState() => _ErrorBoundaryWidgetState();
}

class _ErrorBoundaryWidgetState extends State<_ErrorBoundaryWidget> {
  bool _hasError = false;

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      // Render fallback widget if provided. The onError action was already
      // dispatched once in the post-frame callback that flipped _hasError
      // (spec §2.13.11), so it must not fire again on every rebuild.
      if (widget.fallback != null) {
        try {
          return widget.context.renderer
              .renderWidget(widget.fallback, widget.context);
        } catch (_) {
          // If fallback also fails, show default error UI
        }
      }

      // Default error fallback
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 8),
            Text(
              'Something went wrong',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _retry,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    // Wrap child rendering in error catching
    try {
      return widget.context.renderer.renderWidget(widget.child, widget.context);
    } catch (e, st) {
      // Schedule state update on next frame to avoid build-during-build,
      // and dispatch onError once with the spec §2.13.11 canonical
      // `event` variable (`event.error` / `event.stack`).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _hasError = true;
        });
        if (widget.onError != null) {
          final eventContext = widget.context.createChildContext(
            variables: {
              'event': {
                'error': e.toString(),
                'stack': st.toString(),
              },
            },
          );
          widget.context.actionHandler.execute(widget.onError!, eventContext);
        }
      });
      return const SizedBox.shrink();
    }
  }

  void _retry() {
    setState(() {
      _hasError = false;
    });
  }
}
