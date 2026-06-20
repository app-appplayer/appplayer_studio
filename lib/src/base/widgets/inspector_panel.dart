// Vibe Inspector — debug surface that connects to a built MCP server,
// renders its ApplicationDefinition + DashboardConfig live, and shows
// the JSON-RPC frame log. Phase 1B-2 / 2A: variant cards spawn HTTP
// processes (and `mcp_client` owns the stdio spawn), then connect a
// client. Phase 2B will render the connected ApplicationDefinition.
//
// Card style mirrors `overview_strip._Card` — same width / radius /
// LTRB padding / left colour stripe — so editor and debug share the
// same visual rhythm.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:path/path.dart' as p;

import 'package:appplayer_studio/base.dart';
export 'inspector_render.dart' show InspectorSize, InspectorOrient;

/// Variants vibe knows how to build, in display order. Each is a
/// directory under `<projectPath>/build/`. `defaultTransport` matches
/// the variant's natural launch contract: headless binaries default to
/// stdio (host-spawn), Flutter apps default to streamable HTTP (a GUI
/// is the primary surface; the MCP server runs alongside for external
/// clients).
const List<_VariantSpec> _variants = <_VariantSpec>[
  _VariantSpec(
    slug: 'inline',
    label: 'Inline',
    icon: Icons.code,
    isNative: false,
  ),
  _VariantSpec(
    slug: 'bundle',
    label: 'Bundle',
    icon: Icons.folder_zip_outlined,
    isNative: false,
  ),
  _VariantSpec(
    slug: 'native_inline',
    label: 'Native Inline',
    icon: Icons.desktop_windows_outlined,
    isNative: true,
  ),
  _VariantSpec(
    slug: 'native_bundle',
    label: 'Native Bundle',
    icon: Icons.dashboard_customize_outlined,
    isNative: true,
  ),
];

class _VariantSpec {
  const _VariantSpec({
    required this.slug,
    required this.label,
    required this.icon,
    required this.isNative,
  });
  final String slug;
  final String label;
  final IconData icon;
  final bool isNative;
}

/// Default transport for every variant — stdio matches the host-spawn
/// contract that vibe-built binaries support uniformly. Right-click a
/// card to switch.
const InspectorTransport _defaultTransport = InspectorTransport.stdio;

class InspectorPanel extends StatefulWidget {
  const InspectorPanel({
    super.key,
    required this.projectPath,
    this.sessions,
    this.captureKey,
  });

  /// Currently-open project root, or `null` when no project is open.
  final String? projectPath;

  /// Shell-owned session manager. When non-null, the panel binds to
  /// it and skips `dispose` — connections + wire log survive an
  /// editor↔debug toggle. When null the panel owns a private
  /// instance (legacy / test usage).
  final InspectorSessionManager? sessions;

  /// GlobalKey anchored on the rendered surface so the bridge's
  /// `vibe_layout_snapshot` handler can find it via
  /// `key.currentContext.findRenderObject()` and walk the inspector's
  /// `RenderMetaData` tree.
  final GlobalKey? captureKey;

  @override
  State<InspectorPanel> createState() => _InspectorPanelState();
}

class _InspectorPanelState extends State<InspectorPanel> {
  late final InspectorSessionManager _sessions;
  // True when this panel created its own SessionManager (no shell-
  // owned manager passed in). Drives `dispose` cleanup so we don't
  // tear down a manager owned by the shell.
  late final bool _ownsSessions;
  // Per-variant transport selection. Right-click a card to change.
  // Defaults to stdio for every variant; the active session uses
  // whatever was selected when `connect` started.
  final Map<String, InspectorTransport> _transports =
      <String, InspectorTransport>{};
  // Render/log split — fraction of horizontal width given to render.
  // Drag the divider to resize. Persisted only in-memory (across
  // editor↔debug switches in the same session).
  double _renderFraction = 0.5;

  // Frame controls — mirrors preview_panel toolbar UX.
  InspectorSize _size = InspectorSize.mobile;
  InspectorOrient _orient = InspectorOrient.portrait;
  InspectorBright _bright = InspectorBright.system;
  int _customW = 390;
  int _customH = 844;
  int _resetEpoch = 0;
  final GlobalKey _sizeAnchorKey = GlobalKey();
  final GlobalKey _brightAnchorKey = GlobalKey();

  InspectorTransport _transportFor(String slug) =>
      _transports[slug] ?? _defaultTransport;

  @override
  void initState() {
    super.initState();
    final external = widget.sessions;
    if (external != null) {
      _sessions = external;
      _ownsSessions = false;
    } else {
      _sessions = InspectorSessionManager();
      _ownsSessions = true;
    }
    _sessions.addListener(_onSessionsChanged);
  }

  @override
  void dispose() {
    _sessions.removeListener(_onSessionsChanged);
    if (_ownsSessions) _sessions.dispose();
    super.dispose();
  }

