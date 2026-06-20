/// `VbuInspectorPanel` — debug-mode inspector. Vertical layout:
///
/// 1. **Variant strip** (96px): up to 4 small cards (code / folder_zip /
///    desktop / dashboard / custom) the author can pick to inspect.
/// 2. **Toolbar** (36px): size / orientation / brightness (mirrors
///    `VbuPreviewMcpUi`).
/// 3. **Render split** (flex): two panes — left renders the live target
///    (caller supplies via [renderChild]), right shows the wire-frame
///    log (caller supplies via [logChild]).
///
/// The actual render-tree walker (RenderMetadata) lives in the host's
/// `vibe_studio_base/src/widgets/inspector_render.dart` factory; this
/// atom only owns chrome and selection state. Slot widgets are fed via
/// `renderChild` / `logChild`.
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

class VbuInspectorVariant {
  const VbuInspectorVariant({
    required this.id,
    required this.label,
    this.icon,
    this.transport,
    this.status = VbuInspectorVariantStatus.notBuilt,
  });

  final String id;
  final String label;

  /// Material icon name (e.g. `code`, `folder_zip`, `desktop_windows`,
  /// `dashboard_customize`). Resolved by the factory to an [IconData].
  final IconData? icon;

  /// Transport label (e.g. `stdio`, `http`, `sse`). Rendered as a small
  /// mono caption below the variant label. Null = hidden.
  final String? transport;

  /// Card-state status. Determines the right-hand icon (play / disabled
  /// / error / hourglass) and the secondary tone of the card body.
  final VbuInspectorVariantStatus status;
}

/// Variant card status. Maps to a right-hand icon + tone:
/// - notBuilt: greyed, no icon (the card is dim)
/// - idle: mint play icon (ready to launch)
/// - spawning: amber hourglass (in progress)
/// - running: mint stop icon (running, click to stop)
/// - error: coral error icon
enum VbuInspectorVariantStatus { notBuilt, idle, spawning, running, error }

class VbuInspectorPanel extends StatelessWidget {
  const VbuInspectorPanel({
    super.key,
    this.variants = const <VbuInspectorVariant>[],
    this.activeVariantId,
    this.onVariantChange,
    this.deviceSize,
    this.orientation = 'portrait',
    this.brightness = 'auto',
    this.onSizeChange,
    this.onOrientChange,
    this.onBrightnessChange,
    this.renderChild,
    this.logChild,
  });

  final List<VbuInspectorVariant> variants;
  final String? activeVariantId;
  final ValueChanged<String>? onVariantChange;

  final String? deviceSize;
  final String orientation;
  final String brightness;
  final ValueChanged<String>? onSizeChange;
  final ValueChanged<String>? onOrientChange;
  final ValueChanged<String>? onBrightnessChange;

  /// Left pane content — typically a wired runtime mount.
  final Widget? renderChild;

