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
import 'org_chart_model.dart';
import 'org_chart_painter.dart';
import 'org_node_detail.dart';

class OrgChartPage extends ConsumerStatefulWidget {
  const OrgChartPage({super.key});

  @override
  ConsumerState<OrgChartPage> createState() => _OrgChartPageState();
}

class _OrgChartPageState extends ConsumerState<OrgChartPage> {
  String? _selectedId;
  OrgViewMode _mode = OrgViewMode.workflow;
  final _tc = TransformationController();
  // The content size we last fitted to, so we re-fit when the chart changes
  // (a process / member edit) but not on every rebuild (which would fight the
  // user's manual pan/zoom).
  Size? _fittedFor;

  static const double _minScale = 0.25;
  static const double _maxScale = 2.5;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  /// Fit the whole chart into [viewport] (scale down only — never magnify past
  /// 1:1) and center it, top-aligned with a small margin.
  void _fit(Size content, Size viewport) {
    if (content.width <= 0 || content.height <= 0) return;
    const margin = 24.0;
    final sx = (viewport.width - margin * 2) / content.width;
    final sy = (viewport.height - margin * 2) / content.height;
    final scale = math.min(1.0, math.min(sx, sy)).clamp(_minScale, _maxScale);
    final dx = (viewport.width - content.width * scale) / 2;
    _tc.value = Matrix4.identity()
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
          onMode: (m) {
            if (m == _mode) return;
            setState(() {
              _mode = m;
              _selectedId = null;
              _fittedFor = null; // force re-fit for the new lens
            });
          },
        ),
        Expanded(
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _Message(icon: Icons.error_outline, text: '$e'),
            data: (inputs) {
              final model = buildOrgChartModel(inputs, mode: _mode);
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
                  // Fit once per content-size change (post-frame so we don't
                  // mutate the controller during build).
                  if (_fittedFor != model.size) {
                    _fittedFor = model.size;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _fit(model.size, viewport);
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
  const _Header({required this.mode, required this.onMode});
  final OrgViewMode mode;
  final ValueChanged<OrgViewMode> onMode;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        OpsSpace.s8,
        OpsSpace.s6,
        OpsSpace.s8,
        OpsSpace.s5,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x22FFFFFF))),
      ),
      child: Row(
        children: [
          Text(
            'Organization',
            style: TextStyle(
              fontSize: OpsType.xxl,
              fontWeight: OpsType.semibold,
              color: OpsColors.text,
            ),
          ),
          const SizedBox(width: OpsSpace.s6),
          _LensSwitch(mode: mode, onMode: onMode),
          const SizedBox(width: OpsSpace.s6),
          ..._legendFor(mode),
          const Spacer(),
          Text(
            _hintFor(mode),
            style: TextStyle(fontSize: OpsType.xs, color: OpsColors.text3),
          ),
        ],
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
      _LegendDot(color: OpsColors.domain, label: '★ lead (팀장)'),
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
    return Container(
      decoration: BoxDecoration(
        color: OpsColors.surface.withValues(alpha: 0.6),
        borderRadius: OpsRadius.all_md,
        border: Border.all(color: OpsColors.border),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in OrgViewMode.values)
            GestureDetector(
              onTap: () => onMode(m),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: OpsSpace.s5,
                  vertical: OpsSpace.s2,
                ),
                decoration: BoxDecoration(
                  color: m == mode
                      ? OpsColors.accent.withValues(alpha: 0.22)
                      : Colors.transparent,
                  borderRadius: OpsRadius.all_sm,
                ),
                child: Text(
                  _labels[m]!,
                  style: TextStyle(
                    fontSize: OpsType.sm,
                    fontWeight: m == mode ? OpsType.semibold : OpsType.regular,
                    color: m == mode ? OpsColors.text : OpsColors.text2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bottom-right zoom controls (zoom in / out / fit-to-view).
class _ZoomBar extends StatelessWidget {
  const _ZoomBar({required this.onIn, required this.onOut, required this.onFit});
  final VoidCallback onIn;
  final VoidCallback onOut;
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
            style: TextStyle(
              fontSize: OpsType.sm,
              color: OpsColors.text2,
            ),
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
              style: TextStyle(
                fontSize: OpsType.md,
                color: OpsColors.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
