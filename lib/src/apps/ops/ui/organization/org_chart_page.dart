/// Organization route — a graphical org-chart with a **lens switch** over the
/// same data: Workflow (process event-topology — handoff / parallel / event),
/// Structure (workspace org-unit tree + members by role), and Knowledge
/// (members ↔ referenced skill / profile / philosophy). Tap any node for
/// detail.
///
/// Inputs come from [orgChartInputsProvider] (live via the workspace / member /
/// process / knowledge change ticks); the page builds the model for the
/// selected lens via `buildOrgChartModel(inputs, mode:)` (deterministic — a
/// pure re-layout, no re-fetch on lens switch). The canvas is pan/zoomable
/// (`InteractiveViewer`, fit-to-view + zoom controls) and tap hit-testing is
/// done against the model's node rects in child (canvas) coordinate space.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../theme/tokens.dart';
import '../../widgets/ops_atoms.dart';
import 'org_chart_model.dart';
import 'org_chart_painter.dart';
import 'org_directory.dart';
import 'org_node_detail.dart';
import 'org_overlay.dart';

class OrgChartPage extends ConsumerStatefulWidget {
  const OrgChartPage({super.key});

  @override
  ConsumerState<OrgChartPage> createState() => _OrgChartPageState();
}

class _OrgChartPageState extends ConsumerState<OrgChartPage> {
  String? _selectedId;
  OrgViewMode _mode = OrgViewMode.workflow;

  /// Directory (card master-detail, default) vs Chart (painted canvas).
  bool _directory = true;
  final _tc = TransformationController();
  // Whether the transform was initialised for the current lens. The default
  // view is NATURAL SIZE (1:1) — a large org must stay READABLE and be
  // explored by pan/zoom, not shrunk whole into the viewport (fit-to-view
  // made big orgs illegibly small; it stays available as the Fit button).
  // Content edits (a process / member change) do NOT reset the transform —
  // that would fight the user's pan/zoom; only a lens switch re-initialises.
  bool _viewInitialized = false;

  static const double _minScale = 0.25;
  static const double _maxScale = 3.0;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  /// Natural-size (1:1) view, top-aligned: the default and the `1:1` button.
  /// Content narrower than the viewport is centered; wider content anchors
  /// left so reading starts at the tree's origin.
  void _natural(Size content, Size viewport) {
    if (content.width <= 0 || content.height <= 0) return;
    const margin = 24.0;
    final dx = (viewport.width - content.width) / 2;
    _tc.value =
        Matrix4.identity()
          ..translateByDouble(dx < margin ? margin : dx, margin, 0, 1);
  }

  /// Fit the whole chart into [viewport] (scale down only — never magnify past
  /// 1:1) and center it, top-aligned with a small margin. Explicit action —
  /// the overview lens for a quick glance at the whole org.
  void _fit(Size content, Size viewport) {
    if (content.width <= 0 || content.height <= 0) return;
    const margin = 24.0;
    final sx = (viewport.width - margin * 2) / content.width;
    final sy = (viewport.height - margin * 2) / content.height;
    final scale = math.min(1.0, math.min(sx, sy)).clamp(_minScale, _maxScale);
    final dx = (viewport.width - content.width * scale) / 2;
    _tc.value =
        Matrix4.identity()
          ..translateByDouble(dx < margin ? margin : dx, margin, 0, 1)
          ..scaleByDouble(scale, scale, 1, 1);
  }

