/// Flutter widget that renders every active overlay on top of the
/// shell body. Mounted INSIDE the shell's `RepaintBoundary` so
/// overlays appear in `studio.renderer.screenshot` captures (and
/// every frame the recorder writes).
///
/// Performance: when no overlays are active the widget collapses to a
/// `SizedBox.shrink` and consumes no animation ticks. Each active
/// overlay only spins up the animation controllers its kind actually
/// needs (e.g. pulse_dot keeps a repeating tween, subtitle does
/// not). The host calls into this layer through an [OverlayController]
/// so MCP push handlers never touch widget state directly.
library;

import 'package:flutter/material.dart';

import 'overlay_controller.dart';
import 'overlay_models.dart';
import 'painters/arrow_pointer.dart';
import 'painters/check_mark.dart';
import 'painters/circle_highlight.dart';
import 'painters/cross_mark.dart';
import 'painters/cursor.dart';
import 'painters/lecture.dart';
import 'painters/media.dart';
import 'painters/pulse_dot.dart';
import 'painters/shared.dart';
import 'painters/speech_bubble.dart';
import 'painters/widget_overlays.dart';
import 'targets/position_ref.dart';

/// Resolves element/metadata position refs against the host. The
/// host wires this from `chromeBridge.captureLayoutSnapshot` (or a
/// faster cached resolver). Returns `null` for unresolvable refs so
/// the overlay skips drawing rather than crashing.
typedef ElementRectResolver = Rect? Function(String elementId);

/// Pulse-driven kinds repeat their animation forever (until removed).
/// Draw-on kinds drive their animation from the lifecycle progress
/// instead — no repeating controller needed. Widget-form kinds
/// (subtitle / title_card / step_indicator / watermark / floating_*)
/// rely only on fade opacity.
const Set<OverlayKind> _pulseKinds = <OverlayKind>{
  OverlayKind.pulseDot,
  OverlayKind.circleHighlight,
};

const Set<OverlayKind> _drawOnKinds = <OverlayKind>{
  OverlayKind.arrowPointer,
  OverlayKind.checkMark,
  OverlayKind.crossMark,
  OverlayKind.underline,
  OverlayKind.strikethrough,
  OverlayKind.highlighter,
  OverlayKind.boxOutline,
  OverlayKind.bracket,
  OverlayKind.connectorLine,
};

class OverlayLayer extends StatelessWidget {
  const OverlayLayer({
    super.key,
    required this.controller,
    this.elementResolver,
  });

