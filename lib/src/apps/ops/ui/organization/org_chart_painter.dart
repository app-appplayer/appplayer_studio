/// CustomPainter for the organization org-chart (event-topology layout).
/// Positions come from [OrgChartModel]; this only draws. Order: process card
/// bodies first, then edges (so dep arrows sit on the card), then the step /
/// gate / sign-off / agent / workspace nodes on top.
///
/// Edges: event (process→process, solid teal ⚡ — completion triggers the
/// next), dep (step→step, thin handoff arrow), sign-off (approver→step, dashed
/// amber), hierarchy (ws parent→child elbow).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'org_chart_model.dart';
import 'org_overlay.dart';

class OrgChartPainter extends CustomPainter {
  OrgChartPainter({required this.model, this.selectedId, this.overlay});

  final OrgChartModel model;
  final String? selectedId;

  /// Live layer (working glow · unit badges · delegation arrows) — null
  /// until the first overlay poll lands; the static chart draws unchanged.
  final OrgChartOverlay? overlay;

  OrgNode? _node(String id) {
    for (final n in model.nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// The ONE text style factory every label goes through — a single
  /// typographic scale instead of ten hand-rolled TextStyles.
  TextStyle _ts(
    double size, {
    FontWeight? weight,
    bool mono = false,
    Color? color,
  }) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        fontFamily: mono ? OpsType.mono : null,
        letterSpacing: mono ? OpsType.mono06 : null,
        color: color ?? OpsColors.text,
      );

  /// The ONE rounded frame (fill + stroke) every card/box goes through.
  void _frame(
    Canvas canvas,
    Rect rect, {
    required Color fill,
    required Color stroke,
    required double radius,
    double strokeWidth = 1.2,
  }) {
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(rr, Paint()..color = fill);
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = stroke,
    );
  }

  Color _triggerColor(String? badge) => switch (badge) {
    'event' => OpsColors.io, // teal — event-driven
    'task' => OpsColors.protocol, // blue — task-driven
    _ => OpsColors.textMute, // manual
  };

  @override
  void paint(Canvas canvas, Size size) {
    // Pass 1 — container bodies (process cards + structure unit boxes), drawn
    // under everything else so their members / steps sit on top.
    for (final n in model.nodes) {
      if (n.kind == OrgNodeKind.process) {
        _card(canvas, n);
      } else if (n.kind == OrgNodeKind.workspace && n.isContainer) {
        _unitBox(canvas, n);
      }
    }

    // Pass 2 — edges.
    for (final e in model.edges) {
      final a = _node(e.fromId);
      final b = _node(e.toId);
      if (a == null || b == null) continue;
      switch (e.kind) {
        case OrgEdgeKind.hierarchy:
          // Structure tree (container→container) gets the classic
          // top-down drop; the workflow/knowledge band stack keeps the
          // side-lane elbow so the line never crosses band content.
          if (a.isContainer && b.isContainer) {
            _elbow(canvas, a.rect, b.rect);
          } else {
            _laneElbow(canvas, a.rect, b.rect);
          }
        case OrgEdgeKind.reports:
          _reportLine(canvas, a.rect, b.rect);
        case OrgEdgeKind.event:
          _eventArrow(canvas, a.rect, b.rect);
        case OrgEdgeKind.dep:
          _arrow(canvas, a.rect.centerRight, b.rect.centerLeft,
              OpsColors.text2, 1.4);
        case OrgEdgeKind.signoff:
          _dashedArrow(canvas, a.rect.centerRight, b.rect.centerLeft,
              OpsColors.warn.withValues(alpha: 0.85));
        case OrgEdgeKind.ownership:
          canvas.drawLine(
            a.rect.centerRight,
            b.rect.centerLeft,
            Paint()
              ..color = OpsColors.knowledge.withValues(alpha: 0.45)
              ..strokeWidth = 1.1
              ..style = PaintingStyle.stroke,
          );
        case OrgEdgeKind.containment:
          break;
      }
    }

    // Pass 3 — nodes on top (skip process cards, already drawn).
    for (final n in model.nodes) {
      switch (n.kind) {
        case OrgNodeKind.process:
          break;
        case OrgNodeKind.gate:
          _diamond(canvas, n);
        case OrgNodeKind.workspace:
          if (!n.isContainer) _box(canvas, n, OpsColors.domain, isWorkspace: true);
        case OrgNodeKind.signoff:
          _box(canvas, n, OpsColors.warn, dotted: false);
        case OrgNodeKind.step:
          _box(canvas, n, OpsColors.app);
        case OrgNodeKind.agent:
          if (overlay?.activeNodeIds.contains(n.id) ?? false) {
            _activeGlow(canvas, n.rect);
          }
          _box(canvas, n, n.isLead ? OpsColors.domain : OpsColors.app);
        case OrgNodeKind.knowledge:
          _box(canvas, n, _axisColor(n.sublabel));
        case OrgNodeKind.role:
          _roleHeader(canvas, n);
        case OrgNodeKind.more:
          _box(canvas, n, OpsColors.textMute);
      }
    }

    // Pass 4 — live delegation arrows (recent `agent.routed`), on top of
    // everything: the point is to SEE work flow between people right now.
    final ov = overlay;
    if (ov != null) {
      for (final e in ov.routeEdges) {
        final a = _node(e.fromNodeId);
        final b = _node(e.toNodeId);
        if (a == null || b == null) continue;
        _delegationArrow(canvas, a.rect, b.rect, e.strength);
      }
    }
  }