  void _onSessionsChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final projectPath = widget.projectPath;
    if (projectPath == null) {
      return const _CenteredHint(
        icon: Icons.folder_off_outlined,
        title: 'No project open',
        body: 'Open a project to discover and debug its built variants.',
      );
    }
    final present = <_DiscoveredVariant>[];
    final absent = <_VariantSpec>[];
    for (final spec in _variants) {
      final dir = Directory(p.join(projectPath, 'build', spec.slug));
      if (dir.existsSync()) {
        present.add(_DiscoveredVariant(spec: spec, path: dir.path));
      } else {
        absent.add(spec);
      }
    }
    if (present.isEmpty) {
      return const _CenteredHint(
        icon: Icons.bug_report_outlined,
        title: 'No built variants',
        body:
            'Build a variant first (Build dialog · Cmd-B) — its '
            'artifact lands under `build/<slug>/` and shows up here.',
      );
    }
    final c = VibeTokens.colorOf(context);
    return Column(
      children: <Widget>[
        Container(
          height: VibeTokens.stripHeight,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(bottom: BorderSide(color: c.borderDefault)),
          ),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: VibeTokens.space3,
              vertical: VibeTokens.space2,
            ),
            children: <Widget>[
              for (final v in present) ...<Widget>[
                _VariantCard(
                  variant: v,
                  session: _sessions[v.spec.slug],
                  transport: _transportFor(v.spec.slug),
                  gated: _otherActive(v.spec.slug),
                  onToggle: () => _onVariantToggle(v),
                  onSecondaryTap: (offset) => _showTransportMenu(v, offset),
                ),
                const SizedBox(width: VibeTokens.space2),
              ],
              for (final s in absent) ...<Widget>[
                _VariantCard.absent(spec: s),
                const SizedBox(width: VibeTokens.space2),
              ],
            ],
          ),
        ),
        _InspectorToolbar(
          session: _viewSession(),
          size: _size,
          orient: _orient,
          bright: _bright,
          customW: _customW,
          customH: _customH,
          sizeAnchorKey: _sizeAnchorKey,
          brightAnchorKey: _brightAnchorKey,
          onPickSize: _pickSize,
          onToggleOrient: _toggleOrient,
          onPickBrightness: _pickBrightness,
          onResetView: _resetView,
        ),
        Expanded(
          child:
              widget.captureKey == null
                  ? _renderArea()
                  : KeyedSubtree(key: widget.captureKey, child: _renderArea()),
        ),
      ],
    );
  }

  /// The active session, if one is connected. With the explicit-stop
  /// gate there can only be one such session at a time.
  InspectorSession? _activeSession() {
    for (final s in _sessions.values) {
      if (s.status == InspectorStatus.connected) return s;
    }
    return null;
  }

  /// Most recent session worth viewing — connected first, else any
  /// `exited` / `error` session that still has frames to show. Lets
  /// the wire log + last UI snapshot stay visible after an external
  /// kill so the user can debug what the dying process said last.
  InspectorSession? _viewSession() {
    final connected = _activeSession();
    if (connected != null) return connected;
    InspectorSession? best;
    for (final s in _sessions.values) {
      if (s.frames.isEmpty) continue;
      if (best == null ||
          s.frames.last.timestamp.isAfter(best.frames.last.timestamp)) {
        best = s;
      }
    }
    return best;
  }

  Widget _renderArea() {
    final c = VibeTokens.colorOf(context);
    final view = _viewSession();
    final renderBody =
        view == null
            ? Center(
              child: Text(
                'Connect a variant to render its UI here.',
                style: vibeMono(size: 11, color: c.textTertiary),
              ),
            )
            : InspectorRender(
              key: ValueKey<String>('inspector.render:${view.slug}'),
              session: view,
              sessions: _sessions,
              size: _size,
              orient: _orient,
              brightness: _bright,
              customW: _customW,
              customH: _customH,
              resetEpoch: _resetEpoch,
            );
    return ColoredBox(
      color: c.bg,
      child: LayoutBuilder(
        builder: (ctx, box) {
          final renderW = (box.maxWidth * _renderFraction).clamp(
            160.0,
            box.maxWidth - 160,
          );
          final logW = box.maxWidth - renderW - 6;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(width: renderW, child: renderBody),
              _SplitHandle(
                onDelta: (dx) {
                  setState(() {
                    final next = (renderW + dx) / box.maxWidth;
                    _renderFraction = next.clamp(0.15, 0.85);
                  });
                },
              ),
              SizedBox(width: logW, child: _LoggerPanel(session: view)),
            ],
          );
        },
      ),
    );
  }

  Future<void> _onVariantToggle(_DiscoveredVariant v) async {
    final session = _sessions[v.spec.slug];
    // Tapping the active card stops it. Mid-flight (spawning/
    // connecting) also stops cleanly.
    if (session != null &&
        session.status != InspectorStatus.error &&
        session.status != InspectorStatus.exited) {
      await _sessions.stop(v.spec.slug);
      return;
    }
    // Single-session gate: a different variant is already active —
    // user must stop it explicitly before starting another one.
    final otherActive = _sessions.values.firstWhere(
      (s) =>
          s.slug != v.spec.slug &&
          s.status != InspectorStatus.error &&
          s.status != InspectorStatus.exited,
      orElse:
          () => InspectorSession(
            slug: '__none',
            transport: InspectorTransport.stdio,
          ),
    );
    if (otherActive.slug != '__none') {
      _toast(
        'Stop ${otherActive.slug} first — '
        'only one variant can run at a time.',
      );
      return;
    }
    final binary = _resolveBinary(v.spec, v.path);
    if (binary == null) {
      _toast('No executable found under ${v.path}');
      return;
    }
    await _sessions.connect(
      slug: v.spec.slug,
      binary: binary,
      transport: _transportFor(v.spec.slug),
    );
  }

  Future<void> _pickSize() async {
    final selected = await _showInspectorMenu<InspectorSize>(
      context: context,
      anchor: _sizeAnchorKey,
      value: _size,
      options: const <InspectorSize>[
        InspectorSize.mobile,
        InspectorSize.tablet,
        InspectorSize.desktop,
        InspectorSize.custom,
      ],
      labels: const <InspectorSize, String>{
        InspectorSize.mobile: 'Mobile',
        InspectorSize.tablet: 'Tablet',
        InspectorSize.desktop: 'PC',
        InspectorSize.custom: 'Custom…',
      },
      icons: const <InspectorSize, IconData>{
        InspectorSize.mobile: Icons.smartphone_outlined,
        InspectorSize.tablet: Icons.tablet_outlined,
        InspectorSize.desktop: Icons.monitor_outlined,
        InspectorSize.custom: Icons.tune_outlined,
      },
    );
    if (selected == null || !mounted) return;
    if (selected == InspectorSize.custom) {
      final picked = await _showInspectorCustomSizeDialog(
        context,
        initialW: _customW,
        initialH: _customH,
      );
      if (picked == null || !mounted) return;
      setState(() {
        _size = InspectorSize.custom;
        _customW = picked.$1;
        _customH = picked.$2;
      });
    } else {
      setState(() => _size = selected);
    }
  }

  void _toggleOrient() {
    setState(() {
      _orient =
          _orient == InspectorOrient.portrait
              ? InspectorOrient.landscape
              : InspectorOrient.portrait;
    });
  }

  Future<void> _pickBrightness() async {
    final selected = await _showInspectorMenu<InspectorBright>(
      context: context,
      anchor: _brightAnchorKey,
      value: _bright,
      options: const <InspectorBright>[
        InspectorBright.system,
        InspectorBright.light,
        InspectorBright.dark,
      ],
      labels: const <InspectorBright, String>{
        InspectorBright.system: 'System',
        InspectorBright.light: 'Light',
        InspectorBright.dark: 'Dark',
      },
      icons: const <InspectorBright, IconData>{
        InspectorBright.system: Icons.brightness_auto_outlined,
        InspectorBright.light: Icons.light_mode_outlined,
        InspectorBright.dark: Icons.dark_mode_outlined,
      },
    );
    if (selected == null || !mounted) return;
    setState(() => _bright = selected);
  }

  void _resetView() {
    setState(() => _resetEpoch++);
  }

  /// True iff some *other* variant currently holds the single-session
  /// slot (active = not error/exited). Drives card dim state so the
  /// gate is visible before the user even clicks.
  bool _otherActive(String slug) {
    for (final s in _sessions.values) {
      if (s.slug == slug) continue;
      if (s.status != InspectorStatus.error &&
          s.status != InspectorStatus.exited) {
        return true;
      }
    }
    return false;
  }

  /// Right-click on a card → transport menu. Selecting an item just
  /// updates the persisted choice; the next toggle will spawn with it.
  /// Style mirrors `_ChannelChipState._showContextMenu` and
  /// `VibeEnumEditor._open` (property_editors.dart) — no animation,
  /// compact 28-height items, vibeMono 11pt, `c.elevated` surface,
  /// `radiusMd` rounded border with `c.borderStrong` outline.
  Future<void> _showTransportMenu(
    _DiscoveredVariant v,
    Offset globalOffset,
  ) async {
    final c = VibeTokens.colorOf(context);
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;
    final overlaySize = overlayBox.size;
    final anchor = Rect.fromLTWH(globalOffset.dx, globalOffset.dy, 0, 0);
    final current = _transportFor(v.spec.slug);
    final values = InspectorTransport.values;
    final selected = await showMenu<int>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      menuPadding: EdgeInsets.zero,
      color: c.elevated,
      constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: <PopupMenuEntry<int>>[
        for (var i = 0; i < values.length; i++)
          PopupMenuItem<int>(
            value: i,
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 14,
                  child:
                      values[i] == current
                          ? Icon(Icons.check, size: 14, color: c.mint)
                          : null,
                ),
                const SizedBox(width: 8),
                Text(
                  values[i].label.toUpperCase(),
                  style: vibeMono(
                    size: 11,
                    color:
                        values[i] == current ? c.textPrimary : c.textSecondary,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (selected == null) return;
    final picked = values[selected];
    if (picked == current) return;
    if (!mounted) return;
    setState(() => _transports[v.spec.slug] = picked);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Headless variants land at `<dir>/<exec>` (Unix exec bit set).
  /// Native variants are macOS `.app` bundles; resolve the inner Mach-O.
  String? _resolveBinary(_VariantSpec spec, String dir) {
    if (spec.isNative) {
      if (!Platform.isMacOS) return null;
      final base = p.join(dir, 'build', 'macos', 'Build', 'Products', 'Debug');
      final products = Directory(base);
      if (!products.existsSync()) return null;
      for (final entry in products.listSync()) {
        if (entry is Directory && entry.path.endsWith('.app')) {
          final exeName = p.basenameWithoutExtension(entry.path);
          final exe = p.join(entry.path, 'Contents', 'MacOS', exeName);
          if (File(exe).existsSync()) return exe;
        }
      }
      return null;
    }
    final root = Directory(dir);
    if (!root.existsSync()) return null;
    for (final entry in root.listSync()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (name.contains('.')) continue;
      final stat = entry.statSync();
      if ((stat.mode & 0x49) != 0) return entry.path;
    }
    return null;
  }
}

class _DiscoveredVariant {
  const _DiscoveredVariant({required this.spec, required this.path});
  final _VariantSpec spec;
  final String path;
}

class _VariantCard extends StatelessWidget {
  const _VariantCard({
    required _DiscoveredVariant this.variant,
    required this.session,
    required this.transport,
    required this.gated,
    required this.onToggle,
    required this.onSecondaryTap,
  }) : spec = null,
       absent = false;
  const _VariantCard.absent({required _VariantSpec this.spec})
    : variant = null,
      session = null,
      transport = _defaultTransport,
      gated = false,
      onToggle = null,
      onSecondaryTap = null,
      absent = true;

  final _DiscoveredVariant? variant;
  final _VariantSpec? spec;
  final InspectorSession? session;
  final InspectorTransport transport;

  /// True iff another variant currently owns the single-session slot.
  /// Card stays clickable (so the user can read the toast) but renders
  /// dimmed.
  final bool gated;
  final VoidCallback? onToggle;
  final ValueChanged<Offset>? onSecondaryTap;
  final bool absent;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final s = variant?.spec ?? spec!;
    final connected = session?.status == InspectorStatus.connected;
    final cardBg = connected ? c.mint.withValues(alpha: 0.08) : c.surface2;
    final borderColor = connected ? c.mint : c.borderDefault;
    final borderWidth = connected ? 1.5 : 1.0;
    // All non-absent cards share a mint left stripe. Status colour is
    // carried separately by the play/stop icon and the dot — the bar
    // itself is the variant's "exists" affordance.
    final stripeColor = absent ? c.borderDefault : c.mint;
    final nameColor =
        absent ? c.textTertiary : (connected ? c.textPrimary : c.textSecondary);
    final dim = gated;
    return MouseRegion(
      cursor:
          absent
              ? SystemMouseCursors.basic
              : (dim ? SystemMouseCursors.forbidden : SystemMouseCursors.click),
      child: Opacity(
        opacity: dim ? 0.5 : 1.0,
        child: GestureDetector(
          onTap: absent ? null : onToggle,
          onSecondaryTapDown:
              absent || dim
                  ? null
                  : (details) => onSecondaryTap?.call(details.globalPosition),
          child: AnimatedContainer(
            duration: VibeTokens.durFast,
            curve: VibeTokens.easeStandard,
            width: VibeTokens.stripCardWidth,
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(VibeTokens.radiusLg),
              border: Border.all(color: borderColor, width: borderWidth),
            ),
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 3, color: stripeColor),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    VibeTokens.space2 + 3,
                    VibeTokens.space2,
                    VibeTokens.space2,
                    VibeTokens.space2,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(s.icon, size: 14, color: nameColor),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              s.label,
                              style: TextStyle(
                                fontFamily: VibeTokens.fontSans,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: nameColor,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!absent) _StatusDot(session: session),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Expanded(
                        child: _CardBody(
                          spec: s,
                          session: session,
                          transport: transport,
                          absent: absent,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CardBody extends StatelessWidget {
  const _CardBody({
    required this.spec,
    required this.session,
    required this.transport,
    required this.absent,
  });
  final _VariantSpec spec;
  final InspectorSession? session;
  final InspectorTransport transport;
  final bool absent;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    if (absent) {
      return _BodyContent(
        icon: Icons.block,
        iconColor: c.textTertiary,
        text: 'not built',
        textColor: c.textTertiary,
      );
    }
    final st = session?.status;
    if (st == InspectorStatus.connected) {
      return _BodyContent(
        icon: Icons.stop_circle_outlined,
        iconColor: c.coral,
        text: session!.endpointUrl ?? session!.displayLabel,
        textColor: c.textSecondary,
      );
    }
    if (st == InspectorStatus.spawning || st == InspectorStatus.connecting) {
      return _BodyContent(
        icon: Icons.hourglass_top,
        iconColor: c.amber,
        text: st == InspectorStatus.spawning ? 'spawning…' : 'connecting…',
        textColor: c.amber,
      );
    }
    if (st == InspectorStatus.error) {
      return _BodyContent(
        icon: Icons.error_outline,
        iconColor: c.coral,
        text: session?.errorMessage ?? 'error',
        textColor: c.coral,
      );
    }
    return _BodyContent(
      icon: Icons.play_circle_outline,
      iconColor: c.mint,
      text: transport.label,
      textColor: c.textTertiary,
    );
  }
}

class _BodyContent extends StatelessWidget {
  const _BodyContent({
    required this.icon,
    required this.iconColor,
    required this.text,
    required this.textColor,
  });
  final IconData icon;
  final Color iconColor;
  final String text;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned(
          left: 0,
          top: 0,
          right: 22,
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: VibeTokens.fontMono,
              fontSize: 10,
              color: textColor,
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Icon(icon, size: 22, color: iconColor),
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.session});
  final InspectorSession? session;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final st = session?.status;
    final color = switch (st) {
      InspectorStatus.connected => c.mint,
      InspectorStatus.spawning || InspectorStatus.connecting => c.amber,
      InspectorStatus.error => c.coral,
      _ => c.textTertiary,
    };
    return Icon(Icons.circle, size: 8, color: color);
  }
}

/// 6-px wide vertical drag handle for the render/log split. Cursor
/// switches to a horizontal-resize affordance on hover; mint highlight
/// while pressed.
class _SplitHandle extends StatefulWidget {
  const _SplitHandle({required this.onDelta});
  final ValueChanged<double> onDelta;
  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  bool _hover = false;
  bool _drag = false;
  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _drag = true),
        onHorizontalDragEnd: (_) => setState(() => _drag = false),
        onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
        child: SizedBox(
          width: 6,
          child: Center(
            child: Container(
              width: 1,
              color: (_hover || _drag) ? c.mint : c.borderDefault,
            ),
          ),
        ),
      ),
    );
  }
}

/// Wire log panel. Auto-scrolls to the newest frame; click a row
/// to expand its raw payload underneath. Splits across the bottom
/// of the inspector body so render + log stay visible together.
class _LoggerPanel extends StatefulWidget {
  const _LoggerPanel({required this.session});
  final InspectorSession? session;

  @override
  State<_LoggerPanel> createState() => _LoggerPanelState();
}

/// Bottom-pane tabs. The pane multiplexes wire-log viewing and
/// runtime-state poking — both tap the same MCPUIRuntime instance the
/// inspector is rendering, so showing them in adjacent tabs keeps the
/// "what was sent" / "what's stored" mental model intact.
enum _PanelTab { wire, state }

class _LoggerPanelState extends State<_LoggerPanel> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _query = TextEditingController();
  int? _expanded;

  /// Method picked by clicking a frame — every other frame whose
  /// `method` matches gets a mint stripe so the request/response/
  /// re-call chain stands out.
  String? _selectedMethod;

  /// Track whether the user is sitting at (or near) the bottom of
  /// the log. Auto-scroll only fires when this is true so reading
  /// history isn't tugged back down on each new frame.
  bool _stickToBottom = true;

  _PanelTab _tab = _PanelTab.wire;

  /// Selected runtime target for the State tab. Defaults to the APP
  /// surface when present; falls back to whichever runtime the
  /// session has bound first.
  String? _stateTarget;

  /// Live subscription to the focused runtime's state stream — fires
  /// on every set() so the tree refreshes without polling. Typed as
  /// `dynamic` because `StateChangeEvent` isn't part of the runtime
  /// package's public surface; we only need the tick.
  StreamSubscription<dynamic>? _stateSub;
  MCPUIRuntime? _stateRuntime;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 8-px slack — counts as "at bottom" if within that range.
    final atBottom =
        (_scroll.position.maxScrollExtent - _scroll.position.pixels) <= 8;
    if (atBottom != _stickToBottom) {
      _stickToBottom = atBottom;
    }
  }

  @override
  void didUpdateWidget(covariant _LoggerPanel old) {
    super.didUpdateWidget(old);
    if (_stickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
    // Resync the State-tab subscription whenever the focused runtime
    // pointer might have changed (session swap, snapshot rebuild,
    // newly-bound surface).
    _ensureStateSubscription();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _query.dispose();
    _stateSub?.cancel();
    super.dispose();
  }

  /// Keep the state-stream subscription pointed at the runtime the
  /// user actually wants to see. Pulls the runtime out of the session
  /// for [_stateTarget] (defaulting to APP when unset / missing) and
  /// re-subscribes whenever the instance differs from the cached one.
  void _ensureStateSubscription() {
    final session = widget.session;
    if (session == null) {
      _detachStateSubscription();
      return;
    }
    final targets = session.runtimes.keys.toList();
    if (targets.isEmpty) {
      _detachStateSubscription();
      return;
    }
    final target =
        _stateTarget != null && targets.contains(_stateTarget)
            ? _stateTarget!
            : (targets.contains('mcp-ui:app') ? 'mcp-ui:app' : targets.first);
    if (_stateTarget != target) {
      _stateTarget = target;
    }
    final runtime = session.runtimes[target];
    if (identical(runtime, _stateRuntime)) return;
    _stateSub?.cancel();
    _stateRuntime = runtime;
    _stateSub = runtime?.stateManager.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _detachStateSubscription() {
    _stateSub?.cancel();
    _stateSub = null;
    _stateRuntime = null;
    _stateTarget = null;
  }

  /// Save the current session's wire-log frames to a `.fixture.json`
  /// file. The full payload of every frame round-trips so a later
  /// replay can compare actual vs expected. Default save location is
  /// `<projectRoot>/fixtures/` (auto-created) so fixtures live with
  /// the project they're testing.
  Future<void> _exportFixture(InspectorSession session) async {
    final projectPath = _projectPath;
    String? initialDir;
    if (projectPath != null) {
      final fixturesDir = Directory(p.join(projectPath, 'fixtures'));
      if (!await fixturesDir.exists()) {
        await fixturesDir.create(recursive: true);
      }
      initialDir = fixturesDir.path;
    }
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export wire log fixture',
      fileName:
          '${session.slug}-${DateTime.now().millisecondsSinceEpoch}'
          '.fixture.json',
      type: FileType.custom,
      allowedExtensions: <String>['json'],
      initialDirectory: initialDir,
    );
    if (path == null) return;
    final body = <String, dynamic>{
      'version': 1,
      'slug': session.slug,
      'transport': session.transport.label,
      'recordedAt': DateTime.now().toIso8601String(),
      'frames': <Map<String, dynamic>>[
        for (final f in session.frames) f.toJson(),
      ],
    };
    final dest = path.endsWith('.json') ? path : '$path.json';
    await File(
      dest,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(body));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Saved ${p.basename(dest)}',
          style: const TextStyle(fontSize: 12),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Pick a fixture file and replay its requests against the active
  /// session. The replay walks `tools/call` requests in order and
  /// compares the live response to the recorded one — divergences
  /// surface as `replay FAIL` frames in the wire log.
  Future<void> _replayFixture(InspectorSession session) async {
    final projectPath = _projectPath;
    String? initialDir;
    if (projectPath != null) {
      final fixturesDir = Directory(p.join(projectPath, 'fixtures'));
      if (await fixturesDir.exists()) {
        initialDir = fixturesDir.path;
      }
    }
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Replay wire log fixture',
      type: FileType.custom,
      allowedExtensions: <String>['json'],
      initialDirectory: initialDir,
    );
    if (result == null || result.files.isEmpty) return;
    final pathStr = result.files.first.path;
    if (pathStr == null) return;
    try {
      final body = jsonDecode(await File(pathStr).readAsString());
      if (body is! Map<String, dynamic>) {
        throw const FormatException('fixture root must be a JSON object');
      }
      final frames =
          (body['frames'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(InspectorFrame.fromJson)
              .toList() ??
          const <InspectorFrame>[];
      final replayed = await _sessionsManager.replayFixture(
        session: session,
        fixture: frames,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Replayed $replayed call${replayed == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 12),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Replay failed: $e',
            style: const TextStyle(fontSize: 12),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// Convenience accessor for the parent panel's session manager —
  /// the `_LoggerPanelState` lives inside `_InspectorPanelState` and
  /// reaches up via `findAncestorStateOfType`.
  InspectorSessionManager get _sessionsManager {
    final st = context.findAncestorStateOfType<_InspectorPanelState>();
    if (st == null) {
      throw StateError('logger panel must be inside InspectorPanel');
    }
    return st._sessions;
  }

  /// Project root path resolved from the parent panel widget. Used
  /// to anchor fixture save / load dialogs to `<projectRoot>/fixtures`
  /// so test artifacts live next to the project they exercise.
  String? get _projectPath {
    final st = context.findAncestorStateOfType<_InspectorPanelState>();
    return st?.widget.projectPath;
  }

  /// Filter frames against the current query. Match against method +
  /// jsonEncode of payload + error so every wire field is searchable.
  List<int> _matchingIndexes(List<InspectorFrame> frames) {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) {
      return List<int>.generate(frames.length, (i) => i);
    }
    final hits = <int>[];
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      final body = StringBuffer(f.method);
      if (f.error != null) body.write(' ${f.error}');
      if (f.payload != null) {
        try {
          body.write(' ${jsonEncode(f.payload)}');
        } catch (_) {
          body.write(' ${f.payload}');
        }
      }
      if (body.toString().toLowerCase().contains(q)) {
        hits.add(i);
      }
    }
    return hits;
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final session = widget.session;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.borderDefault)),
      ),
      child: Column(
        children: <Widget>[
          _PanelHeader(
            tab: _tab,
            onTabChanged: (t) => setState(() => _tab = t),
            wireLeading:
                _tab == _PanelTab.wire
                    ? _WireToolbar(
                      query: _query,
                      onChanged: () => setState(() {}),
                      matches: _matchingIndexes(
                        session?.frames ?? const <InspectorFrame>[],
                      ),
                      total: session?.frames.length ?? 0,
                      onExport:
                          session != null && session.frames.isNotEmpty
                              ? () => _exportFixture(session)
                              : null,
                      onReplay:
                          session != null &&
                                  session.status == InspectorStatus.connected
                              ? () => _replayFixture(session)
                              : null,
                    )
                    : _StateToolbar(
                      runtimes:
                          session?.runtimes ?? const <String, MCPUIRuntime>{},
                      selected: _stateTarget,
                      onPick:
                          (t) => setState(() {
                            _stateTarget = t;
                            _ensureStateSubscription();
                          }),
                    ),
          ),
          Expanded(
            child:
                _tab == _PanelTab.wire
                    ? _buildWire(c, session)
                    : _buildState(c),
          ),
        ],
      ),
    );
  }

  Widget _buildWire(dynamic c, InspectorSession? session) {
    final frames = session?.frames ?? const <InspectorFrame>[];
    final matches = _matchingIndexes(frames);
    final query = _query.text.trim();
    if (frames.isEmpty) {
      return Center(
        child: Text(
          'No wire activity yet',
          style: vibeMono(size: 11, color: c.textTertiary),
        ),
      );
    }
    if (matches.isEmpty) {
      return Center(
        child: Text(
          'No matches',
          style: vibeMono(size: 11, color: c.textTertiary),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: matches.length,
      itemBuilder: (ctx, j) {
        final i = matches[j];
        final f = frames[i];
        final expanded = _expanded == i;
        final highlighted =
            _selectedMethod != null && f.method == _selectedMethod;
        return _FrameRow(
          frame: f,
          expanded: expanded,
          highlighted: highlighted,
          query: query,
          onTap:
              () => setState(() {
                _expanded = expanded ? null : i;
                _selectedMethod = expanded ? null : f.method;
              }),
        );
      },
    );
  }

  Widget _buildState(dynamic c) {
    _ensureStateSubscription();
    final runtime = _stateRuntime;
    if (runtime == null) {
      return Center(
        child: Text(
          'No runtime bound — render the UI first.',
          style: vibeMono(size: 11, color: c.textTertiary),
        ),
      );
    }
    final state = runtime.stateManager.state;
    if (state.isEmpty) {
      return Center(
        child: Text(
          'State is empty.',
          style: vibeMono(size: 11, color: c.textTertiary),
        ),
      );
    }
    final rows = <_StateNode>[];
    _flatten('', state, rows);
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (ctx, i) {
        final node = rows[i];
        return _StateRow(
          path: node.path,
          value: node.value,
          isLeaf: node.isLeaf,
          onCommit:
              !node.isLeaf
                  ? null
                  : (parsed) => runtime.stateManager.set(
                    node.path,
                    parsed,
                    source: 'inspector',
                  ),
        );
      },
    );
  }

  /// Recursively walk a state map. Containers (Map / List) emit one
  /// row each so the hierarchy is visible, then their entries follow
  /// indented. Leaves carry their full dotted path so editing fires
  /// the runtime's per-path stream — that's how widget bindings get
  /// notified, so a top-level container set wouldn't refresh deep
  /// bindings.
  void _flatten(String prefix, dynamic value, List<_StateNode> out) {
    if (value is Map) {
      if (prefix.isNotEmpty) {
        out.add(_StateNode(path: prefix, value: value, isLeaf: false));
      }
      final keys = value.keys.toList()..sort();
      for (final k in keys) {
        final next = prefix.isEmpty ? '$k' : '$prefix.$k';
        _flatten(next, value[k], out);
      }
      return;
    }
    if (value is List) {
      if (prefix.isNotEmpty) {
        out.add(_StateNode(path: prefix, value: value, isLeaf: false));
      }
      for (var i = 0; i < value.length; i++) {
        final next = prefix.isEmpty ? '[$i]' : '$prefix.$i';
        _flatten(next, value[i], out);
      }
      return;
    }
    // Primitive (or null) — editable leaf.
    out.add(_StateNode(path: prefix, value: value, isLeaf: true));
  }
}

