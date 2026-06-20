import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:appplayer_ui_view/appplayer_ui_view.dart'
    show BezelConfig, DeviceFrame;

import 'package:appplayer_studio/base.dart';

/// Snapshot of preview-panel UI state that the shell can persist into
/// `<projectPath>/prefs.json`. Strings keep the public surface stable
/// even if the panel's internal enums change.
class PreviewPrefsSnapshot {
  const PreviewPrefsSnapshot({
    this.sizeChoice,
    this.orientation,
    this.brightness,
    this.customW,
    this.customH,
  });

  /// `'mobile'` / `'tablet'` / `'pc'` / `'custom'`.
  final String? sizeChoice;

  /// `'portrait'` / `'landscape'`.
  final String? orientation;

  /// `'system'` / `'light'` / `'dark'`.
  final String? brightness;

  /// Custom logical width / height — only meaningful when
  /// [sizeChoice] is `custom`.
  final int? customW;
  final int? customH;
}

/// Per `handoff/widgets/preview_panel.md` — center column, flex. Tab bar
/// (mcp_ui · self-UI) on top, AppPlayer host frame in the middle.
/// What the host hands a [PreviewVariant.buildBody] callback so a consumer
/// can mount its own renderer inside the panel's device surface without the
/// panel knowing anything about it. The panel owns the frame / epoch /
/// transform; the consumer owns the widget.
class PreviewBodyContext {
  const PreviewBodyContext({
    required this.frame,
    required this.resetEpoch,
    required this.previewMode,
    required this.transform,
    this.selectedWidgetPath,
    this.onSelectWidget,
    this.inspectRoot,
  });

  /// The active device frame (size / bezel / DPR) the body should fit.
  final DeviceFrame frame;

  /// Combined reset + external epoch — bake into the body's key so manual
  /// refresh and reactive canonical updates both re-mount it.
  final int resetEpoch;

  /// Forced brightness override (`light` / `dark`) or null for the
  /// bundle's own theme.mode.
  final String? previewMode;

  /// Panel-owned controller for a body that wraps itself in an
  /// [InteractiveViewer]; reset when the user presses Reset view.
  final TransformationController transform;

  final WidgetPath? selectedWidgetPath;
  final ValueChanged<WidgetPath>? onSelectWidget;
  final Map<String, dynamic>? inspectRoot;
}

/// A preview renderer + how the panel should present it. The panel owns the
/// generic surface (toolbar / device frame / tracks); a consumer
/// (built-in or bundle) declares a variant to swap the mcp-ui track's body
/// and tune the chrome — the panel never branches on any domain concept
/// (e.g. project kind). Null variant = the default [PreviewMcpUi] body in a
/// framed mobile surface.
class PreviewVariant {
  const PreviewVariant({
    required this.buildBody,
    this.framed = false,
    this.customSizeOnly = false,
    this.minimalToolbar = false,
  });

  /// Builds the mcp-ui track body from the panel-provided context.
  final Widget Function(PreviewBodyContext) buildBody;

  /// Whether to wrap the body in the panel's rounded device border. False
  /// when the body draws its own chrome (e.g. its own bezel).
  final bool framed;

  /// Start in (and restrict the size picker to) a free-form custom W×H
  /// instead of the mobile/tablet/PC presets.
  final bool customSizeOnly;

  /// Hide the track tabs / orientation / refresh controls — for a body
  /// that re-mounts itself and has a single applicable track.
  final bool minimalToolbar;
}

class PreviewPanel extends StatefulWidget {
  const PreviewPanel({
    super.key,
    required this.canonical,
    this.focusPageId,
    this.focusComponentId,
    this.dashboardMode = false,
    this.selfUiFramework = SelfUiFramework.none,
    this.selfUiSimDir,
    this.initialPrefs,
    this.onPrefsChanged,
    this.selectedWidgetPath,
    this.onSelectWidget,
    this.inspectRoot,
    this.externalRefreshEpoch = 0,
    this.captureKey,
    this.variant,
  });

  /// Optional renderer override + chrome tuning (see [PreviewVariant]).
  /// Null = default [PreviewMcpUi] in a framed mobile surface.
  final PreviewVariant? variant;