  /// Bright ring behind an agent chip whose member invoked within the
  /// working window — "this seat is active right now".
  void _activeGlow(Canvas canvas, Rect rect) {
    final rr = RRect.fromRectAndRadius(
      rect.inflate(3),
      const Radius.circular(9),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..color = OpsColors.success.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..color = OpsColors.success
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  /// Delegation flow: a thick teal arrow from the delegating seat to the
  /// assignee, fading as the event ages out of the window.
  void _delegationArrow(Canvas canvas, Rect from, Rect to, double strength) {
    final c = OpsColors.io.withValues(alpha: 0.25 + 0.65 * strength);
    final p0 = from.center;
    final p1 = to.center;
    final dir = (p1 - p0);
    if (dir.distance < 1) return;
    // Trim ends so the arrow starts/stops at the chip borders, not centers.
    final unit = dir / dir.distance;
    final start = p0 + unit * (from.shortestSide / 2);
    final end = p1 - unit * (to.shortestSide / 2);
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = c
        ..strokeWidth = 2.0 + 1.2 * strength
        ..strokeCap = StrokeCap.round,
    );
    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    const s = 7.0;
    final tip1 = end - Offset(math.cos(angle - 0.45), math.sin(angle - 0.45)) * s;
    final tip2 = end - Offset(math.cos(angle + 0.45), math.sin(angle + 0.45)) * s;
    canvas.drawPath(
      Path()
        ..moveTo(end.dx, end.dy)
        ..lineTo(tip1.dx, tip1.dy)
        ..lineTo(tip2.dx, tip2.dy)
        ..close(),
      Paint()..color = c,
    );
  }

  Color _axisColor(String? axis) => switch (axis) {
    'skill' => OpsColors.knowledge, // purple
    'profile' => OpsColors.protocol, // blue
    'philosophy' => OpsColors.domain, // amber
    _ => OpsColors.knowledge,
  };

  /// Role-group header (structure lens) — an uppercase mono label + count, no
  /// box, with a thin rule beneath.
  void _roleHeader(Canvas canvas, OrgNode n) {
    final tp = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: n.label.toUpperCase(),
            style: _ts(OpsType.sm, mono: true, color: OpsColors.text2),
          ),
          if (n.sublabel != null)
            TextSpan(
              text: '  ·  ${n.sublabel}',
              style: _ts(OpsType.xs, color: OpsColors.text3),
            ),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(n.rect.left, n.rect.top + 2));
    canvas.drawLine(
      Offset(n.rect.left, n.rect.bottom),
      Offset(n.rect.right, n.rect.bottom),
      Paint()
        ..color = OpsColors.border
        ..strokeWidth = 1,
    );
  }

  // --- process card ---

  void _card(Canvas canvas, OrgNode n) {
    final selected = n.id == selectedId;
    final accent = _triggerColor(n.badge);
    _frame(
      canvas,
      n.rect,
      fill: OpsColors.surface.withValues(alpha: 0.55),
      stroke: OpsColors.io.withValues(alpha: selected ? 1.0 : 0.6),
      radius: 12,
      strokeWidth: selected ? 2.0 : 1.2,
    );
    // Header strip.
    final title = TextPainter(
      text: TextSpan(
        text: n.label,
        style: _ts(OpsType.md, weight: OpsType.semibold),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: n.rect.width - 24);
    title.paint(canvas, Offset(n.rect.left + 12, n.rect.top + 8));
    // Trigger badge (top-right).
    final badge = n.badge ?? 'manual';
    final bp = TextPainter(
      text: TextSpan(text: '▸ $badge', style: _ts(OpsType.xs, mono: true, color: accent)),
      textDirection: TextDirection.ltr,
    )..layout();
    bp.paint(canvas, Offset(n.rect.right - bp.width - 12, n.rect.top + 10));
    // Header rule — separates the title strip from the step flow.
    canvas.drawLine(
      Offset(n.rect.left + 1, n.rect.top + OrgChartMetrics.headerH - 4),
      Offset(n.rect.right - 1, n.rect.top + OrgChartMetrics.headerH - 4),
      Paint()
        ..color = OpsColors.border.withValues(alpha: 0.6)
        ..strokeWidth = 1,
    );
  }

  /// Structure-lens org-unit container — a framed box (amber) enclosing the
  /// unit's lead + members, with a header strip carrying the unit title.
  void _unitBox(Canvas canvas, OrgNode n) {
    final selected = n.id == selectedId;
    final pending = overlay?.pendingByUnit[n.wsId] ?? 0;
    // A unit with work stuck on approval is the thing the eye must find —
    // its frame turns to the warn color, matching its ⏳ badge.
    _frame(
      canvas,
      n.rect,
      fill: OpsColors.domain.withValues(alpha: 0.07),
      stroke: pending > 0
          ? OpsColors.warn.withValues(alpha: selected ? 1.0 : 0.9)
          : OpsColors.domain.withValues(alpha: selected ? 1.0 : 0.7),
      radius: 12,
      strokeWidth: selected ? 2.0 : (pending > 0 ? 1.8 : 1.3),
    );
    // Header title, sublabel baseline-aligned beside it.
    final title = TextPainter(
      text: TextSpan(
        text: n.label,
        style: _ts(OpsType.lg, weight: OpsType.semibold),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: n.rect.width - 120);
    title.paint(canvas, Offset(n.rect.left + 12, n.rect.top + 8));
    if (n.sublabel != null) {
      final sub = TextPainter(
        text: TextSpan(
          text: n.sublabel,
          style: _ts(OpsType.xs, mono: true, color: OpsColors.text3),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: n.rect.width - title.width - 140);
      sub.paint(
        canvas,
        Offset(
          n.rect.left + 12 + title.width + 8,
          n.rect.top + 8 + (title.height - sub.height),
        ),
      );
    }
    // Header rule — the unit title reads as a strip, not floating text.
    canvas.drawLine(
      Offset(n.rect.left + 1, n.rect.top + OrgChartMetrics.headerH - 4),
      Offset(n.rect.right - 1, n.rect.top + OrgChartMetrics.headerH - 4),
      Paint()
        ..color = OpsColors.domain.withValues(alpha: 0.25)
        ..strokeWidth = 1,
    );
    // Live badges, header right: ⏳ pending approvals (warn — the unit is
    // blocked on a person) · ▤ today's outputs (quiet count).
    final output = overlay?.outputTodayByUnit[n.wsId] ?? 0;
    var badgeRight = n.rect.right - 12;
    if (pending > 0) {
      badgeRight -= _headerBadge(
        canvas,
        right: badgeRight,
        top: n.rect.top + 8,
        text: '⏳ $pending',
        color: OpsColors.warn,
      );
      badgeRight -= 6;
    }
    if (output > 0) {
      _headerBadge(
        canvas,
        right: badgeRight,
        top: n.rect.top + 8,
        text: '▤ $output',
        color: OpsColors.text3,
      );
    }
  }

  /// Pill badge right-aligned in a unit header. Returns its painted width.
  double _headerBadge(
    Canvas canvas, {
    required double right,
    required double top,
    required String text,
    required Color color,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: _ts(OpsType.xs, mono: true, weight: OpsType.semibold, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromLTWH(right - tp.width - 12, top, tp.width + 12, 18);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(9)),
      Paint()..color = color.withValues(alpha: 0.14),
    );
    tp.paint(canvas, Offset(rect.left + 6, rect.top + (18 - tp.height) / 2));
    return rect.width;
  }

  // --- node boxes ---

  void _box(Canvas canvas, OrgNode n, Color base,
      {bool isWorkspace = false, bool dotted = false}) {
    final selected = n.id == selectedId;
    _frame(
      canvas,
      n.rect,
      fill: base.withValues(alpha: isWorkspace ? 0.20 : 0.14),
      stroke: base.withValues(alpha: (selected || n.isLead) ? 1.0 : 0.7),
      radius: isWorkspace ? 10 : 8,
      strokeWidth: selected ? 2.0 : (n.isLead ? 1.8 : 1.0),
    );
    // Left marker: agent / human icon for member nodes, a dot otherwise.
    if (n.kind == OrgNodeKind.agent) {
      _glyph(
        canvas,
        n.isAgent ? Icons.smart_toy_outlined : Icons.person_outline,
        n.rect.centerLeft + const Offset(13, 0),
        base,
        14,
      );
      if (n.isLead) {
        // Crown marker at the top-left corner for the unit lead.
        _glyph(canvas, Icons.star, n.rect.topLeft + const Offset(7, 7),
            OpsColors.domain, 11);
      }
    } else if (!isWorkspace && n.kind != OrgNodeKind.signoff) {
      canvas.drawCircle(
        n.rect.centerLeft + const Offset(11, 0),
        3.2,
        Paint()..color = base,
      );
    }
    _label(canvas, n, isWorkspace);
  }

  /// Draw a material icon glyph centered at [center].
  void _glyph(Canvas canvas, IconData icon, Offset center, Color color,
      double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _diamond(Canvas canvas, OrgNode n) {
    final c = n.rect.center;
    final r = n.rect.width / 2;
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx, c.dy + r)
      ..lineTo(c.dx - r, c.dy)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = OpsColors.knowledge.withValues(alpha: 0.9),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = n.id == selectedId ? 2 : 1.0
        ..color = OpsColors.knowledge,
    );
  }

  void _label(Canvas canvas, OrgNode n, bool isWorkspace) {
    // Text inset clears the node's left marker: member icon (agent), dot
    // (step/knowledge/…), none (sign-off chip / workspace header).
    final inset = isWorkspace
        ? 14.0
        : n.kind == OrgNodeKind.agent
            ? 28.0
            : n.kind == OrgNodeKind.signoff
                ? 12.0
                : 22.0;
    final left = n.rect.left + inset;
    final maxW = n.rect.width - inset - 10;
    final title = TextPainter(
      text: TextSpan(
        text: n.label,
        style: _ts(
          isWorkspace ? OpsType.lg : OpsType.sm,
          weight: isWorkspace ? OpsType.semibold : OpsType.medium,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxW);
    final hasSub = n.sublabel != null &&
        (isWorkspace ||
            n.kind == OrgNodeKind.step ||
            n.kind == OrgNodeKind.agent ||
            n.kind == OrgNodeKind.signoff);
    if (hasSub) {
      // Two-line rhythm centered in the node: title, 3px gap, mono sublabel.
      final sub = TextPainter(
        text: TextSpan(
          text: n.sublabel,
          style: _ts(OpsType.xs, mono: true, color: OpsColors.text3),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxW);
      final blockH = title.height + 3 + sub.height;
      final topY = n.rect.center.dy - blockH / 2;
      title.paint(canvas, Offset(left, topY));
      sub.paint(canvas, Offset(left, topY + title.height + 3));
    } else {
      title.paint(canvas, Offset(left, n.rect.center.dy - title.height / 2));
    }
  }

  // --- edges ---

  /// Side-lane elbow for the band-stacked lenses: down the parent's left
  /// margin, across into the child's left edge — never over band content.
  void _laneElbow(Canvas canvas, Rect parent, Rect child) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = OpsColors.domain.withValues(alpha: 0.7);
    final sx = parent.left + 16;
    canvas.drawPath(
      Path()
        ..moveTo(sx, parent.bottom)
        ..lineTo(sx, child.center.dy)
        ..lineTo(child.left, child.center.dy),
      paint,
    );
  }

  void _elbow(Canvas canvas, Rect parent, Rect child) {
    // Classic org-chart drop: parent bottom-center → half-gap bus →
    // child top-center.
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = OpsColors.domain.withValues(alpha: 0.7);
    final midY = (parent.bottom + child.top) / 2;
    canvas.drawPath(
      Path()
        ..moveTo(parent.center.dx, parent.bottom)
        ..lineTo(parent.center.dx, midY)
        ..lineTo(child.center.dx, midY)
        ..lineTo(child.center.dx, child.top),
      paint,
    );
  }

  /// Reporting line — lead (팀장) down to a team member, drawn as an elbow
  /// (down from the lead's bottom, across, down into the member's top).
  void _reportLine(Canvas canvas, Rect lead, Rect member) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..color = OpsColors.domain.withValues(alpha: 0.6);
    final midY = (lead.bottom + member.top) / 2;
    canvas.drawPath(
      Path()
        ..moveTo(lead.center.dx, lead.bottom)
        ..lineTo(lead.center.dx, midY)
        ..lineTo(member.center.dx, midY)
        ..lineTo(member.center.dx, member.top),
      paint,
    );
  }

  /// Event edge between two process cards — solid teal, ⚡ at the midpoint.
  void _eventArrow(Canvas canvas, Rect a, Rect b) {
    final from = a.centerRight;
    final to = b.centerLeft;
    _arrow(canvas, from, to, OpsColors.io, 2.0);
    final mid = Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);
    final tp = TextPainter(
      text: TextSpan(text: '⚡', style: _ts(OpsType.md, color: OpsColors.io)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, mid - Offset(tp.width / 2, tp.height / 2));
  }

  void _arrow(Canvas canvas, Offset a, Offset b, Color c, double w) {
    canvas.drawLine(
      a,
      b,
      Paint()
        ..color = c
        ..strokeWidth = w
        ..style = PaintingStyle.stroke,
    );
    _arrowHead(canvas, a, b, c);
  }

  void _dashedArrow(Canvas canvas, Offset a, Offset b, Color c) {
    final paint = Paint()
      ..color = c
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    const dash = 5.0, gap = 4.0;
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    var d = 0.0;
    while (d < total) {
      canvas.drawLine(
        a + dir * d,
        a + dir * math.min(d + dash, total),
        paint,
      );
      d += dash + gap;
    }
    _arrowHead(canvas, a, b, c);
  }

  void _arrowHead(Canvas canvas, Offset a, Offset b, Color c) {
    final ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
    const len = 7.0, spread = 0.5;
    final p1 = b - Offset(math.cos(ang - spread), math.sin(ang - spread)) * len;
    final p2 = b - Offset(math.cos(ang + spread), math.sin(ang + spread)) * len;
    canvas.drawPath(
      Path()
        ..moveTo(b.dx, b.dy)
        ..lineTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)
        ..close(),
      Paint()
        ..color = c
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant OrgChartPainter old) =>
      old.model != model ||
      old.selectedId != selectedId ||
      old.overlay != overlay;
}