/// One entry surfaced in the state tab. [isLeaf] decides whether the
/// row is editable — containers are read-only headers and their
/// children appear indented underneath.
class _StateNode {
  const _StateNode({
    required this.path,
    required this.value,
    required this.isLeaf,
  });
  final String path;
  final dynamic value;
  final bool isLeaf;
}

/// Tabbed header for the bottom pane — Wire / State toggle on the
/// left, contextual toolbar (search box or surface picker) filling
/// the rest of the row.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.tab,
    required this.onTabChanged,
    required this.wireLeading,
  });
  final _PanelTab tab;
  final ValueChanged<_PanelTab> onTabChanged;
  final Widget wireLeading;

  Widget _tabChip(
    BuildContext context, {
    required _PanelTab value,
    required String label,
  }) {
    final c = VibeTokens.colorOf(context);
    final selected = tab == value;
    return InkWell(
      onTap: () => onTabChanged(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          label,
          style: vibeMono(
            size: 10,
            weight: FontWeight.w500,
            color: selected ? c.mint : c.textTertiary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space3),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: <Widget>[
          _tabChip(context, value: _PanelTab.wire, label: 'WIRE'),
          _tabChip(context, value: _PanelTab.state, label: 'STATE'),
          const SizedBox(width: VibeTokens.space3),
          Expanded(child: wireLeading),
        ],
      ),
    );
  }
}