  final WorkspaceCanonical canonical;
  final String? focusPageId;
  final String? focusComponentId;
  final bool dashboardMode;
  final SelfUiFramework selfUiFramework;
  final String? selfUiSimDir;

  /// Currently-selected widget path — used to highlight the node when
  /// inspect mode is on.
  final WidgetPath? selectedWidgetPath;

  /// Reports tap-to-select events from the inspector overlay.
  final ValueChanged<WidgetPath>? onSelectWidget;

  /// Root of the widget tree the inspector should resolve hits against
  /// (the focused page's `content` or component's `template`). When
  /// null the inspect toggle is hidden — there's nothing to inspect.
  final Map<String, dynamic>? inspectRoot;

  /// Bump to force the inner runtime to rebuild from canonical
  /// (combined with the panel's own internal Reset bumps in the
  /// effective epoch). The shell increments this from
  /// `bridge.onRequestPreviewRefresh` and the `vibe_preview_refresh`
  /// MCP tool — vibe's runtime currently only refreshes content via
  /// rebuild, so this is the manual lever for "I edited the canonical
  /// and want to see it now".
  final int externalRefreshEpoch;

  /// Restore the panel to a prior state — typically `project.prefs`.
  /// Null fields keep the panel's defaults.
  final PreviewPrefsSnapshot? initialPrefs;

  /// Fires after every user-driven mutation of size / orient /
  /// brightness so the shell can persist the new state. Custom W×H
  /// changes also fire (size choice flips to `'custom'`).
  final ValueChanged<PreviewPrefsSnapshot>? onPrefsChanged;

  /// `GlobalKey` the shell uses to grab a `RenderRepaintBoundary` of
  /// the live preview area for `vibe_preview_capture`. The key is
  /// owned by the shell so the bridge handler can reach it without
  /// digging into PreviewPanel's private state.
  final GlobalKey? captureKey;