  /// Right pane content — typically a scrolling wire frame log.
  final Widget? logChild;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (variants.isNotEmpty)
            _VariantStrip(
              variants: variants,
              activeId: activeVariantId,
              onSelect: onVariantChange,
            ),
          _Toolbar(
            deviceSize: deviceSize,
            orientation: orientation,
            brightness: brightness,
            onSizeChange: onSizeChange,
            onOrientChange: onOrientChange,
            onBrightnessChange: onBrightnessChange,
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: Container(
                    color: c.surface2,
                    child: renderChild ?? _EmptyHint(text: 'No render mounted'),
                  ),
                ),
                Container(width: 1, color: c.borderDefault),
                Expanded(
                  flex: 2,
                  child: Container(
                    color: c.surface,
                    child: logChild ?? _EmptyHint(text: 'No wire log'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VariantStrip extends StatelessWidget {
  const _VariantStrip({
    required this.variants,
    required this.activeId,
    required this.onSelect,
  });

  final List<VbuInspectorVariant> variants;
  final String? activeId;
  final ValueChanged<String>? onSelect;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      height: 96,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(
          top: BorderSide(color: c.borderSubtle, width: 1),
          bottom: BorderSide(color: c.borderDefault, width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: variants.length,
        separatorBuilder: (_, __) => const SizedBox(width: VbuTokens.space3),
        itemBuilder: (context, i) {
          final v = variants[i];
          final selected = v.id == activeId;
          return InkWell(
            onTap: onSelect == null ? null : () => onSelect!(v.id),
            borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
            child: AnimatedContainer(
              duration: VbuTokens.durFast,
              curve: VbuTokens.easeStandard,
              width: 168,
              height: 80,
              padding: const EdgeInsets.fromLTRB(11, 8, 8, 8),
              decoration: BoxDecoration(
                color: selected ? c.surface3 : c.surface2,
                border: Border.all(
                  color: selected ? c.amber : c.borderDefault,
                  width: selected ? 1.5 : 1,
                ),
                borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
              ),
              child: Opacity(
                opacity:
                    v.status == VbuInspectorVariantStatus.notBuilt ? 0.5 : 1.0,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          v.icon ?? Icons.dashboard_customize,
                          size: 16,
                          color: c.textPrimary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            v.label,
                            style: TextStyle(
                              fontFamily: VbuTokens.fontSans,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: c.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        _statusIcon(v.status, c),
                      ],
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            v.transport ?? v.id,
                            style: TextStyle(
                              fontFamily: VbuTokens.fontMono,
                              fontSize: 10,
                              color: c.textTertiary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (v.status == VbuInspectorVariantStatus.notBuilt)
                          Text(
                            'not built',
                            style: TextStyle(
                              fontFamily: VbuTokens.fontMono,
                              fontSize: 10,
                              color: c.textMuted,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Maps variant status to a small (14px) right-edge icon. notBuilt gets
/// no icon (the card is already dimmed); idle = play, spawning =
/// hourglass, running = stop, error = error_outline.
Widget _statusIcon(VbuInspectorVariantStatus s, dynamic c) {
  switch (s) {
    case VbuInspectorVariantStatus.notBuilt:
      return Icon(Icons.block, size: 14, color: c.textMuted);
    case VbuInspectorVariantStatus.idle:
      return Icon(Icons.play_circle_outline, size: 14, color: c.mint);
    case VbuInspectorVariantStatus.spawning:
      return Icon(Icons.hourglass_empty, size: 14, color: c.amber);
    case VbuInspectorVariantStatus.running:
      return Icon(Icons.stop_circle_outlined, size: 14, color: c.mint);
    case VbuInspectorVariantStatus.error:
      return Icon(Icons.error_outline, size: 14, color: c.coral);
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.deviceSize,
    required this.orientation,
    required this.brightness,
    required this.onSizeChange,
    required this.onOrientChange,
    required this.onBrightnessChange,
  });

  final String? deviceSize;
  final String orientation;
  final String brightness;
  final ValueChanged<String>? onSizeChange;
  final ValueChanged<String>? onOrientChange;
  final ValueChanged<String>? onBrightnessChange;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.borderDefault, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: VbuTokens.space2),
      child: Row(
        children: [
          _MiniButton(
            icon: Icons.smartphone,
            label: 'phone',
            onTap: () => onSizeChange?.call('390x844'),
          ),
          _MiniButton(
            icon: Icons.tablet,
            label: 'tablet',
            onTap: () => onSizeChange?.call('768x1024'),
          ),
          _MiniButton(
            icon: Icons.desktop_windows,
            label: 'desktop',
            onTap: () => onSizeChange?.call('1280x800'),
          ),
          const SizedBox(width: 8),
          Container(width: 1, height: 16, color: c.borderDefault),
          const SizedBox(width: 8),
          _MiniButton(
            icon: Icons.rotate_right,
            label: orientation == 'portrait' ? 'P' : 'L',
            onTap:
                () => onOrientChange?.call(
                  orientation == 'portrait' ? 'landscape' : 'portrait',
                ),
          ),
          _MiniButton(
            icon:
                brightness == 'dark'
                    ? Icons.dark_mode
                    : (brightness == 'light'
                        ? Icons.light_mode
                        : Icons.brightness_auto),
            label: brightness,
            onTap: () {
              final next =
                  brightness == 'auto'
                      ? 'light'
                      : (brightness == 'light' ? 'dark' : 'auto');
              onBrightnessChange?.call(next);
            },
          ),
          const Spacer(),
          Text(
            'INSPECTOR',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 9,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: c.amber,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatefulWidget {
  const _MiniButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  State<_MiniButton> createState() => _MiniButtonState();
}

class _MiniButtonState extends State<_MiniButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: VbuTokens.durFast,
          curve: VbuTokens.easeStandard,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: _hover ? c.surface2 : Colors.transparent,
            borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 14,
                color: _hover ? c.textPrimary : c.textSecondary,
              ),
              if (widget.label.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: c.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Center(
      child: Text(
        text,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 11,
          color: c.textTertiary,
        ),
      ),
    );
  }
}