  final OverlayController controller;
  final ElementRectResolver? elementResolver;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<OverlaySpec>>(
      valueListenable: controller,
      builder: (context, specs, _) {
        if (specs.isEmpty) return const SizedBox.shrink();
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              for (final spec in specs)
                _OverlayHost(
                  key: ValueKey(spec.id),
                  spec: spec,
                  elementResolver: elementResolver,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _OverlayHost extends StatefulWidget {
  const _OverlayHost({super.key, required this.spec, this.elementResolver});
  final OverlaySpec spec;
  final ElementRectResolver? elementResolver;

  @override
  State<_OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState extends State<_OverlayHost>
    with TickerProviderStateMixin {
  late final AnimationController _life;
  AnimationController? _pulse;

  @override
  void initState() {
    super.initState();
    final stay = widget.spec.stayMs == 0 ? 4000 : widget.spec.stayMs;
    final total = widget.spec.appearMs + stay + widget.spec.fadeMs;
    _life = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: total),
    )..forward();
    if (_pulseKinds.contains(widget.spec.kind)) {
      _pulse = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200),
      )..repeat();
    }
  }

  @override
  void dispose() {
    _life.dispose();
    _pulse?.dispose();
    super.dispose();
  }

  double _fadeOpacity() {
    final totalMs = _life.duration!.inMilliseconds;
    if (totalMs == 0) return 1;
    final ms = _life.value * totalMs;
    final appear = widget.spec.appearMs.toDouble();
    final stay =
        widget.spec.stayMs == 0
            ? (totalMs - appear - widget.spec.fadeMs).toDouble()
            : widget.spec.stayMs.toDouble();
    final fade = widget.spec.fadeMs.toDouble();
    if (ms < appear) return ms / appear;
    if (ms < appear + stay) return 1;
    final fadeT = (ms - appear - stay) / fade;
    return (1.0 - fadeT).clamp(0.0, 1.0);
  }

  double _drawProgress() {
    final totalMs = _life.duration!.inMilliseconds;
    final appear = widget.spec.appearMs;
    if (totalMs == 0 || appear == 0) return 1;
    final ms = _life.value * totalMs;
    return (ms / appear).clamp(0.0, 1.0);
  }

  /// Click ripple progress for the cursor — runs over [clickMs] starting
  /// the moment travel (appear) completes. Returns < 0 before the click
  /// fires (and forever when the spec has no click).
  double _clickProgress(int clickMs) {
    final totalMs = _life.duration!.inMilliseconds;
    if (totalMs == 0 || clickMs <= 0) return -1;
    final ms = _life.value * totalMs;
    final start = widget.spec.appearMs.toDouble();
    if (ms < start) return -1;
    return ((ms - start) / clickMs).clamp(0.0, 1.0);
  }

  Rect? _resolveTarget(PositionRef? ref) {
    if (ref == null) return null;
    if (ref.x != null) return resolveAbs(ref);
    if (ref.element != null && widget.elementResolver != null) {
      return widget.elementResolver!(ref.element!);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[_life, if (_pulse != null) _pulse!];
    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (context, _) {
        final opacity = _fadeOpacity();
        if (opacity <= 0) return const SizedBox.shrink();
        return _renderKind(opacity);
      },
    );
  }

  Widget _renderKind(double opacity) {
    final spec = widget.spec;
    switch (spec.kind) {
      case OverlayKind.titleCard:
        return TitleCardOverlay(props: spec.props, fadeOpacity: opacity);
      case OverlayKind.subtitle:
        return SubtitleOverlay(props: spec.props, fadeOpacity: opacity);
      case OverlayKind.stepIndicator:
        return StepIndicatorOverlay(props: spec.props, fadeOpacity: opacity);
      case OverlayKind.watermark:
        return WatermarkOverlay(props: spec.props, fadeOpacity: opacity);
      case OverlayKind.circleHighlight:
        {
          final target = _resolveTarget(spec.target);
          if (target == null) return const SizedBox.shrink();
          return Opacity(
            opacity: opacity,
            child: CustomPaint(
              painter: CircleHighlightPainter(
                target: target,
                progress: _pulse?.value ?? 0,
                props: spec.props,
              ),
            ),
          );
        }
      case OverlayKind.checkMark:
        {
          final target = _resolveTarget(spec.target);
          if (target == null) return const SizedBox.shrink();
          return Opacity(
            opacity: opacity,
            child: CustomPaint(
              painter: CheckMarkPainter(
                center: target.center,
                progress: _drawProgress(),
                props: spec.props,
              ),
            ),
          );
        }
      case OverlayKind.crossMark:
        {
          final target = _resolveTarget(spec.target);
          if (target == null) return const SizedBox.shrink();
          return Opacity(
            opacity: opacity,
            child: CustomPaint(
              painter: CrossMarkPainter(
                center: target.center,
                progress: _drawProgress(),
                props: spec.props,
              ),
            ),
          );
        }
      case OverlayKind.pulseDot:
        {
          final target = _resolveTarget(spec.target);
          if (target == null) return const SizedBox.shrink();
          return Opacity(
            opacity: opacity,
            child: CustomPaint(
              painter: PulseDotPainter(
                center: target.center,
                progress: _pulse?.value ?? 0,
                props: spec.props,
              ),
            ),
          );
        }
      case OverlayKind.arrowPointer:
        {
          final target = _resolveTarget(spec.target);
          if (target == null) return const SizedBox.shrink();
          final text = stringProp(spec.props, 'text', '');
          final tp = TextPainter(
            text: TextSpan(
              text: text,
              style: const TextStyle(
                color: kTextOnDark,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 2,
          );
          return Opacity(
            opacity: opacity,
            child: CustomPaint(
              painter: ArrowPointerPainter(
                target: target,
                progress: _drawProgress(),
                text: text,
                props: spec.props,
                textPainter: tp,
              ),
            ),
          );
        }
      case OverlayKind.highlighter:
      case OverlayKind.underline:
      case OverlayKind.strikethrough:
      case OverlayKind.boxOutline:
      case OverlayKind.bracket:
      case OverlayKind.numberedLabel:
        return _renderLecture(opacity);
      case OverlayKind.speechBubble:
        {
          final target = _resolveTarget(spec.target);
          if (target == null) return const SizedBox.shrink();
          return Opacity(
            opacity: opacity,
            child: SpeechBubbleOverlay(target: target, props: spec.props),
          );
        }
      case OverlayKind.connectorLine:
        {
          final targets = spec.targets
              ?.map(_resolveTarget)
              .whereType<Rect>()
              .toList(growable: false);
          if (targets == null || targets.length < 2) {
            return const SizedBox.shrink();
          }
          return Opacity(
            opacity: opacity,
            child: CustomPaint(
              painter: ConnectorLinePainter(
                from: targets[0].center,
                to: targets[1].center,
                progress: _drawProgress(),
                props: spec.props,
              ),
            ),
          );
        }
      case OverlayKind.floatingIcon:
        {
          final target = _resolveTarget(spec.target);
          return Opacity(
            opacity: opacity,
            child: FloatingIconOverlay(
              target: target,
              props: spec.props,
              entrance: _drawProgress(),
            ),
          );
        }
      case OverlayKind.floatingImage:
        {
          final target = _resolveTarget(spec.target);
          return Opacity(
            opacity: opacity,
            child: FloatingImageOverlay(
              target: target,
              props: spec.props,
              entrance: _drawProgress(),
            ),
          );
        }
      case OverlayKind.slide:
        return Opacity(
          opacity: opacity,
          child: SlideOverlay(props: spec.props, entrance: _drawProgress()),
        );
      case OverlayKind.cursor:
        {
          // Travel from targets[0] → targets[1] over the appear window
          // (eased); a single `target` parks the cursor in place. Click
          // ripple (props.click) fires once travel completes.
          final pts = spec.targets
              ?.map(_resolveTarget)
              .whereType<Rect>()
              .toList(growable: false);
          Offset? position;
          if (pts != null && pts.length >= 2) {
            final t = Curves.easeInOut.transform(_drawProgress());
            position = Offset.lerp(pts[0].center, pts[1].center, t);
          } else {
            final single =
                _resolveTarget(spec.target) ??
                (pts != null && pts.isNotEmpty ? pts.first : null);
            position = single?.center;
          }
          if (position == null) return const SizedBox.shrink();
          final click = spec.props['click'] == true;
          final clickMs = (spec.props['clickMs'] as num?)?.toInt() ?? 350;
          return Opacity(
            opacity: opacity,
            child: CustomPaint(
              painter: CursorPainter(
                position: position,
                clickProgress: click ? _clickProgress(clickMs) : -1,
                props: spec.props,
              ),
            ),
          );
        }
      case OverlayKind.transition:
        // Transitions are applied between scenes by the scenario engine —
        // not a free-floating overlay. Skip render here.
        return const SizedBox.shrink();
    }
  }

  Widget _renderLecture(double opacity) {
    final spec = widget.spec;
    final target = _resolveTarget(spec.target);
    final targets = spec.targets
        ?.map(_resolveTarget)
        .whereType<Rect>()
        .toList(growable: false);
    return Opacity(
      opacity: opacity,
      child: CustomPaint(
        painter: LecturePainter(
          kind: spec.kind,
          target: target,
          targets: targets,
          progress: _drawProgress(),
          props: spec.props,
        ),
      ),
    );
  }
}
