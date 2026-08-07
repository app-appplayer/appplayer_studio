/// WebView widget factory for MCP UI DSL v1.1
///
/// Displays web content in an embedded browser view.
/// Note: Platform support varies - iOS, Android, macOS, and web supported.
library webview_factory;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../capability_absent.dart';
import '../widget_factory.dart';

/// Factory for WebView widgets
class WebViewWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties. Use nullable resolve — non-nullable String
    // generics throw when the property is absent (null).
    final url = context.resolve<String?>(properties['url']);
    final html = context.resolve<String?>(properties['html']);
    final width = (dimensionOf(properties['width'], context))?.toDouble();
    final height = (dimensionOf(properties['height'], context))?.toDouble() ?? 300;

    // Options
    final enableJavaScript = boolOf(properties['enableJavaScript'], context) ?? true;
    final enableZoom = boolOf(properties['enableZoom'], context) ?? true;
    // `allowNavigation` (§10.18) is decided by the engine, so it travels to
    // the host surface with the rest of `properties` rather than being read
    // and dropped here.
    final backgroundColor =
        parseColor(properties['backgroundColor'], context) ??
            context.themeManager.getColorValue('surface') ??
            Colors.white;

    // Action handlers
    final onPageStarted = actionOf(properties['onPageStarted'], context);
    final onPageFinished =
        actionOf(properties['onPageFinished'], context);
    final onError = actionOf(properties['onError'], context);

    // §6.13 — a web view either loads pages or says it cannot. The engine is a
    // platform power, so the host supplies the surface; the built-in path never
    // reports a load it did not perform.
    final builder = context.capabilities.webViewBuilder;
    if (builder != null) {
      return applyCommonWrappers(
        SizedBox(
          width: width,
          height: height,
          // Builder so the host always gets a live BuildContext, whatever the
          // render context was created with.
          child: Builder(
            builder: (ctx) =>
                builder(ctx, properties, surfaceEventsFor(properties, context),
                    surfaceAssetsFor(context)) ??
                const SizedBox.shrink(),
          ),
        ),
        properties,
        context,
      );
    }

    Widget webView = _WebViewWidget(
      url: url,
      html: html,
      enableJavaScript: enableJavaScript,
      enableZoom: enableZoom,
      backgroundColor: backgroundColor,
      onPageStarted: onPageStarted,
      onPageFinished: onPageFinished,
      onError: onError,
      context: context,
    );

    webView = SizedBox(
      width: width,
      height: height,
      child: webView,
    );

    return applyCommonWrappers(webView, properties, context);
  }
}

class _WebViewWidget extends StatefulWidget {
  final String? url;
  final String? html;
  final bool enableJavaScript;
  final bool enableZoom;
  final Color backgroundColor;
  final Map<String, dynamic>? onPageStarted;
  final Map<String, dynamic>? onPageFinished;
  final Map<String, dynamic>? onError;
  final RenderContext context;

  const _WebViewWidget({
    this.url,
    this.html,
    required this.enableJavaScript,
    required this.enableZoom,
    required this.backgroundColor,
    this.onPageStarted,
    this.onPageFinished,
    this.onError,
    required this.context,
  });

  @override
  State<_WebViewWidget> createState() => _WebViewWidgetState();
}

class _WebViewWidgetState extends State<_WebViewWidget> {
  bool _isLoading = true;
  String? _errorMessage;
  Timer? _loadTimer;

  @override
  void initState() {
    super.initState();
    _loadContent(fromInitState: true);
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    super.dispose();
  }

  /// [fromInitState] is true on the first call, where the element is not yet
  /// mounted: assigning the fields directly is correct there, and calling
  /// `setState` is an error the framework reports as "setState() called
  /// during build". Every action dispatch is deferred to after the first
  /// frame for the same reason — a document whose `onError` writes state
  /// would otherwise rebuild mid-build.
  void _loadContent({bool fromInitState = false}) {
    void apply(VoidCallback changes) {
      if (fromInitState) {
        changes();
      } else if (mounted) {
        setState(changes);
      }
    }

    void afterFrame(VoidCallback action) {
      if (!fromInitState) {
        action();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) action();
      });
    }

    afterFrame(_notifyPageStarted);

    // Check platform support
    if (!_isPlatformSupported()) {
      apply(() {
        _isLoading = false;
        _errorMessage = 'WebView is not supported on this platform';
      });
      afterFrame(() => _notifyError(_errorMessage!));
      return;
    }

    // Validate URL or HTML content
    if (widget.url == null && widget.html == null) {
      apply(() {
        _isLoading = false;
        _errorMessage = 'Either url or html content is required';
      });
      afterFrame(() => _notifyError(_errorMessage!));
      return;
    }

    // No engine was wired, so nothing will load. §6.13.1 — this reports the
    // absence instead of announcing a page load that never happened. The old
    // path fired `onPageFinished` after 100ms and drew the URL as text, which
    // told the document the page was up.
    apply(() {
      _isLoading = false;
      _errorMessage = 'no web view capability';
    });
    afterFrame(() => _notifyError(_errorMessage!));
  }

  bool _isPlatformSupported() {
    // WebView is supported on iOS, Android, macOS, and web
    if (kIsWeb) return true;

    final platform = defaultTargetPlatform;
    return platform == TargetPlatform.iOS ||
        platform == TargetPlatform.android ||
        platform == TargetPlatform.macOS;
  }

  void _notifyPageStarted() {
    if (widget.onPageStarted != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'url': widget.url ?? '',
          }
        },
      );
      widget.context.actionHandler.execute(widget.onPageStarted!, eventContext);
    }
  }


  void _notifyError(String error) {
    if (widget.onError != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'error': error,
            'url': widget.url ?? '',
          }
        },
      );
      widget.context.actionHandler.execute(widget.onError!, eventContext);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        color: widget.backgroundColor,
        child: const Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_errorMessage != null) {
      // §6.13.2 — the failure went to `onError` and the diagnostic channel when
      // it happened. Drawing it here would put the runtime's limits in the
      // user's screen, which §6.12.4 already forbids for assets.
      return const SizedBox.shrink();
    }

    // Render HTML content if provided
    if (widget.html != null) {
      return Container(
        color: widget.backgroundColor,
        child: _HtmlPreview(
          html: widget.html!,
          enableJavaScript: widget.enableJavaScript,
        ),
      );
    }

    // No engine: nothing to show. The URL preview that used to live here was a
    // facsimile of a loaded page (§6.13.1) — it even satisfied "render".
    return const SizedBox.shrink();
  }
}

/// Simple HTML preview widget
class _HtmlPreview extends StatelessWidget {
  final String html;
  final bool enableJavaScript;

  const _HtmlPreview({
    required this.html,
    required this.enableJavaScript,
  });

  @override
  Widget build(BuildContext context) {
    // Parse and display basic HTML structure
    // For full HTML rendering, use webview_flutter package
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.blue.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                const Icon(Icons.code, size: 16, color: Colors.blue),
                const SizedBox(width: 8),
                const Text(
                  'HTML Content',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
                const Spacer(),
                if (!enableJavaScript)
                  const Chip(
                    label: Text('JS Disabled'),
                    labelStyle: TextStyle(fontSize: 10),
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Builder(builder: (ctx) {
            final theme = Theme.of(ctx);
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: theme.dividerColor),
              ),
              child: SelectableText(
                html,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