/// Search box + frame counter — extracted from the original wire-log
/// header so both tab modes can reuse the panel header chrome. Adds
/// export / replay icons on the right when the active session has a
/// wire log to save / a connection to replay against.
class _WireToolbar extends StatelessWidget {
  const _WireToolbar({
    required this.query,
    required this.onChanged,
    required this.matches,
    required this.total,
    this.onExport,
    this.onReplay,
  });
  final TextEditingController query;
  final VoidCallback onChanged;
  final List<int> matches;
  final int total;
  final VoidCallback? onExport;
  final VoidCallback? onReplay;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final q = query.text.trim();
    return Row(
      children: <Widget>[
        Expanded(
          child: SizedBox(
            height: 18,
            child: TextField(
              controller: query,
              onChanged: (_) => onChanged(),
              style: vibeMono(size: 10, color: c.textPrimary),
              cursorColor: c.mint,
              cursorWidth: 1,
              decoration: InputDecoration(
                isCollapsed: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                hintText: 'search',
                hintStyle: vibeMono(size: 10, color: c.textTertiary),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(3),
                  borderSide: BorderSide(color: c.borderDefault),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(3),
                  borderSide: BorderSide(color: c.borderDefault),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(3),
                  borderSide: BorderSide(color: c.mint),
                ),
                suffixIcon:
                    query.text.isEmpty
                        ? null
                        : InkWell(
                          onTap: () {
                            query.clear();
                            onChanged();
                          },
                          child: Icon(
                            Icons.close,
                            size: 12,
                            color: c.textTertiary,
                          ),
                        ),
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 16,
                  minHeight: 16,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: VibeTokens.space2),
        Text(
          q.isEmpty ? '$total frames' : '${matches.length}/$total',
          style: vibeMono(size: 10, color: c.textTertiary),
        ),
        const SizedBox(width: VibeTokens.space2),
        Tooltip(
          message:
              onExport == null
                  ? 'No frames to export'
                  : 'Export wire log fixture',
          child: InkWell(
            onTap: onExport,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.file_download_outlined,
                size: 14,
                color:
                    onExport == null
                        ? c.textTertiary.withValues(alpha: 0.4)
                        : c.textSecondary,
              ),
            ),
          ),
        ),
        Tooltip(
          message:
              onReplay == null
                  ? 'Connect a session to replay'
                  : 'Replay fixture against this session',
          child: InkWell(
            onTap: onReplay,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(
                Icons.replay_outlined,
                size: 14,
                color:
                    onReplay == null
                        ? c.textTertiary.withValues(alpha: 0.4)
                        : c.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Surface picker for the State tab. Shows a chip per bound runtime
/// target (e.g. APP, DASHBOARD) so the user can flip between their
/// state managers without leaving the panel.
class _StateToolbar extends StatelessWidget {
  const _StateToolbar({
    required this.runtimes,
    required this.selected,
    required this.onPick,
  });
  final Map<String, MCPUIRuntime> runtimes;
  final String? selected;
  final ValueChanged<String> onPick;

  String _shortLabel(String target) {
    const prefix = 'mcp-ui:';
    final tail =
        target.startsWith(prefix) ? target.substring(prefix.length) : target;
    return tail.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    if (runtimes.isEmpty) {
      return Text(
        'no runtime bound',
        style: vibeMono(size: 10, color: c.textTertiary),
      );
    }
    final keys = runtimes.keys.toList()..sort();
    return Row(
      children: <Widget>[
        for (final k in keys) ...<Widget>[
          InkWell(
            onTap: () => onPick(k),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Text(
                _shortLabel(k),
                style: vibeMono(
                  size: 10,
                  weight: FontWeight.w500,
                  color: selected == k ? c.mint : c.textTertiary,
                ),
              ),
            ),
          ),
        ],
        const Spacer(),
        Text(
          'tap value to edit',
          style: vibeMono(size: 10, color: c.textTertiary),
        ),
      ],
    );
  }
}

/// One row in the State tree — key on the left, current value on the
/// right (tap to edit). Edits are parsed as JSON literals first so
/// numbers / booleans round-trip; bare strings stay as strings.
/// Container rows ([isLeaf] false) are read-only — their children
/// appear in subsequent rows.
class _StateRow extends StatefulWidget {
  const _StateRow({
    required this.path,
    required this.value,
    required this.isLeaf,
    required this.onCommit,
  });
  final String path;
  final dynamic value;
  final bool isLeaf;
  final ValueChanged<dynamic>? onCommit;

  @override
  State<_StateRow> createState() => _StateRowState();
}

class _StateRowState extends State<_StateRow> {
  bool _editing = false;
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _renderValue(widget.value));
  }

  @override
  void didUpdateWidget(covariant _StateRow old) {
    super.didUpdateWidget(old);
    if (!_editing && old.value != widget.value) {
      _ctrl.text = _renderValue(widget.value);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// What goes into the right-hand cell. For containers we summarise
  /// (`{2 keys}` / `[3 items]`) so the row stays compact; deep
  /// children show in their own rows underneath.
  static String _renderValue(dynamic v) {
    if (v == null) return 'null';
    if (v is String) return v;
    if (v is Map) return '{${v.length} key${v.length == 1 ? '' : 's'}}';
    if (v is List) return '[${v.length} item${v.length == 1 ? '' : 's'}]';
    try {
      return jsonEncode(v);
    } catch (_) {
      return v.toString();
    }
  }

  /// Indent depth derived from the dotted path. Each '.' is one level;
  /// nested list indices use the same separator after [_flatten].
  int get _depth => '.'.allMatches(widget.path).length;

  String get _label {
    final p = widget.path;
    if (p.isEmpty) return p;
    final i = p.lastIndexOf('.');
    return i < 0 ? p : p.substring(i + 1);
  }

  void _commit() {
    if (widget.onCommit == null) return;
    final raw = _ctrl.text;
    dynamic parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      parsed = raw;
    }
    widget.onCommit!(parsed);
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final preview = _renderValue(widget.value);
    final labelColor = widget.isLeaf ? c.textSecondary : c.textTertiary;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        VibeTokens.space3 + _depth * 12.0,
        2,
        VibeTokens.space3,
        2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 140,
            child: Text(
              _label,
              style: vibeMono(
                size: 11,
                color: labelColor,
                weight: widget.isLeaf ? FontWeight.w400 : FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: VibeTokens.space2),
          Expanded(
            child:
                _editing && widget.isLeaf
                    ? TextField(
                      controller: _ctrl,
                      autofocus: true,
                      style: vibeMono(size: 11, color: c.textPrimary),
                      cursorColor: c.mint,
                      cursorWidth: 1,
                      decoration: InputDecoration(
                        isCollapsed: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(3),
                          borderSide: BorderSide(color: c.mint),
                        ),
                      ),
                      onSubmitted: (_) => _commit(),
                    )
                    : InkWell(
                      onTap:
                          widget.isLeaf
                              ? () => setState(() => _editing = true)
                              : null,
                      child: Text(
                        preview,
                        style: vibeMono(
                          size: 11,
                          color: widget.isLeaf ? c.textPrimary : c.textTertiary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
          ),
          if (_editing && widget.isLeaf)
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
              iconSize: 12,
              icon: Icon(Icons.check, color: c.mint),
              onPressed: _commit,
            ),
        ],
      ),
    );
  }
}

class _FrameRow extends StatelessWidget {
  const _FrameRow({
    required this.frame,
    required this.expanded,
    required this.onTap,
    this.highlighted = false,
    this.query = '',
  });
  final InspectorFrame frame;
  final bool expanded;
  final VoidCallback onTap;
  final bool highlighted;
  final String query;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final (Color color, String marker) = switch (frame.kind) {
      InspectorFrameKind.request => (c.amber, '→'),
      InspectorFrameKind.response => (c.mint, '←'),
      InspectorFrameKind.notification => (c.textSecondary, '◇'),
      InspectorFrameKind.error => (c.coral, '✗'),
      InspectorFrameKind.info => (c.textTertiary, '·'),
    };
    final ts = frame.timestamp;
    final tsLabel =
        '${_two(ts.hour)}:${_two(ts.minute)}:${_two(ts.second)}'
        '.${_three(ts.millisecond)}';
    final dur = frame.duration;
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: highlighted ? c.mint.withValues(alpha: 0.06) : null,
          border: Border(
            left: BorderSide(
              color: highlighted ? c.mint : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space3,
          vertical: 2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(tsLabel, style: vibeMono(size: 10, color: c.textTertiary)),
                const SizedBox(width: VibeTokens.space2),
                SizedBox(
                  width: 12,
                  child: Text(
                    marker,
                    style: vibeMono(
                      size: 11,
                      weight: FontWeight.w500,
                      color: color,
                    ),
                  ),
                ),
                const SizedBox(width: VibeTokens.space2),
                Expanded(
                  child: _HighlightedText(
                    text: frame.method,
                    query: query,
                    style: vibeMono(
                      size: 11,
                      color: color,
                      weight: FontWeight.w500,
                    ),
                    maxLines: 1,
                  ),
                ),
                if (dur != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(
                      '${dur.inMilliseconds}ms',
                      style: vibeMono(size: 10, color: c.textTertiary),
                    ),
                  ),
              ],
            ),
            if (expanded) ...<Widget>[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 60),
                child: _HighlightedText(
                  text: _formatPayload(frame),
                  query: query,
                  style: vibeMono(size: 10, color: c.textSecondary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _three(int n) => n.toString().padLeft(3, '0');

  static String _formatPayload(InspectorFrame f) {
    final buf = StringBuffer();
    if (f.error != null) {
      buf.writeln('error: ${f.error}');
    }
    if (f.payload != null) {
      try {
        buf.write(const JsonEncoder.withIndent('  ').convert(f.payload));
      } catch (_) {
        buf.write(f.payload.toString());
      }
    }
    return buf.toString();
  }
}

/// Text widget that wraps every case-insensitive match of [query] in
/// a yellow background span. Used by both the row's method line and
/// the expanded payload so search hits stand out everywhere.
class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.text,
    required this.query,
    required this.style,
    this.maxLines,
  });
  final String text;
  final String query;
  final TextStyle style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: maxLines == null ? null : TextOverflow.ellipsis,
      );
    }
    final c = VibeTokens.colorOf(context);
    final hl = TextStyle(
      backgroundColor: c.amber.withValues(alpha: 0.4),
      color: style.color,
      fontFamily: style.fontFamily,
      fontSize: style.fontSize,
      fontWeight: style.fontWeight,
    );
    final lower = text.toLowerCase();
    final q = query.toLowerCase();
    final spans = <TextSpan>[];
    var i = 0;
    while (i < text.length) {
      final j = lower.indexOf(q, i);
      if (j < 0) {
        spans.add(TextSpan(text: text.substring(i)));
        break;
      }
      if (j > i) {
        spans.add(TextSpan(text: text.substring(i, j)));
      }
      spans.add(TextSpan(text: text.substring(j, j + q.length), style: hl));
      i = j + q.length;
    }
    return RichText(
      text: TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
  }
}