  void _zoomBy(double factor) {
    final cur = _tc.value.getMaxScaleOnAxis();
    final next = (cur * factor).clamp(_minScale, _maxScale);
    final f = next / cur;
    _tc.value = _tc.value.clone()..scaleByDouble(f, f, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(orgChartInputsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          mode: _mode,
          directory: _directory,
          onDirectory: (d) => setState(() => _directory = d),
          onMode: (m) {
            if (m == _mode) return;
            setState(() {
              _mode = m;
              _selectedId = null;
              _viewInitialized = false; // re-anchor 1:1 for the new lens
            });
          },
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _Message(icon: Icons.error_outline, text: '$e'),
            data: (inputs) {
              final model = buildOrgChartModel(inputs, mode: _mode);
              // Live layer: 4s poll (facts/process runs have no change
              // stream). A tick only repaints — the geometry above rebuilds
              // solely on registry mutations, so pan/zoom is untouched.
              final overlay = ref
                  .watch(orgOverlayProvider)
                  .whenOrNull(data: (raw) => resolveOrgOverlay(inputs, raw));
              if (_directory) {
                if (inputs.isEmpty) {
                  return const _Message(
                    icon: Icons.hub_outlined,
                    text:
                        'No workspaces yet. Create one (Workspaces) to '
                        'see the organization.',
                  );
                }
                return OrgDirectory(inputs: inputs, overlay: overlay);
              }
              if (model.nodes.isEmpty) {
                return const _Message(
                  icon: Icons.hub_outlined,
                  text:
                      'No workspaces yet. Create one (Workspaces) to see the '
                      'organization chart.',
                );
              }
              return LayoutBuilder(
                builder: (ctx, constraints) {
                  final viewport = constraints.biggest;
                  // Initialise once per lens at NATURAL size (post-frame so we
                  // don't mutate the controller during build). Content edits
                  // keep the user's current pan/zoom.
                  if (!_viewInitialized) {
                    _viewInitialized = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _natural(model.size, viewport);
                    });
                  }
                  return Stack(
                    children: [
                      InteractiveViewer(
                        transformationController: _tc,
                        constrained: false,
                        minScale: _minScale,
                        maxScale: _maxScale,
                        boundaryMargin: const EdgeInsets.all(400),
                        child: SizedBox(
                          width: model.size.width,
                          height: model.size.height,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (d) {
                              final n = model.hitTest(d.localPosition);
                              setState(() => _selectedId = n?.id);
                              if (n != null) {
                                showOrgNodeDetail(context, ref, n, model);
                              }
                            },
                            child: CustomPaint(
                              size: model.size,
                              painter: OrgChartPainter(
                                model: model,
                                selectedId: _selectedId,
                                overlay: overlay,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: OpsSpace.s5,
                        bottom: OpsSpace.s5,
                        child: _ZoomBar(
                          onIn: () => _zoomBy(1.25),
                          onOut: () => _zoomBy(0.8),
                          onNatural: () => _natural(model.size, viewport),
                          onFit: () => _fit(model.size, viewport),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.mode,
    required this.onMode,
    required this.directory,
    required this.onDirectory,
  });
  final OrgViewMode mode;
  final ValueChanged<OrgViewMode> onMode;
  final bool directory;
  final ValueChanged<bool> onDirectory;

  Widget _viewSwitch() => OpsPillSwitch<bool>(
    options: const [('Directory', true), ('Chart', false)],
    value: directory,
    onChanged: onDirectory,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        OpsSpace.s8,
        OpsSpace.s6,
        OpsSpace.s8,
        OpsSpace.s5,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: OpsColors.border)),
      ),
      // The header must never overflow, whatever the pane width. Wide panes
      // get the fixed title/switch + scrolling legend + right-aligned hint;
      // panes too narrow for even the fixed part degrade to one fully
      // scrollable strip.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final title = Text(
            'Organization',
            style: TextStyle(
              fontSize: OpsType.xxl,
              fontWeight: OpsType.semibold,
              color: OpsColors.text,
            ),
          );
          if (constraints.maxWidth < 560) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  title,
                  const SizedBox(width: OpsSpace.s6),
                  _viewSwitch(),
                  if (!directory) ...[
                    const SizedBox(width: OpsSpace.s6),
                    _LensSwitch(mode: mode, onMode: onMode),
                    const SizedBox(width: OpsSpace.s6),
                    ..._legendFor(mode),
                  ],
                ],
              ),
            );
          }
          return Row(
            children: [
              title,
              const SizedBox(width: OpsSpace.s6),
              _viewSwitch(),
              if (!directory) ...[
                const SizedBox(width: OpsSpace.s6),
                _LensSwitch(mode: mode, onMode: onMode),
              ],
              const SizedBox(width: OpsSpace.s6),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: directory ? const [] : _legendFor(mode)),
                ),
              ),
              const SizedBox(width: OpsSpace.s4),
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _hintFor(mode),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: OpsType.xs,
                      color: OpsColors.text3,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _legendFor(OrgViewMode mode) => switch (mode) {
    OrgViewMode.workflow => [
      const _LegendDot(color: OpsColors.io, label: 'process ⚡event'),
      const _LegendDot(color: OpsColors.app, label: 'step'),
      _LegendDot(color: OpsColors.warn, label: '✓ sign-off'),
      const _LegendDot(color: OpsColors.knowledge, label: '◇ charter'),
    ],
    OrgViewMode.structure => const [
      _LegendDot(color: OpsColors.domain, label: '★ lead'),
      _LegendDot(color: OpsColors.app, label: '🤖 agent / 👤 human'),
    ],
    OrgViewMode.knowledge => const [
      _LegendDot(color: OpsColors.app, label: 'member'),
      _LegendDot(color: OpsColors.knowledge, label: 'skill'),
      _LegendDot(color: OpsColors.protocol, label: 'profile'),
      _LegendDot(color: OpsColors.domain, label: 'philosophy'),
    ],
  };

  String _hintFor(OrgViewMode mode) => switch (mode) {
    OrgViewMode.workflow =>
      '⚡ event-triggers · → depends-on · parallel branches stack · tap for detail',
    OrgViewMode.structure =>
      'workspace = org unit (nest for sub-teams) · lead → members · tap for detail',
    OrgViewMode.knowledge =>
      'member → referenced skill / profile / philosophy · tap for detail',
  };
}

/// Segmented lens switch (Workflow / Structure / Knowledge).
class _LensSwitch extends StatelessWidget {
  const _LensSwitch({required this.mode, required this.onMode});
  final OrgViewMode mode;
  final ValueChanged<OrgViewMode> onMode;

