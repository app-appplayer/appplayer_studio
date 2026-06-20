/// `VbuPreviewMcpUi` — domain-side preview for the bundle currently being
/// authored. Renders a device-frame chrome with a top toolbar (size /
/// orientation / brightness / refresh) and a body slot. The body
/// content is supplied via [child] (e.g. an embedded `MCPUIRuntime`
/// mount or a placeholder), so the atom itself stays free of runtime
/// dependencies — the real-mount factory lives in `vibe_studio_base`
/// (see `_VbuPreviewMcpUiPlaceholderFactory`) and feeds the resolved
/// runtime in via the child slot once available.
///
/// When [child] is null the atom paints a placeholder: device icon +
/// meta (bundleId · uiPath · deviceSize · inspector flag). This is the
/// state shown while the real factory is still TODO (cherry inbox).
library;

import 'package:flutter/material.dart';

import '../tokens.dart';

class VbuPreviewMcpUi extends StatelessWidget {
  const VbuPreviewMcpUi({
    super.key,
    this.bundleId,
    this.uiPath = 'ui/app.json',
    this.deviceSize,
    this.orientation = 'portrait',
    this.brightness = 'auto',
    this.showInspector = false,
    this.onSizeChange,
    this.onOrientChange,
    this.onBrightnessChange,
    this.onRefresh,
    this.child,
  });

  final String? bundleId;
  final String uiPath;

  /// `390x844` (iPhone 14), `1280x800` (desktop), `768x1024` (tablet),
  /// or any `<w>x<h>`. Drives the inner frame size when non-null.
  final String? deviceSize;

  /// `portrait` / `landscape` — flips the deviceSize axes.
  final String orientation;

  /// `auto` / `light` / `dark` — picked by the wired factory to drive
  /// the runtime's theme.mode override. The atom only renders the
  /// icon for the current choice.
  final String brightness;

  final bool showInspector;

  final ValueChanged<String>? onSizeChange;
  final ValueChanged<String>? onOrientChange;
  final ValueChanged<String>? onBrightnessChange;
  final VoidCallback? onRefresh;

  /// Body content. When non-null the atom renders this inside the
  /// device frame. When null the placeholder body fires instead.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            deviceSize: deviceSize,
            orientation: orientation,
            brightness: brightness,
            showInspector: showInspector,
            onSizeChange: onSizeChange,
            onOrientChange: onOrientChange,
            onBrightnessChange: onBrightnessChange,
            onRefresh: onRefresh,
          ),
          Expanded(
            child: Center(
              child: _DeviceFrame(
                deviceSize: deviceSize,
                orientation: orientation,
                child:
                    child ??
                    _Placeholder(
                      bundleId: bundleId,
                      uiPath: uiPath,
                      deviceSize: deviceSize,
                      showInspector: showInspector,
                    ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.deviceSize,
    required this.orientation,
    required this.brightness,
    required this.showInspector,
    required this.onSizeChange,
    required this.onOrientChange,
    required this.onBrightnessChange,
    required this.onRefresh,
  });

  final String? deviceSize;
  final String orientation;
  final String brightness;
  final bool showInspector;
  final ValueChanged<String>? onSizeChange;
  final ValueChanged<String>? onOrientChange;
  final ValueChanged<String>? onBrightnessChange;
  final VoidCallback? onRefresh;

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
          Text(
            'UI DSL',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: c.textSecondary,
            ),
          ),
          const Spacer(),
          _SizeButton(deviceSize: deviceSize, onSizeChange: onSizeChange),
          const SizedBox(width: 6),
          _IconAction(
            icon:
                orientation == 'portrait'
                    ? Icons.stay_current_portrait_outlined
                    : Icons.stay_current_landscape_outlined,
            tooltip: 'Rotate ($orientation)',
            onTap:
                () => onOrientChange?.call(
                  orientation == 'portrait' ? 'landscape' : 'portrait',
                ),
          ),
          _IconAction(
            icon: _brightnessIconOutlined(brightness),
            tooltip: 'Theme: $brightness',
            onTap: () => onBrightnessChange?.call(_nextBrightness(brightness)),
          ),
          if (showInspector) ...[
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'INSPECTOR',
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: c.amber,
                ),
              ),
            ),
          ],
          _IconAction(
            icon: Icons.refresh_outlined,
            tooltip: 'Reload preview',
            onTap: onRefresh,
          ),
        ],
      ),
    );
  }

  IconData _brightnessIconOutlined(String mode) {
    switch (mode) {
      case 'light':
        return Icons.light_mode_outlined;
      case 'dark':
        return Icons.dark_mode_outlined;
      case 'auto':
      default:
        return Icons.brightness_auto_outlined;
    }
  }

  String _nextBrightness(String mode) {
    switch (mode) {
      case 'auto':
        return 'light';
      case 'light':
        return 'dark';
      case 'dark':
      default:
        return 'auto';
    }
  }
}

/// Compact pill that opens the device-size showMenu (Mobile / Tablet /
/// PC / Custom…). Mirrors vibe_studio_base's preview_panel `_SizeButton`.
class _SizeButton extends StatelessWidget {
  const _SizeButton({required this.deviceSize, required this.onSizeChange});

  final String? deviceSize;
  final ValueChanged<String>? onSizeChange;