/// Inspector toolbar — preview_panel toolbar shape (height 36,
/// `c.surface`, bottom border). Shows the active session's transport,
/// endpoint, and tool count; future controls (capture, brightness,
/// frame size override) drop in here.
class _InspectorToolbar extends StatelessWidget {
  const _InspectorToolbar({
    required this.session,
    required this.size,
    required this.orient,
    required this.bright,
    required this.customW,
    required this.customH,
    required this.sizeAnchorKey,
    required this.brightAnchorKey,
    required this.onPickSize,
    required this.onToggleOrient,
    required this.onPickBrightness,
    required this.onResetView,
  });
  final InspectorSession? session;
  final InspectorSize size;
  final InspectorOrient orient;
  final InspectorBright bright;
  final int customW;
  final int customH;
  final Key sizeAnchorKey;
  final Key brightAnchorKey;
  final VoidCallback onPickSize;
  final VoidCallback onToggleOrient;
  final VoidCallback onPickBrightness;
  final VoidCallback onResetView;

  String _sizeChoiceLabel() => switch (size) {
    InspectorSize.mobile => 'Mobile',
    InspectorSize.tablet => 'Tablet',
    InspectorSize.desktop => 'PC',
    InspectorSize.custom => 'Custom',
  };

  IconData _sizeChoiceIcon() => switch (size) {
    InspectorSize.mobile => Icons.smartphone_outlined,
    InspectorSize.tablet => Icons.tablet_outlined,
    InspectorSize.desktop => Icons.monitor_outlined,
    InspectorSize.custom => Icons.tune_outlined,
  };