  static const _labels = {
    OrgViewMode.workflow: 'Workflow',
    OrgViewMode.structure: 'Structure',
    OrgViewMode.knowledge: 'Knowledge',
  };

  @override
  Widget build(BuildContext context) {
    return OpsPillSwitch<OrgViewMode>(
      options: [for (final m in OrgViewMode.values) (_labels[m]!, m)],
      value: mode,
      onChanged: onMode,
    );
  }
}

/// Bottom-right zoom controls (zoom out / 1:1 / fit-to-view / zoom in).
/// 1:1 = the readable default for large orgs; Fit = whole-org overview.
class _ZoomBar extends StatelessWidget {
  const _ZoomBar({
    required this.onIn,
    required this.onOut,
    required this.onNatural,
    required this.onFit,
  });
  final VoidCallback onIn;
  final VoidCallback onOut;
  final VoidCallback onNatural;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: OpsColors.surface.withValues(alpha: 0.9),
        borderRadius: OpsRadius.all_md,
        border: Border.all(color: OpsColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomBtn(icon: Icons.remove, tip: 'Zoom out', onTap: onOut),
          _ZoomBtn(
            icon: Icons.crop_free_outlined,
            tip: 'Actual size (1:1)',
            onTap: onNatural,
          ),
          _ZoomBtn(icon: Icons.fit_screen_outlined, tip: 'Fit', onTap: onFit),
          _ZoomBtn(icon: Icons.add, tip: 'Zoom in', onTap: onIn),
        ],
      ),
    );
  }
}

class _ZoomBtn extends StatelessWidget {
  const _ZoomBtn({required this.icon, required this.tip, required this.onTap});
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18, color: OpsColors.text2),
      tooltip: tip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      splashRadius: 18,
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: OpsSpace.s6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: OpsSpace.s2),
          Text(
            label,
            style: TextStyle(fontSize: OpsType.sm, color: OpsColors.text2),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(OpsSpace.s9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: OpsColors.text3, size: 40),
            const SizedBox(height: OpsSpace.s5),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: OpsType.md, color: OpsColors.text3),
            ),
          ],
        ),
      ),
    );
  }
}
