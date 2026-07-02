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

class OrgChartPainter extends CustomPainter {
  OrgChartPainter({required this.model, this.selectedId});

  final OrgChartModel model;
  final String? selectedId;

  OrgNode? _node(String id) {
    for (final n in model.nodes) {
      if (n.id == id) return n;
    }
    return null;
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
          _elbow(canvas, a.rect, b.rect);
        case OrgEdgeKind.reports:
          _reportLine(canvas, a.rect, b.rect);
        case OrgEdgeKind.event:
          _eventArrow(canvas, a.rect, b.rect);
        case OrgEdgeKind.dep:
          _arrow(canvas, a.rect.centerRight, b.rect.centerLeft,
              OpsColors.text2, 1.4);
        case OrgEdgeKind.signoff:
          _dashedArrow(canvas, a.rect.bottomCenter, b.rect.topCenter,
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
          _box(canvas, n, n.isLead ? OpsColors.domain : OpsColors.app);
        case OrgNodeKind.knowledge:
          _box(canvas, n, _axisColor(n.sublabel));
        case OrgNodeKind.role:
          _roleHeader(canvas, n);
        case OrgNodeKind.more:
          _box(canvas, n, OpsColors.textMute);
      }
    }
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
            style: TextStyle(
              fontSize: OpsType.sm,
              fontFamily: OpsType.mono,
              letterSpacing: OpsType.mono06,
              color: OpsColors.text2,
            ),
          ),
          if (n.sublabel != null)
            TextSpan(
              text: '  ·  ${n.sublabel}',
              style: TextStyle(fontSize: OpsType.xs, color: OpsColors.text3),
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
    final rr = RRect.fromRectAndRadius(n.rect, const Radius.circular(10));
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.fill
        ..color = OpsColors.surface.withValues(alpha: 0.55),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.0 : 1.2
        ..color = OpsColors.io.withValues(alpha: selected ? 1.0 : 0.6),
    );
    // Header strip.
    final title = TextPainter(
      text: TextSpan(
        text: n.label,
        style: TextStyle(
          fontSize: OpsType.md,
          fontWeight: OpsType.semibold,
          color: OpsColors.text,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: n.rect.width - 24);
    title.paint(canvas, Offset(n.rect.left + 12, n.rect.top + 8));
    // Trigger badge (top-right).
    final badge = n.badge ?? 'manual';
    final bp = TextPainter(
      text: TextSpan(
        text: '▸ $badge',
        style: TextStyle(
          fontSize: OpsType.xs,
          fontFamily: OpsType.mono,
          color: accent,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    bp.paint(canvas, Offset(n.rect.right - bp.width - 12, n.rect.top + 10));
  }

  /// Structure-lens org-unit container — a framed box (amber) enclosing the
  /// unit's lead + members, with a header strip carrying the unit title.
  void _unitBox(Canvas canvas, OrgNode n) {
    final selected = n.id == selectedId;
    final rr = RRect.fromRectAndRadius(n.rect, const Radius.circular(12));
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.fill
        ..color = OpsColors.domain.withValues(alpha: 0.07),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.0 : 1.3
        ..color = OpsColors.domain.withValues(alpha: selected ? 1.0 : 0.7),
    );
    // Header title + sublabel (type · member count).
    final title = TextPainter(
      text: TextSpan(
        text: n.label,
        style: TextStyle(
          fontSize: OpsType.lg,
          fontWeight: OpsType.semibold,
          color: OpsColors.text,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: n.rect.width - 28);
    title.paint(canvas, Offset(n.rect.left + 14, n.rect.top + 9));
    if (n.sublabel != null) {
      final sub = TextPainter(
        text: TextSpan(
          text: n.sublabel,
          style: TextStyle(
            fontSize: OpsType.xs,
            fontFamily: OpsType.mono,
            color: OpsColors.text3,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      sub.paint(
        canvas,
        Offset(n.rect.left + 16 + title.width, n.rect.top + 15),
      );
    }
  }

  // --- node boxes ---

  void _box(Canvas canvas, OrgNode n, Color base,
      {bool isWorkspace = false, bool dotted = false}) {
    final selected = n.id == selectedId;
    final rr = RRect.fromRectAndRadius(
      n.rect,
      Radius.circular(isWorkspace ? 10 : 7),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.fill
        ..color = base.withValues(alpha: isWorkspace ? 0.20 : 0.14),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 2.0 : (n.isLead ? 1.8 : 1.0)
        ..color = base.withValues(alpha: (selected || n.isLead) ? 1.0 : 0.7),
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
    final left = n.rect.left + (isWorkspace ? 14 : 20);
    final maxW = n.rect.width - (isWorkspace ? 24 : 28);
    final title = TextPainter(
      text: TextSpan(
        text: n.label,
        style: TextStyle(
          fontSize: isWorkspace ? OpsType.lg : OpsType.sm,
          fontWeight: isWorkspace ? OpsType.semibold : OpsType.medium,
          color: OpsColors.text,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxW);
    final hasSub = n.sublabel != null &&
        (isWorkspace || n.kind == OrgNodeKind.step || n.kind == OrgNodeKind.agent);
    if (hasSub) {
      title.paint(canvas, Offset(left, n.rect.top + (isWorkspace ? 6 : 5)));
      final sub = TextPainter(
        text: TextSpan(
          text: n.sublabel,
          style: TextStyle(
            fontSize: OpsType.xs,
            fontFamily: OpsType.mono,
            color: OpsColors.text3,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxW);
      sub.paint(canvas, Offset(left, n.rect.top + (isWorkspace ? 26 : 24)));
    } else {
      title.paint(canvas, Offset(left, n.rect.center.dy - title.height / 2));
    }
  }

  // --- edges ---

  void _elbow(Canvas canvas, Rect parent, Rect child) {
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
      text: TextSpan(
        text: '⚡',
        style: TextStyle(fontSize: OpsType.md, color: OpsColors.io),
      ),
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
      old.model != model || old.selectedId != selectedId;
}
