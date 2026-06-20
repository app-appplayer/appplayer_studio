/// `WorkspacePageNavOverlay` — floating, draggable nav strip rendered
/// above a workspace bundle when the bundle opts in via
/// `wiring.showPageNav: true`. Lists one pill per router case, mint
/// accent on the active route, semi-transparent surface so workspace
/// content is still readable underneath. Position defaults to
/// bottom-centre and can be dragged anywhere within the parent.
library;

import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

/// One nav entry — a router case key plus the label shown on the pill.
class WorkspacePageNavEntry {
  const WorkspacePageNavEntry({required this.route, required this.label});
  final String route;
  final String label;
}

/// Draggable horizontal pill strip. Reads the current route from
/// [activeRoute] (which the parent rebuilds via the runtime's state
/// notifier) and dispatches taps through [onNavigate].
class WorkspacePageNavOverlay extends StatefulWidget {
  const WorkspacePageNavOverlay({
    super.key,
    required this.entries,
    required this.activeRoute,
    required this.onNavigate,
  });

  final List<WorkspacePageNavEntry> entries;
  final String? activeRoute;
  final ValueChanged<String> onNavigate;

  @override
  State<WorkspacePageNavOverlay> createState() =>
      _WorkspacePageNavOverlayState();
}

class _WorkspacePageNavOverlayState extends State<WorkspacePageNavOverlay> {
  // Null = use the default bottom-centre placement; non-null = the user
  // has dragged the pill so we honour their offset.
  Offset? _offset;
  Size? _stripSize;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        final stripSize = _stripSize;
        final offset = _resolveOffset(maxW, maxH, stripSize);
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned(
              left: offset.dx,
              top: offset.dy,
              child: _MeasuredStrip(
                onSize: (size) {
                  if (_stripSize == size) return;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    setState(() => _stripSize = size);
                  });
                },
                // Drag is attached only to the handle (inside _buildStrip)
                // so each pill receives its own taps cleanly — wrapping
                // the whole strip with onPanUpdate competed with pill
                // taps in the gesture arena and swallowed them on some
                // backends.
                child: _buildStrip(
                  onDragDelta: (delta) {
                    final current =
                        _stripSize == null
                            ? offset
                            : _resolveOffset(maxW, maxH, _stripSize);
                    final next = current + delta;
                    setState(() => _offset = _clamp(next, maxW, maxH));
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Offset _resolveOffset(double maxW, double maxH, Size? stripSize) {
    final cached = _offset;
    if (cached != null) return _clamp(cached, maxW, maxH);
    // Default: bottom-centre. If we haven't measured the strip yet,
    // fall back to a sensible centring guess (will snap to exact after
    // the first frame).
    final w = stripSize?.width ?? 320;
    final h = stripSize?.height ?? 40;
    final left = ((maxW - w) / 2).clamp(8.0, double.infinity);
    final top = (maxH - h - 24).clamp(8.0, double.infinity);
    return Offset(left, top);
  }

  Offset _clamp(Offset o, double maxW, double maxH) {
    final w = _stripSize?.width ?? 320;
    final h = _stripSize?.height ?? 40;
    final dx = o.dx.clamp(8.0, (maxW - w - 8).clamp(8.0, double.infinity));
    final dy = o.dy.clamp(8.0, (maxH - h - 8).clamp(8.0, double.infinity));
    return Offset(dx, dy);
  }

  Widget _buildStrip({required ValueChanged<Offset> onDragDelta}) {
    final c = VbuTokens.colorOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface2.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.textPrimary.withValues(alpha: 0.08)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Drag handle — only this is pan-sensitive so pill taps
            // remain unambiguous.
            _DragHandle(onPanUpdate: onDragDelta),
            for (final entry in widget.entries)
              _NavPill(
                entry: entry,
                active: entry.route == widget.activeRoute,
                onTap: () => widget.onNavigate(entry.route),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavPill extends StatelessWidget {
  const _NavPill({
    required this.entry,
    required this.active,
    required this.onTap,
  });
  final WorkspacePageNavEntry entry;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final bg = active ? c.mint.withValues(alpha: 0.18) : Colors.transparent;
    final fg = active ? c.mint : c.textPrimary.withValues(alpha: 0.78);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color:
                    active
                        ? c.mint.withValues(alpha: 0.55)
                        : Colors.transparent,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              entry.label,
              style: vbuMono(
                size: 11,
                weight: active ? FontWeight.w600 : FontWeight.w500,
                color: fg,
              ).copyWith(letterSpacing: 0.2),
            ),
          ),
        ),
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onPanUpdate});
  final ValueChanged<Offset> onPanUpdate;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.move,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (details) => onPanUpdate(details.delta),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Icon(
            Icons.drag_indicator,
            size: 14,
            color: c.textSecondary.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}

/// Reports the laid-out child size to the parent so the overlay can
/// centre / clamp its position to the real strip dimensions instead
/// of guessing.
class _MeasuredStrip extends StatefulWidget {
  const _MeasuredStrip({required this.child, required this.onSize});
  final Widget child;
  final ValueChanged<Size> onSize;

  @override
  State<_MeasuredStrip> createState() => _MeasuredStripState();
}

class _MeasuredStripState extends State<_MeasuredStrip> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(_report);
  }

  @override
  void didUpdateWidget(covariant _MeasuredStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback(_report);
  }

  void _report(Duration _) {
    final ctx = _key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      widget.onSize(box.size);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: _key, child: widget.child);
  }
}
