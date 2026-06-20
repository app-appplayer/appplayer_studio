/// WebView widget factory for MCP UI DSL v1.1
///
/// Displays web content in an embedded browser view.
/// Note: Platform support varies - iOS, Android, macOS, and web supported.
library webview_factory;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
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
    final width = (properties['width'] as num?)?.toDouble();
    final height = (properties['height'] as num?)?.toDouble() ?? 300;

    // Options
    final enableJavaScript = properties['enableJavaScript'] as bool? ?? true;
    final enableZoom = properties['enableZoom'] as bool? ?? true;
    // Spec §10.18: `allowNavigation`.
    // ignore: unused_local_variable
    final allowNavigation = properties['allowNavigation'] as bool? ?? true;
    final backgroundColor =
        parseColor(properties['backgroundColor'], context) ??
            context.themeManager.getColorValue('surface') ??
            Colors.white;

    // Action handlers
    final onPageStarted = properties['onPageStarted'] as Map<String, dynamic>?;
    final onPageFinished =
        properties['onPageFinished'] as Map<String, dynamic>?;
    final onError = properties['onError'] as Map<String, dynamic>?;

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
    _loadContent();
  }

  @override
  void dispose() {
    _loadTimer?.cancel();
    super.dispose();
  }

  void _loadContent() {
    // Simulate page load start
    _notifyPageStarted();

    // Check platform support
    if (!_isPlatformSupported()) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'WebView is not supported on this platform';
      });
      _notifyError(_errorMessage!);
      return;
    }

    // Validate URL or HTML content
    if (widget.url == null && widget.html == null) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Either url or html content is required';
      });
      _notifyError(_errorMessage!);
      return;
    }

    // Simulate successful load — use a cancellable timer so teardown
    // during the 100ms window doesn't leave a pending timer.
    _loadTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _notifyPageFinished();
      }
    });
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

  void _notifyPageFinished() {
    if (widget.onPageFinished != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'url': widget.url ?? '',
          }
        },
      );
      widget.context.actionHandler
          .execute(widget.onPageFinished!, eventContext);
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
      final cs = Theme.of(context).colorScheme;
      return Container(
        color: widget.backgroundColor,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                color: cs.error,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.error),
              ),
            ],
          ),
        ),
      );
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

    // Render URL placeholder (actual WebView requires platform-specific setup)
    return Container(
      color: widget.backgroundColor,
      child: _UrlPreview(
        url: widget.url!,
        enableZoom: widget.enableZoom,
      ),
    );
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

/// URL preview placeholder
class _UrlPreview extends StatelessWidget {
  final String url;
  final bool enableZoom;

  const _UrlPreview({
    required this.url,
    required this.enableZoom,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      children: [
        // URL bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            border: Border(
              bottom: BorderSide(color: theme.dividerColor),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.lock, size: 14, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  url,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurface,
                  ),
                ),
              ),
              if (enableZoom)
                IconButton(
                  icon: const Icon(Icons.zoom_in, size: 18),
                  onPressed: () {},
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
        ),
        // Content area
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.language,
                  size: 64,
                  color: cs.onSurface.withValues(alpha: 0.4),
                ),
                const SizedBox(height: 16),
                Text(
                  'WebView Content',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Add webview_flutter to pubspec.yaml\nfor full web content rendering',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
