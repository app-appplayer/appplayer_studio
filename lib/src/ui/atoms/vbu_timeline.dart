/// Horizontal duration-proportional timeline — step blocks across the
/// top, optional overlay tracks below, scrub indicator, click-to-select.
/// Designed for Scene Builder scenario editing but generic enough that
/// any "sequence of timed events" surface (test scheduler, automation
/// playback, monitor playback) can use it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tokens.dart';

/// One step block.
class VbuTimelineStep {
  const VbuTimelineStep({
    required this.label,
    required this.durationMs,
    this.color,
    this.icon,
  });
  final String label;
  final int durationMs;
  final Color? color;
  final IconData? icon;
}

/// Track of timed-region entries layered below the step strip
/// (watermark / step_indicator / subtitle overlays that span more
/// than one step).
class VbuTimelineTrack {
  const VbuTimelineTrack({required this.label, required this.regions});
  final String label;
  final List<VbuTimelineRegion> regions;
}

class VbuTimelineRegion {
  const VbuTimelineRegion({
    required this.atMs,
    required this.durationMs,
    required this.label,
    this.color,
  });
  final int atMs;
  final int durationMs;
  final String label;
  final Color? color;
}

class VbuTimeline extends StatelessWidget {
  const VbuTimeline({
    super.key,
    required this.steps,
    this.tracks = const <VbuTimelineTrack>[],
    this.selectedIndex,
    this.onSelectStep,
    this.scrubMs,
    this.pixelsPerSecond = 80,
    this.stepHeight = 36,
    this.trackHeight = 22,
  });

  final List<VbuTimelineStep> steps;
  final List<VbuTimelineTrack> tracks;

  /// Which step is currently focused.
  final int? selectedIndex;
  final ValueChanged<int>? onSelectStep;

  /// Current playhead position in milliseconds (null = no scrub line).
  final int? scrubMs;

  /// Horizontal density. 80 px/s gives a typical 30s demo a ~2.4k-px
  /// width.
  final double pixelsPerSecond;

  final double stepHeight;
  final double trackHeight;

  int get _totalMs {
    var total = 0;
    for (final s in steps) {
      total += s.durationMs;
    }
    // Tracks may extend past steps — honour the longest end.
    for (final t in tracks) {
      for (final r in t.regions) {
        final end = r.atMs + r.durationMs;
        if (end > total) total = end;
      }
    }
    return total;
  }

