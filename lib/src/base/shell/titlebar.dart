import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main/chrome_bridge.dart';
import 'tokens.dart';

/// Per `handoff/widgets/titlebar.md` — 28px chrome at the top of the
/// window. Project switcher on the left, transport pill in the middle,
/// window actions on the right.
class VibeTitlebar extends StatelessWidget {
  const VibeTitlebar({
    super.key,
    required this.bundleName,
    required this.transport,
    required this.specVersion,
    this.host = '127.0.0.1',
    this.port,
    this.state = TitlebarState.idle,
    this.onPickBundle,
    this.appLabel = 'AppPlayer Builder',
    this.leftPanelVisible,
    this.onToggleLeftPanel,
    this.chromeBridge,
  });

  /// Optional bridge — when supplied and `chromeBridge.hasTabStrip`
  /// flips to true, the titlebar renders a show / hide icon on its
  /// right edge that toggles `chromeBridge.tabBarVisible`. Lets the
  /// host wire the universal-host tab strip toggle without forking
  /// the titlebar widget.
  final ChromeBridge? chromeBridge;

  final String bundleName;
  final String transport;
  final String specVersion;

  /// Tool name shown next to the mint dot on the left edge. Domain
  /// hosts override this — vibe_app_builder keeps the default
  /// "AppPlayer Builder", knowledge_builder passes "Knowledge Builder",
  /// future tools their own label.
  final String appLabel;

  /// MCP server host (defaults to localhost). Combined with [port] into
  /// the URL the user copies into AppPlayer / Claude Desktop.
  final String host;

  /// MCP server port. When null the URL pill is hidden.
  final int? port;

  final TitlebarState state;
  final VoidCallback? onPickBundle;

  /// Optional left-panel toggle. `null` hides the icon; non-null pairs
  /// (visible flag + callback) render a `panel_left_open` /
  /// `panel_left_close` icon at the very left edge of the row so every
  /// builder gets a consistent collapse handle for the chat column.
  final bool? leftPanelVisible;
  final VoidCallback? onToggleLeftPanel;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    Widget body = MetaData(
      metaData: <String, dynamic>{
        'type': 'studio.chrome.titlebar',
        'id': 'titlebar',
        'label': appLabel,
        'title': bundleName,
      },
      child: Container(
        height: VibeTokens.titlebarHeight,
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(bottom: BorderSide(color: c.borderDefault, width: 1)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space3),
        child: Row(
          children: <Widget>[
            // macOS: the native title bar is hidden (full-size content), so
            // the window's traffic-light buttons float over this bar's left
            // edge — inset to clear them.
            if (Platform.isMacOS) const SizedBox(width: 64),
            if (leftPanelVisible != null &&
                onToggleLeftPanel != null) ...<Widget>[
              Tooltip(
                message:
                    leftPanelVisible! ? 'Hide chat panel' : 'Show chat panel',
                child: InkWell(
                  onTap: onToggleLeftPanel,
                  borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      leftPanelVisible! ? Icons.menu_open : Icons.menu_outlined,
                      size: 16,
                      color: c.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: VibeTokens.space2),
            ],
            Icon(Icons.adjust, size: 14, color: c.mint),
            const SizedBox(width: VibeTokens.space2),
            Text(
              appLabel,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
            const Spacer(),
            if (port != null) ...<Widget>[
              if (chromeBridge != null)
                ValueListenableBuilder<String>(
                  valueListenable: chromeBridge!.activeMcpUrl,
                  builder: (_, activeUrl, __) {
                    // Empty (Home / no-domain) → system URL fallback.
                    final effective =
                        activeUrl.isEmpty
                            ? '$transport://$host:$port/mcp'
                            : activeUrl;
                    return _UrlPill(displayUrl: effective);
                  },
                )
              else
                _UrlPill(displayUrl: '$transport://$host:$port/mcp'),
              const SizedBox(width: VibeTokens.space2),
            ],
            _TransportPill(transport: transport, specVersion: '', state: state),
            const SizedBox(width: VibeTokens.space2),
            if (chromeBridge != null)
              ValueListenableBuilder<String>(
                valueListenable: chromeBridge!.bundleVersion,
                builder:
                    (_, ver, __) =>
                        _VersionLabel(version: ver.isEmpty ? specVersion : ver),
              )
            else
              _VersionLabel(version: specVersion),
            if (chromeBridge != null) ...<Widget>[
              ValueListenableBuilder<String>(
                valueListenable: chromeBridge!.titlebarText,
                builder: (_, txt, __) {
                  if (txt.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(left: VibeTokens.space2),
                    child: Text(
                      txt,
                      style: TextStyle(
                        fontFamily: VibeTokens.fontMono,
                        fontSize: 11,
                        color: c.textSecondary,
                      ),
                    ),
                  );
                },
              ),
            ],
            const Spacer(),
            if (chromeBridge != null) _TabBarToggle(bridge: chromeBridge!),
          ],
        ),
      ),
    );
    final bridge = chromeBridge;
    if (bridge != null) {
      body = MouseRegion(
        onEnter: (_) {
          if (bridge.hasTabStrip.value && !bridge.tabBarVisible.value) {
            bridge.peekIn();
          }
        },
        onExit: (_) {
          if (bridge.hasTabStrip.value && !bridge.tabBarVisible.value) {
            bridge.peekOut();
          }
        },
        child: body,
      );
    }
    return body;
  }
}

class _TabBarToggle extends StatelessWidget {
  const _TabBarToggle({required this.bridge});

