import 'package:flutter/widgets.dart';

import '../capabilities/runtime_capabilities.dart';
import '../renderer/render_context.dart';

/// Draws nothing, and reports once that the behaviour this widget declares is
/// not available here (spec §6.13.2).
///
/// A widget, not a bare `SizedBox`, because the report has to happen **after**
/// the frame: firing the document's action during build throws, and catching
/// that throw quietly would lose the failure a second time.
///
/// Shared rather than copied into each factory: the widgets that need it
/// (`map`, `lottieAnimation`, `mediaPlayer`, `webView`, `pdfViewer`) must all
/// behave identically here, and four near-copies is how one of them ends up
/// drawing something again.
class CapabilityAbsent extends StatefulWidget {
  const CapabilityAbsent({
    super.key,
    required this.capability,
    required this.onError,
    required this.renderContext,
  });

  final RuntimeCapability capability;

  /// The document's declared error action, if it wrote one.
  final Map<String, dynamic>? onError;

  final RenderContext renderContext;

  @override
  State<CapabilityAbsent> createState() => _CapabilityAbsentState();
}

class _CapabilityAbsentState extends State<CapabilityAbsent> {
  @override
  void initState() {
    super.initState();
    final onError = widget.onError;
    if (onError == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final failure = CapabilityUnavailable(widget.capability);
      final child = widget.renderContext.createChildContext(
        variables: {
          'event': {
            'code': 'CAPABILITY_UNAVAILABLE',
            'message': failure.toString(),
            // Widget-level errors are spelled `event.error` in the widget
            // sections of the spec; both are carried so a document written
            // against either reads the same failure.
            'error': failure.toString(),
          },
        },
      );
      widget.renderContext.actionHandler.execute(onError, child);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Routes a hosted surface's events to the actions the document declared.
SurfaceEvents surfaceEventsFor(
  Map<String, dynamic> properties,
  RenderContext context,
) =>
    SurfaceEvents((name, payload) {
      final action = properties[name];
      if (action is! Map) return;
      final child = context.createChildContext(variables: {'event': payload});
      context.actionHandler.execute(Map<String, dynamic>.from(action), child);
    });

/// Bytes for asset forms a platform surface cannot fetch itself — the same
/// reader that already makes `bundle://` images work.
SurfaceAssets surfaceAssetsFor(RenderContext context) =>
    SurfaceAssets((ref) => context.assetResolver.bytesFor(ref));