  @override
  State<PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<PreviewPanel> {
  PreviewTrack _active = PreviewTrack.mcpUi;
  _DeviceSizeChoice _sizeChoice = _DeviceSizeChoice.mobile;
  _Orient _orient = _Orient.portrait;
  int _customW = 390;
  int _customH = 844;

  /// Panel-owned transform for a [PreviewVariant] body that wraps itself in
  /// an InteractiveViewer (the default [PreviewMcpUi] body ignores it).
  final TransformationController _variantTransform = TransformationController();

  @override
  void dispose() {
    _variantTransform.dispose();
    super.dispose();
  }

  /// Apply a [PreviewVariant.customSizeOnly] variant's size defaults —
  /// desktop-style custom W×H, portrait — when no saved prefs win.
  void _applyVariantSizeDefaults() {
    _sizeChoice = _DeviceSizeChoice.custom;
    _orient = _Orient.portrait;
    if (_customW <= 0) _customW = 1280;
    if (_customH <= 0) _customH = 800;
  }

  @override
  void didUpdateWidget(covariant PreviewPanel old) {
    super.didUpdateWidget(old);
    // A consumer that flips to a custom-size-only variant (e.g. App
    // Builder switching a tab from an AppPlayer app to a Studio package)
    // re-seeds the size the same way initState would on a fresh mount.
    if (old.variant?.customSizeOnly != true &&
        (widget.variant?.customSizeOnly ?? false)) {
      setState(_applyVariantSizeDefaults);
    }
  }

  @override
  void initState() {
    super.initState();
    final init = widget.initialPrefs;
    if (init != null) {
      final size = _decodeSizeChoice(init.sizeChoice);
      if (size != null) _sizeChoice = size;
      final orient = _decodeOrient(init.orientation);
      if (orient != null) _orient = orient;
      final bright = _decodeBrightness(init.brightness);
      if (bright != null) _brightness = bright;
      if (init.customW != null && init.customW! > 0) _customW = init.customW!;
      if (init.customH != null && init.customH! > 0) _customH = init.customH!;
    }
    if (widget.variant?.customSizeOnly ?? false) _applyVariantSizeDefaults();
  }

  void _emitPrefs() {
    final cb = widget.onPrefsChanged;
    if (cb == null) return;
    cb(
      PreviewPrefsSnapshot(
        sizeChoice: _encodeSizeChoice(_sizeChoice),
        orientation: _encodeOrient(_orient),
        brightness: _encodeBrightness(_brightness),
        customW: _customW,
        customH: _customH,
      ),
    );
  }

  static String _encodeSizeChoice(_DeviceSizeChoice v) {
    switch (v) {
      case _DeviceSizeChoice.mobile:
        return 'mobile';
      case _DeviceSizeChoice.tablet:
        return 'tablet';
      case _DeviceSizeChoice.desktop:
        return 'pc';
      case _DeviceSizeChoice.custom:
        return 'custom';
    }
  }

  static _DeviceSizeChoice? _decodeSizeChoice(String? v) {
    switch (v) {
      case 'mobile':
        return _DeviceSizeChoice.mobile;
      case 'tablet':
        return _DeviceSizeChoice.tablet;
      case 'pc':
        return _DeviceSizeChoice.desktop;
      case 'custom':
        return _DeviceSizeChoice.custom;
    }
    return null;
  }

  static String _encodeOrient(_Orient v) =>
      v == _Orient.landscape ? 'landscape' : 'portrait';
  static _Orient? _decodeOrient(String? v) {
    if (v == 'portrait') return _Orient.portrait;
    if (v == 'landscape') return _Orient.landscape;
    return null;
  }

  static String _encodeBrightness(_PreviewBright v) {
    switch (v) {
      case _PreviewBright.system:
        return 'system';
      case _PreviewBright.light:
        return 'light';
      case _PreviewBright.dark:
        return 'dark';
    }
  }

  static _PreviewBright? _decodeBrightness(String? v) {
    switch (v) {
      case 'system':
        return _PreviewBright.system;
      case 'light':
        return _PreviewBright.light;
      case 'dark':
        return _PreviewBright.dark;
    }
    return null;
  }

  /// Bumped whenever the user presses Reset view — fed into the preview
  /// widget's key so the framed device tears down + remounts at the
  /// device preset's initial position / scale (no zoom, no pan).
  int _viewResetEpoch = 0;
  void _resetView() {
    _variantTransform.value = Matrix4.identity();
    setState(() => _viewResetEpoch++);
  }

  /// Forced brightness for the rendered preview only — `system` defers to
  /// the bundle's own theme.mode. `light` / `dark` override theme.mode in
  /// the snapshot fed to the runtime, so the tool chrome is unaffected.
  _PreviewBright _brightness = _PreviewBright.system;
  String? _previewModeFor() {
    switch (_brightness) {
      case _PreviewBright.system:
        return null;
      case _PreviewBright.light:
        return 'light';
      case _PreviewBright.dark:
        return 'dark';
    }
  }

  DeviceFrame _currentFrame() {
    // Pick a base preset so we inherit its bezel chrome / safeArea / DPR.
    // (DeviceFrame.custom alone has no bezel, which would render the device
    // as a borderless rectangle — visually losing the screen-edge cue.)
    late DeviceFrame base;
    switch (_sizeChoice) {
      case _DeviceSizeChoice.mobile:
        base = DeviceFrame.phone;
        break;
      case _DeviceSizeChoice.tablet:
        base = DeviceFrame.tablet;
        break;
      case _DeviceSizeChoice.desktop:
        base = DeviceFrame.desktop;
        break;
      case _DeviceSizeChoice.custom:
        base = DeviceFrame.custom(
          _customW.toDouble(),
          _customH.toDouble(),
          bezel: const BezelConfig(thickness: 6, cornerRadius: 12),
        );
        break;
    }
    final logicalSize =
        _orient == _Orient.landscape
            ? Size(base.logicalSize.height, base.logicalSize.width)
            : base.logicalSize;
    return DeviceFrame(
      id: '${base.id}-${_orient.name}',
      label: '${base.label} (${_orient.name})',
      logicalSize: logicalSize,
      devicePixelRatio: base.devicePixelRatio,
      bezel: base.bezel,
      safeArea: base.safeArea,
    );
  }

  Future<void> _pickSize() async {
    // A custom-size-only variant skips the preset menu and jumps straight
    // to the custom W×H dialog — there are no meaningful presets, the user
    // just types the size they target.
    if (widget.variant?.customSizeOnly ?? false) {
      final picked = await _showCustomSizeDialog(
        context,
        initialW: _customW,
        initialH: _customH,
      );
      if (picked == null || !mounted) return;
      setState(() {
        _sizeChoice = _DeviceSizeChoice.custom;
        _customW = picked.$1;
        _customH = picked.$2;
      });
      _emitPrefs();
      return;
    }
    final selected = await _showVibeMenu<_DeviceSizeChoice>(
      context: context,
      anchor: _sizeAnchorKey,
      value: _sizeChoice,
      options: const <_DeviceSizeChoice>[
        _DeviceSizeChoice.mobile,
        _DeviceSizeChoice.tablet,
        _DeviceSizeChoice.desktop,
        _DeviceSizeChoice.custom,
      ],
      labels: const <_DeviceSizeChoice, String>{
        _DeviceSizeChoice.mobile: 'Mobile',
        _DeviceSizeChoice.tablet: 'Tablet',
        _DeviceSizeChoice.desktop: 'PC',
        _DeviceSizeChoice.custom: 'Custom…',
      },
      icons: const <_DeviceSizeChoice, IconData>{
        _DeviceSizeChoice.mobile: Icons.smartphone_outlined,
        _DeviceSizeChoice.tablet: Icons.tablet_outlined,
        _DeviceSizeChoice.desktop: Icons.monitor_outlined,
        _DeviceSizeChoice.custom: Icons.tune_outlined,
      },
    );
    if (selected == null) return;
    if (!mounted) return;
    if (selected == _DeviceSizeChoice.custom) {
      final picked = await _showCustomSizeDialog(
        context,
        initialW: _customW,
        initialH: _customH,
      );
      if (picked == null || !mounted) return;
      setState(() {
        _sizeChoice = _DeviceSizeChoice.custom;
        _customW = picked.$1;
        _customH = picked.$2;
      });
    } else {
      setState(() => _sizeChoice = selected);
    }
    _emitPrefs();
  }

  void _toggleOrient() {
    setState(() {
      _orient =
          _orient == _Orient.portrait ? _Orient.landscape : _Orient.portrait;
    });
    _emitPrefs();
  }

  Future<void> _pickBrightness() async {
    final selected = await _showVibeMenu<_PreviewBright>(
      context: context,
      anchor: _brightAnchorKey,
      value: _brightness,
      options: const <_PreviewBright>[
        _PreviewBright.system,
        _PreviewBright.light,
        _PreviewBright.dark,
      ],
      labels: const <_PreviewBright, String>{
        _PreviewBright.system: 'System',
        _PreviewBright.light: 'Light',
        _PreviewBright.dark: 'Dark',
      },
      icons: const <_PreviewBright, IconData>{
        _PreviewBright.system: Icons.brightness_auto_outlined,
        _PreviewBright.light: Icons.light_mode_outlined,
        _PreviewBright.dark: Icons.dark_mode_outlined,
      },
    );
    if (selected == null) return;
    if (!mounted) return;
    setState(() => _brightness = selected);
    _emitPrefs();
  }

  IconData _brightnessIcon() {
    switch (_brightness) {
      case _PreviewBright.system:
        return Icons.brightness_auto_outlined;
      case _PreviewBright.light:
        return Icons.light_mode_outlined;
      case _PreviewBright.dark:
        return Icons.dark_mode_outlined;
    }
  }

  final GlobalKey _sizeAnchorKey = GlobalKey();
  final GlobalKey _brightAnchorKey = GlobalKey();

  String _sizeLabel() {
    final f = _currentFrame().logicalSize;
    return '${f.width.toInt()}×${f.height.toInt()}';
  }

  String _sizeChoiceLabel() {
    switch (_sizeChoice) {
      case _DeviceSizeChoice.mobile:
        return 'Mobile';
      case _DeviceSizeChoice.tablet:
        return 'Tablet';
      case _DeviceSizeChoice.desktop:
        return 'PC';
      case _DeviceSizeChoice.custom:
        return 'Custom';
    }
  }

  IconData _sizeChoiceIcon() {
    switch (_sizeChoice) {
      case _DeviceSizeChoice.mobile:
        return Icons.smartphone_outlined;
      case _DeviceSizeChoice.tablet:
        return Icons.tablet_outlined;
      case _DeviceSizeChoice.desktop:
        return Icons.monitor_outlined;
      case _DeviceSizeChoice.custom:
        return Icons.tune_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final hasSelfUi = widget.selfUiFramework != SelfUiFramework.none;
    return Container(
      color: c.bg,
      child: Column(
        children: <Widget>[
          _TabBar(
            active: _active,
            hasSelfUi: hasSelfUi,
            onSelect: (t) => setState(() => _active = t),
            onRefresh: _resetView,
            onResetView: _resetView,
            sizeAnchorKey: _sizeAnchorKey,
            sizeChoiceIcon: _sizeChoiceIcon(),
            sizeChoiceLabel: _sizeChoiceLabel(),
            sizePixelLabel: _sizeLabel(),
            onPickSize: _pickSize,
            orientLandscape: _orient == _Orient.landscape,
            onToggleOrient: _toggleOrient,
            brightAnchorKey: _brightAnchorKey,
            brightnessIcon: _brightnessIcon(),
            onPickBrightness: _pickBrightness,
            minimalToolbar: widget.variant?.minimalToolbar ?? false,
          ),
          Expanded(
            child: RepaintBoundary(
              key: widget.captureKey,
              // An unframed variant draws its own chrome (e.g. its own
              // bezel), so the panel skips its rounded device border to
              // avoid a doubled frame.
              child:
                  (widget.variant?.framed ?? true)
                      ? _Frame(child: _content(hasSelfUi))
                      : _content(hasSelfUi),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(bool hasSelfUi) {
    switch (_active) {
      case PreviewTrack.mcpUi:
        // A consumer-declared variant owns the mcp-ui body (e.g. App
        // Builder's Studio-package preview mounts a workspace runtime).
        // The panel stays agnostic — it just hands over the surface state.
        final variant = widget.variant;
        if (variant != null) {
          return variant.buildBody(
            PreviewBodyContext(
              frame: _currentFrame(),
              resetEpoch: _viewResetEpoch + widget.externalRefreshEpoch,
              previewMode: _previewModeFor(),
              transform: _variantTransform,
              selectedWidgetPath: widget.selectedWidgetPath,
              onSelectWidget: widget.onSelectWidget,
              inspectRoot: widget.inspectRoot,
            ),
          );
        }
        return PreviewMcpUi(
          canonical: widget.canonical,
          focusPageId: widget.focusPageId,
          focusComponentId: widget.focusComponentId,
          dashboardMode: widget.dashboardMode,
          frame: _currentFrame(),
          previewMode: _previewModeFor(),
          resetEpoch: _viewResetEpoch + widget.externalRefreshEpoch,
          inspectRoot: widget.inspectRoot,
          selectedWidgetPath: widget.selectedWidgetPath,
          onSelectWidget: widget.onSelectWidget,
        );
      case PreviewTrack.selfUi:
        if (!hasSelfUi) return const _Empty();
        return PreviewSelfUi(
          framework: widget.selfUiFramework,
          simBuildDir: widget.selfUiSimDir,
        );
    }
  }
}

enum PreviewTrack { mcpUi, selfUi }

enum _DeviceSizeChoice { mobile, tablet, desktop, custom }

enum _Orient { portrait, landscape }

enum _PreviewBright { system, light, dark }

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.active,
    required this.hasSelfUi,
    required this.onSelect,
    required this.onRefresh,
    required this.onResetView,
    required this.sizeAnchorKey,
    required this.sizeChoiceIcon,
    required this.sizeChoiceLabel,
    required this.sizePixelLabel,
    required this.onPickSize,
    required this.orientLandscape,
    required this.onToggleOrient,
    required this.brightAnchorKey,
    required this.brightnessIcon,
    required this.onPickBrightness,
    this.minimalToolbar = false,
  });

  final PreviewTrack active;
  final bool hasSelfUi;
  final ValueChanged<PreviewTrack> onSelect;
  final VoidCallback onRefresh;
  final VoidCallback onResetView;
  final Key sizeAnchorKey;
  final IconData sizeChoiceIcon;
  final String sizeChoiceLabel;
  final String sizePixelLabel;
  final VoidCallback onPickSize;
  final bool orientLandscape;
  final VoidCallback onToggleOrient;
  final Key brightAnchorKey;
  final IconData brightnessIcon;
  final VoidCallback onPickBrightness;

  /// Hide the track tabs / orientation / refresh — for a variant whose
  /// body re-mounts itself and has a single applicable track.
  final bool minimalToolbar;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.borderDefault)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space3),
      child: Row(
        children: <Widget>[
          if (!minimalToolbar) ...<Widget>[
            _Tab(
              label: 'UI DSL',
              active: active == PreviewTrack.mcpUi,
              color: VibeTokens.track.mcp,
              onTap: () => onSelect(PreviewTrack.mcpUi),
            ),
            const SizedBox(width: VibeTokens.space3),
            _Tab(
              label: 'LVGL',
              active: active == PreviewTrack.selfUi,
              color: VibeTokens.track.self,
              disabled: !hasSelfUi,
              onTap: hasSelfUi ? () => onSelect(PreviewTrack.selfUi) : null,
            ),
          ],
          const Spacer(),
          if (active == PreviewTrack.mcpUi) ...<Widget>[
            _SizeButton(
              anchorKey: sizeAnchorKey,
              choiceIcon: sizeChoiceIcon,
              choiceLabel: sizeChoiceLabel,
              pixelLabel: sizePixelLabel,
              onTap: onPickSize,
            ),
            const SizedBox(width: VibeTokens.space2),
            if (!minimalToolbar)
              Tooltip(
                message:
                    orientLandscape
                        ? 'Switch to portrait'
                        : 'Switch to landscape',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onToggleOrient,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Icon(
                      orientLandscape
                          ? Icons.stay_current_landscape_outlined
                          : Icons.stay_current_portrait_outlined,
                      size: 16,
                      color: c.textSecondary,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: VibeTokens.space1),
            Tooltip(
              message: 'Preview brightness (runtime only)',
              child: GestureDetector(
                key: brightAnchorKey,
                behavior: HitTestBehavior.opaque,
                onTap: onPickBrightness,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Icon(brightnessIcon, size: 16, color: c.textSecondary),
                ),
              ),
            ),
            const SizedBox(width: VibeTokens.space2),
          ],
          if (!minimalToolbar)
            IconButton(
              tooltip: 'Refresh preview',
              iconSize: 16,
              icon: Icon(Icons.refresh_outlined, color: c.textSecondary),
              onPressed: onRefresh,
            ),
          IconButton(
            tooltip: 'Reset view (zoom & pan)',
            iconSize: 16,
            icon: Icon(
              Icons.center_focus_strong_outlined,
              color: c.textSecondary,
            ),
            onPressed: onResetView,
          ),
        ],
      ),
    );
  }
}

/// Compact pill that opens the device-size showMenu (vibe pattern).
class _SizeButton extends StatelessWidget {
  const _SizeButton({
    required this.anchorKey,
    required this.choiceIcon,
    required this.choiceLabel,
    required this.pixelLabel,
    required this.onTap,
  });
  final Key anchorKey;
  final IconData choiceIcon;
  final String choiceLabel;
  final String pixelLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Tooltip(
      message: 'Render size: $choiceLabel ($pixelLabel)',
      child: GestureDetector(
        key: anchorKey,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
            border: Border.all(color: c.borderDefault),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(choiceIcon, size: 13, color: c.textSecondary),
              const SizedBox(width: 6),
              Text(
                choiceLabel,
                style: vibeMono(size: 11, color: c.textPrimary),
              ),
              const SizedBox(width: 6),
              Text(
                pixelLabel,
                style: vibeMono(size: 10, color: c.textTertiary),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more, size: 12, color: c.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

/// showMenu helper — anchored under the trigger, vibe styling, no animation.
/// Optionally renders an [icons] glyph before each option's label.
Future<T?> _showVibeMenu<T>({
  required BuildContext context,
  required Key anchor,
  required T value,
  required List<T> options,
  required Map<T, String> labels,
  Map<T, IconData>? icons,
}) async {
  final c = VibeTokens.colorOf(context);
  final box = (anchor as GlobalKey).currentContext?.findRenderObject();
  if (box is! RenderBox) return null;
  final overlayBox =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final overlaySize = overlayBox.size;
  final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
  final size = box.size;
  final anchorRect = Rect.fromLTWH(
    offset.dx,
    offset.dy + size.height + 2,
    size.width,
    0,
  );
  return showMenu<T>(
    context: context,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    menuPadding: EdgeInsets.zero,
    color: c.elevated,
    constraints: const BoxConstraints(minWidth: 140),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
      side: BorderSide(color: c.borderStrong),
    ),
    position: RelativeRect.fromRect(anchorRect, Offset.zero & overlaySize),
    items: <PopupMenuEntry<T>>[
      for (final opt in options)
        PopupMenuItem<T>(
          value: opt,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: <Widget>[
              if (icons != null) ...<Widget>[
                Icon(
                  icons[opt] ?? Icons.circle_outlined,
                  size: 13,
                  color: opt == value ? c.mint : c.textSecondary,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                labels[opt] ?? '$opt',
                style: vibeMono(
                  size: 11,
                  color: opt == value ? c.mint : c.textPrimary,
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// Asks for custom W × H pixel dimensions. Returns `(w, h)` or null.
Future<(int, int)?> _showCustomSizeDialog(
  BuildContext context, {
  required int initialW,
  required int initialH,
}) async {
  final wCtrl = TextEditingController(text: '$initialW');
  final hCtrl = TextEditingController(text: '$initialH');
  final c = VibeTokens.colorOf(context);
  final result = await showDialog<(int, int)?>(
    context: context,
    builder:
        (ctx) => Dialog(
          backgroundColor: c.surface2,
          child: SizedBox(
            width: 320,
            child: Padding(
              padding: const EdgeInsets.all(VibeTokens.space4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Custom render size',
                    style: TextStyle(
                      fontFamily: VibeTokens.fontSans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: VibeTokens.space3),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: wCtrl,
                          autofocus: true,
                          keyboardType: TextInputType.number,
                          style: vibeMono(size: 12, color: c.textPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Width (px)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: VibeTokens.space3),
                      Expanded(
                        child: TextField(
                          controller: hCtrl,
                          keyboardType: TextInputType.number,
                          style: vibeMono(size: 12, color: c.textPrimary),
                          decoration: const InputDecoration(
                            labelText: 'Height (px)',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: VibeTokens.space4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(null),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: VibeTokens.space2),
                      FilledButton(
                        onPressed: () {
                          final w = int.tryParse(wCtrl.text.trim());
                          final h = int.tryParse(hCtrl.text.trim());
                          if (w == null || w <= 0 || h == null || h <= 0) {
                            Navigator.of(ctx).pop(null);
                            return;
                          }
                          Navigator.of(ctx).pop((w, h));
                        },
                        child: const Text('Apply'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
  );
  return result;
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.active,
    required this.color,
    this.disabled = false,
    this.onTap,
  });

  final String label;
  final bool active;
  final Color color;
  final bool disabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textColor =
        disabled
            ? VibeTokens.colorOf(context).textTertiary
            : active
            ? VibeTokens.colorOf(context).textPrimary
            : VibeTokens.colorOf(context).textSecondary;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 80,
        height: 36,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: <Widget>[
            Center(
              child: Text(
                label,
                // Use GoogleFonts.inter so the tab text picks up the same
                // typeface the rest of the chrome (titlebar, statusbar,
                // properties) loads — a raw `fontFamily: 'Inter'` falls
                // back to the system font when the asset isn't bundled,
                // which made the tab labels look different.
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: textColor,
                ),
              ),
            ),
            Container(
              height: 2,
              width: 32,
              color: active ? color : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    // The frame is the full center canvas — no width/height cap. The
    // InteractiveViewer inside [UiView] inherits this size, so zoom and
    // pan operate against the whole area; the rendered device sits at its
    // logical size in the middle and scales relative to the full canvas.
    return Padding(
      padding: const EdgeInsets.all(VibeTokens.space6),
      child: Container(
        constraints: const BoxConstraints.expand(),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(VibeTokens.radiusXl),
          border: Border.all(color: c.borderStrong),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'self-UI track is inactive',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: VibeTokens.colorOf(context).textTertiary,
        ),
      ),
    );
  }
}