  String get _label {
    final w = _parseWidth(deviceSize);
    if (w == null) return 'Custom';
    if (w <= 600) return 'Mobile';
    if (w <= 900) return 'Tablet';
    return 'PC';
  }

  IconData get _icon {
    final w = _parseWidth(deviceSize);
    if (w == null) return Icons.tune_outlined;
    if (w <= 600) return Icons.smartphone_outlined;
    if (w <= 900) return Icons.tablet_outlined;
    return Icons.monitor_outlined;
  }

  String? get _pixel {
    if (deviceSize == null || deviceSize == 'custom') return null;
    return deviceSize;
  }

  double? _parseWidth(String? sz) {
    if (sz == null || sz == 'custom') return null;
    final parts = sz.split('x');
    if (parts.length != 2) return null;
    return double.tryParse(parts[0]);
  }

  Future<void> _open(BuildContext context) async {
    final c = VbuTokens.colorOf(context);
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final origin = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final size = renderBox.size;
    final position = RelativeRect.fromLTRB(
      origin.dx,
      origin.dy + size.height + 2,
      overlay.size.width - origin.dx - size.width,
      overlay.size.height - origin.dy - size.height,
    );
    final selected = await showMenu<String>(
      context: context,
      position: position,
      color: c.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
        side: BorderSide(color: c.borderDefault),
      ),
      items: <PopupMenuEntry<String>>[
        _menuItem(
          '390x844',
          'Mobile',
          Icons.smartphone_outlined,
          _label == 'Mobile',
        ),
        _menuItem(
          '768x1024',
          'Tablet',
          Icons.tablet_outlined,
          _label == 'Tablet',
        ),
        _menuItem('1280x800', 'PC', Icons.monitor_outlined, _label == 'PC'),
        _menuItem('custom', 'Custom…', Icons.tune_outlined, _label == 'Custom'),
      ],
    );
    if (selected != null) onSizeChange?.call(selected);
  }

  PopupMenuItem<String> _menuItem(
    String value,
    String label,
    IconData icon,
    bool selected,
  ) {
    return PopupMenuItem<String>(
      value: value,
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: _MenuRow(icon: icon, label: label, selected: selected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Tooltip(
      message:
          _pixel == null
              ? 'Render size: $_label'
              : 'Render size: $_label ($_pixel)',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _open(context),
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
            border: Border.all(color: c.borderDefault),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon, size: 13, color: c.textSecondary),
              const SizedBox(width: 6),
              Text(
                _label,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 11,
                  color: c.textPrimary,
                ),
              ),
              if (_pixel != null) ...[
                const SizedBox(width: 6),
                Text(
                  _pixel!,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 10,
                    color: c.textTertiary,
                  ),
                ),
              ],
              const SizedBox(width: 2),
              Icon(Icons.expand_more, size: 12, color: c.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.selected,
  });

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: selected ? c.mint : c.textSecondary),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontFamily: VbuTokens.fontSans,
            fontSize: 12,
            color: selected ? c.mint : c.textPrimary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        if (selected) ...[
          const SizedBox(width: 12),
          Icon(Icons.check, size: 12, color: c.mint),
        ],
      ],
    );
  }
}

/// Small icon-only action button with hover surface highlight. Replaces
/// the previous labelled `_PresetButton` for orient / brightness /
/// refresh — those are icon-only in the real PreviewPanel.
class _IconAction extends StatefulWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
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
            child: Icon(
              widget.icon,
              size: 16,
              color: _hover ? c.textPrimary : c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceFrame extends StatelessWidget {
  const _DeviceFrame({
    required this.deviceSize,
    required this.orientation,
    required this.child,
  });

  final String? deviceSize;
  final String orientation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final size = _parseSize(deviceSize, orientation);
    return Padding(
      padding: const EdgeInsets.all(VbuTokens.space4),
      child: Container(
        width: size?.width,
        height: size?.height,
        decoration: BoxDecoration(
          color: c.surface3,
          border: Border.all(color: c.borderStrong, width: 6),
          borderRadius: BorderRadius.circular(VbuTokens.radiusLg + 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }

  Size? _parseSize(String? sz, String orient) {
    if (sz == null || sz == 'custom') return null;
    final parts = sz.split('x');
    if (parts.length != 2) return null;
    final w = double.tryParse(parts[0]);
    final h = double.tryParse(parts[1]);
    if (w == null || h == null) return null;
    final landscape = orient == 'landscape';
    return Size(landscape ? h : w, landscape ? w : h);
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.bundleId,
    required this.uiPath,
    required this.deviceSize,
    required this.showInspector,
  });

  final String? bundleId;
  final String uiPath;
  final String? deviceSize;
  final bool showInspector;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(VbuTokens.space5),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.smartphone, size: 40, color: c.textTertiary),
            const SizedBox(height: VbuTokens.space3),
            Text(
              'VbuPreviewMcpUi placeholder',
              style: TextStyle(
                fontFamily: VbuTokens.fontSans,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(height: VbuTokens.space1),
            Text(
              'bundleId: ${bundleId ?? "<active>"}  ·  '
              'uiPath: $uiPath  ·  '
              'device: ${deviceSize ?? "fit"}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textTertiary,
              ),
            ),
            const SizedBox(height: VbuTokens.space3),
            Text(
              'Wire factory: registerVbuWidgets → '
              '_VbuPreviewMcpUiFactory',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 10,
                color: c.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