  final ChromeBridge bridge;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return ValueListenableBuilder<bool>(
      valueListenable: bridge.hasTabStrip,
      builder: (_, hasStrip, __) {
        if (!hasStrip) return const SizedBox.shrink();
        return ValueListenableBuilder<bool>(
          valueListenable: bridge.tabBarVisible,
          builder:
              (_, visible, __) => Tooltip(
                message: visible ? 'Hide tab bar' : 'Show tab bar',
                child: InkWell(
                  onTap: () => bridge.tabBarVisible.value = !visible,
                  borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      visible
                          ? Icons.unfold_less_outlined
                          : Icons.unfold_more_outlined,
                      size: 16,
                      color: c.textSecondary,
                    ),
                  ),
                ),
              ),
        );
      },
    );
  }
}

/// Version label — separate from the transport pill since transport
/// (http / sse) and version are independent. Light style — no pill
/// chrome around it so it reads as metadata, not an action.
class _VersionLabel extends StatelessWidget {
  const _VersionLabel({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    if (version.isEmpty) return const SizedBox.shrink();
    return Text(
      version,
      style: TextStyle(
        fontFamily: VibeTokens.fontMono,
        fontSize: 11,
        color: c.textTertiary,
      ),
    );
  }
}

enum TitlebarState { idle, patching, conflict, disconnected }

/// Click-to-copy URL pill — gives the user a quick way to wire the
/// active server URL into AppPlayer or another MCP client. Renders the
/// full URL (including the `/mcp` Streamable HTTP endpoint path) and
/// copies the same string verbatim on tap.
class _UrlPill extends StatelessWidget {
  const _UrlPill({required this.displayUrl});

  /// Full URL including `/mcp` path. Used both for the visible label
  /// (host:port[/path] form rendered below) and the clipboard payload.
  final String displayUrl;

  String get _label {
    // Strip scheme for a tighter pill — keep host:port[/path].
    final uri = Uri.tryParse(displayUrl);
    if (uri == null) return displayUrl;
    final host = uri.host;
    final port = uri.hasPort ? ':${uri.port}' : '';
    final path = uri.path.isEmpty ? '' : uri.path;
    return '$host$port$path';
  }

  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await Clipboard.setData(ClipboardData(text: displayUrl));
    messenger?.showSnackBar(
      SnackBar(
        content: Text('Copied $displayUrl'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Tooltip(
      message: 'MCP server URL — click to copy',
      child: InkWell(
        onTap: () => _copy(context),
        borderRadius: BorderRadius.circular(VibeTokens.radiusFull),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space2,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(VibeTokens.radiusFull),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.link_outlined, size: 12, color: c.textSecondary),
              const SizedBox(width: 4),
              Text(
                _label,
                style: TextStyle(
                  fontFamily: VibeTokens.fontMono,
                  fontSize: 11,
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TransportPill extends StatelessWidget {
  const _TransportPill({
    required this.transport,
    required this.specVersion,
    required this.state,
  });

  final String transport;
  final String specVersion;
  final TitlebarState state;

  Color _dotColor() {
    switch (state) {
      case TitlebarState.idle:
        return VibeTokens.status.ok;
      case TitlebarState.patching:
        return VibeTokens.status.warn;
      case TitlebarState.conflict:
        return VibeTokens.status.error;
      case TitlebarState.disconnected:
        return VibeTokens.color.textTertiary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space2,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(VibeTokens.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: _dotColor(),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: VibeTokens.space2),
          Text(
            transport,
            style: TextStyle(
              fontFamily: VibeTokens.fontMono,
              fontSize: 11,
              color: c.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