  String _sizePixelLabel() {
    final f =
        inspectorFrameFor(
          size,
          orient,
          customW: customW,
          customH: customH,
        ).logicalSize;
    return '${f.width.toInt()}×${f.height.toInt()}';
  }

  IconData _brightnessIcon() => switch (bright) {
    InspectorBright.system => Icons.brightness_auto_outlined,
    InspectorBright.light => Icons.light_mode_outlined,
    InspectorBright.dark => Icons.dark_mode_outlined,
  };

  String _statusLabel(InspectorStatus st) => switch (st) {
    InspectorStatus.connected => 'CONNECTED',
    InspectorStatus.spawning => 'SPAWNING',
    InspectorStatus.connecting => 'CONNECTING',
    InspectorStatus.exited => 'EXITED',
    InspectorStatus.error => 'ERROR',
    InspectorStatus.idle => 'IDLE',
  };

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final s = session;
    final st = s?.status;
    final (Color iconColor, IconData icon, Color slugColor) = switch (st) {
      InspectorStatus.connected => (
        c.mint,
        Icons.power_outlined,
        c.textPrimary,
      ),
      InspectorStatus.spawning || InspectorStatus.connecting => (
        c.amber,
        Icons.power_outlined,
        c.textPrimary,
      ),
      InspectorStatus.exited => (
        c.textTertiary,
        Icons.power_off_outlined,
        c.textTertiary,
      ),
      InspectorStatus.error => (c.coral, Icons.error_outline, c.coral),
      _ => (c.textTertiary, Icons.power_off_outlined, c.textTertiary),
    };
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.borderDefault)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space3),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 14, color: iconColor),
          const SizedBox(width: VibeTokens.space2),
          if (s == null)
            Text(
              'No active session',
              style: vibeMono(size: 11, color: c.textTertiary),
            )
          else ...<Widget>[
            Text(
              s.slug,
              style: vibeMono(
                size: 11,
                weight: FontWeight.w500,
                color: slugColor,
              ),
            ),
            if (st != null && st != InspectorStatus.connected) ...<Widget>[
              const SizedBox(width: VibeTokens.space2),
              Text(
                _statusLabel(st),
                style: vibeMono(size: 10, color: iconColor),
              ),
            ],
            const SizedBox(width: VibeTokens.space2),
            Text('·', style: vibeMono(size: 11, color: c.textTertiary)),
            const SizedBox(width: VibeTokens.space2),
            Text(
              s.transport.label.toUpperCase(),
              style: vibeMono(size: 11, color: c.textSecondary),
            ),
            if (s.endpointUrl != null) ...<Widget>[
              const SizedBox(width: VibeTokens.space2),
              Text('·', style: vibeMono(size: 11, color: c.textTertiary)),
              const SizedBox(width: VibeTokens.space2),
              Flexible(
                child: Text(
                  s.endpointUrl!,
                  overflow: TextOverflow.ellipsis,
                  style: vibeMono(size: 11, color: c.textSecondary),
                ),
              ),
            ],
            const Spacer(),
            Text(
              '${s.tools.length} tools · ${s.pages.length} pages',
              style: vibeMono(size: 11, color: c.textTertiary),
            ),
            const SizedBox(width: VibeTokens.space3),
          ],
          if (s == null) const Spacer(),
          _InspectorSizeButton(
            anchorKey: sizeAnchorKey,
            choiceIcon: _sizeChoiceIcon(),
            choiceLabel: _sizeChoiceLabel(),
            pixelLabel: _sizePixelLabel(),
            onTap: onPickSize,
          ),
          const SizedBox(width: VibeTokens.space2),
          Tooltip(
            message:
                orient == InspectorOrient.landscape
                    ? 'Switch to portrait'
                    : 'Switch to landscape',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onToggleOrient,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Icon(
                  orient == InspectorOrient.landscape
                      ? Icons.stay_current_landscape_outlined
                      : Icons.stay_current_portrait_outlined,
                  size: 16,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: 'Preview brightness (runtime only)',
            child: GestureDetector(
              key: brightAnchorKey,
              behavior: HitTestBehavior.opaque,
              onTap: onPickBrightness,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Icon(
                  _brightnessIcon(),
                  size: 16,
                  color: c.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: VibeTokens.space2),
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

/// Render-size button — icon + label + pixel-size — mirrors
/// `preview_panel._SizeButton` so the inspector toolbar reads the
/// same as the editor's preview toolbar.
class _InspectorSizeButton extends StatelessWidget {
  const _InspectorSizeButton({
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

/// Inspector-side copy of `preview_panel._showVibeMenu` — anchored
/// under the trigger, vibe styling, no animation.
Future<T?> _showInspectorMenu<T>({
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

/// Custom W × H input dialog — mirrors `preview_panel._showCustomSizeDialog`.
Future<(int, int)?> _showInspectorCustomSizeDialog(
  BuildContext context, {
  required int initialW,
  required int initialH,
}) async {
  final wCtrl = TextEditingController(text: '$initialW');
  final hCtrl = TextEditingController(text: '$initialH');
  final c = VibeTokens.colorOf(context);
  return showDialog<(int, int)?>(
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
}

class _CenteredHint extends StatelessWidget {
  const _CenteredHint({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return ColoredBox(
      color: c.bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48, color: c.textTertiary),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                fontFamily: VibeTokens.fontSans,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: VibeTokens.fontSans,
                  fontSize: 13,
                  color: c.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