  double get _totalWidth => math.max(120, _totalMs * pixelsPerSecond / 1000);

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final totalH = stepHeight + tracks.length * (trackHeight + 4) + 24;
    return SizedBox(
      height: totalH,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: _totalWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _StepStrip(
                steps: steps,
                pixelsPerSecond: pixelsPerSecond,
                height: stepHeight,
                selectedIndex: selectedIndex,
                onSelect: onSelectStep,
              ),
              for (final t in tracks) ...<Widget>[
                const SizedBox(height: 4),
                _TrackStrip(
                  track: t,
                  totalMs: _totalMs,
                  pixelsPerSecond: pixelsPerSecond,
                  height: trackHeight,
                ),
              ],
              const SizedBox(height: 4),
              _Ruler(
                totalMs: _totalMs,
                pixelsPerSecond: pixelsPerSecond,
                color: c.textTertiary,
                scrubMs: scrubMs,
                scrubColor: c.mint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepStrip extends StatelessWidget {
  const _StepStrip({
    required this.steps,
    required this.pixelsPerSecond,
    required this.height,
    required this.selectedIndex,
    required this.onSelect,
  });
  final List<VbuTimelineStep> steps;
  final double pixelsPerSecond;
  final double height;
  final int? selectedIndex;
  final ValueChanged<int>? onSelect;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return SizedBox(
      height: height,
      child: Row(
        children: <Widget>[
          for (var i = 0; i < steps.length; i++)
            _StepBlock(
              index: i,
              step: steps[i],
              width: math.max(40, steps[i].durationMs * pixelsPerSecond / 1000),
              color: steps[i].color ?? c.mint,
              selected: i == selectedIndex,
              onTap: onSelect == null ? null : () => onSelect!(i),
            ),
        ],
      ),
    );
  }
}

class _StepBlock extends StatelessWidget {
  const _StepBlock({
    required this.index,
    required this.step,
    required this.width,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final int index;
  final VbuTimelineStep step;
  final double width;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final body = Container(
      width: width,
      margin: const EdgeInsets.only(right: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(selected ? 0.4 : 0.18),
        border: Border.all(
          color: selected ? color : color.withOpacity(0.4),
          width: selected ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.centerLeft,
      child: Row(
        children: <Widget>[
          if (step.icon != null) ...<Widget>[
            Icon(step.icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              step.label,
              style: TextStyle(
                fontFamily: VbuTokens.fontSans,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return body;
    return GestureDetector(onTap: onTap, child: body);
  }
}

class _TrackStrip extends StatelessWidget {
  const _TrackStrip({
    required this.track,
    required this.totalMs,
    required this.pixelsPerSecond,
    required this.height,
  });
  final VbuTimelineTrack track;
  final int totalMs;
  final double pixelsPerSecond;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final w = math.max(120.0, totalMs * pixelsPerSecond / 1000);
    return SizedBox(
      width: w,
      height: height,
      child: Stack(
        children: <Widget>[
          // Track background bar.
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Track label.
          Positioned(
            left: 6,
            top: 0,
            bottom: 0,
            child: Center(
              child: Text(
                track.label,
                style: TextStyle(
                  fontFamily: VbuTokens.fontMono,
                  fontSize: 10,
                  color: c.textTertiary,
                ),
              ),
            ),
          ),
          for (final r in track.regions)
            Positioned(
              left: r.atMs * pixelsPerSecond / 1000,
              top: 2,
              bottom: 2,
              width: math.max(2, r.durationMs * pixelsPerSecond / 1000),
              child: Container(
                decoration: BoxDecoration(
                  color: (r.color ?? c.amber).withOpacity(0.5),
                  borderRadius: BorderRadius.circular(3),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.centerLeft,
                child: Text(
                  r.label,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontSans,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Ruler extends StatelessWidget {
  const _Ruler({
    required this.totalMs,
    required this.pixelsPerSecond,
    required this.color,
    required this.scrubMs,
    required this.scrubColor,
  });
  final int totalMs;
  final double pixelsPerSecond;
  final Color color;
  final int? scrubMs;
  final Color scrubColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: CustomPaint(
        size: Size(math.max(120, totalMs * pixelsPerSecond / 1000), 20),
        painter: _RulerPainter(
          totalMs: totalMs,
          pixelsPerSecond: pixelsPerSecond,
          color: color,
          scrubMs: scrubMs,
          scrubColor: scrubColor,
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.totalMs,
    required this.pixelsPerSecond,
    required this.color,
    required this.scrubMs,
    required this.scrubColor,
  });
  final int totalMs;
  final double pixelsPerSecond;
  final Color color;
  final int? scrubMs;
  final Color scrubColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint =
        Paint()
          ..color = color
          ..strokeWidth = 1;
    // Tick every second; longer tick every 5.
    final totalSec = (totalMs / 1000).ceil();
    for (var s = 0; s <= totalSec; s++) {
      final x = s * pixelsPerSecond;
      final tall = s % 5 == 0;
      canvas.drawLine(Offset(x, 0), Offset(x, tall ? 10 : 5), paint);
      if (tall) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${s}s',
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontFamily: 'monospace',
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(x + 2, 8));
      }
    }
    // Scrub line.
    if (scrubMs != null) {
      final sx = scrubMs! * pixelsPerSecond / 1000;
      final scrubPaint =
          Paint()
            ..color = scrubColor
            ..strokeWidth = 2;
      canvas.drawLine(Offset(sx, 0), Offset(sx, size.height), scrubPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RulerPainter old) =>
      old.totalMs != totalMs ||
      old.pixelsPerSecond != pixelsPerSecond ||
      old.scrubMs != scrubMs;
}
