// Phase 3 dedicated implicit-animation wrappers — 1:1 maps onto
// Flutter's `Animated*` family. Each accepts the Phase 3 spec
// shape (`duration` / `curve` / `onEnd` + the property-specific
// payload) and emits the matching Flutter widget.

import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Resolve the spec § AnimationCurve enum to a Flutter [Curve].
Curve _resolveCurve(dynamic value) {
  switch (value) {
    case 'linear':
      return Curves.linear;
    case 'easeIn':
      return Curves.easeIn;
    case 'easeOut':
      return Curves.easeOut;
    case 'easeInOut':
      return Curves.easeInOut;
    // M3 standard: minimal overshoot, clean cubic.
    case 'standard':
      return Curves.fastOutSlowIn;
    case 'standardAccelerate':
      return Curves.easeIn;
    case 'standardDecelerate':
      return Curves.easeOut;
    // M3 emphasized: more dramatic acceleration profile.
    case 'emphasized':
      return Curves.easeInOutCubicEmphasized;
    case 'emphasizedAccelerate':
      return Curves.easeInCubic;
    case 'emphasizedDecelerate':
      return Curves.easeOutCubic;
    case 'bounceIn':
      return Curves.bounceIn;
    case 'bounceOut':
      return Curves.bounceOut;
  }
  return Curves.easeInOut;
}

Duration _resolveDuration(dynamic value, {int fallbackMs = 300}) {
  if (value is num) return Duration(milliseconds: value.toInt());
  if (value is Map && value['value'] is num) {
    return Duration(milliseconds: (value['value'] as num).toInt());
  }
  return Duration(milliseconds: fallbackMs);
}

class AnimatedOpacityWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final opacity =
        (context.resolve(properties['opacity']) as num?)?.toDouble() ?? 1.0;
    final childDef = properties['child'] as Map<String, dynamic>?;
    final child =
        childDef != null ? context.buildWidget(childDef) : const SizedBox();

    return AnimatedOpacity(
      opacity: opacity.clamp(0.0, 1.0),
      duration: _resolveDuration(context.resolve(properties['duration'])),
      curve: _resolveCurve(context.resolve(properties['curve'])),
      onEnd: _onEndCallback(properties['onEnd'], context),
      child: child,
    );
  }
}

class AnimatedAlignWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final alignment = parseAlignment(
            context.resolve(properties['alignment'])) ??
        Alignment.center;
    final childDef = properties['child'] as Map<String, dynamic>?;
    final child =
        childDef != null ? context.buildWidget(childDef) : const SizedBox();

    return AnimatedAlign(
      alignment: alignment,
      duration: _resolveDuration(context.resolve(properties['duration'])),
      curve: _resolveCurve(context.resolve(properties['curve'])),
      onEnd: _onEndCallback(properties['onEnd'], context),
      child: child,
    );
  }
}

class AnimatedPositionedWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final childDef = properties['child'] as Map<String, dynamic>?;
    final child =
        childDef != null ? context.buildWidget(childDef) : const SizedBox();

    return AnimatedPositioned(
      top: parseDimension(context.resolve(properties['top'])),
      right: parseDimension(context.resolve(properties['right'])),
      bottom: parseDimension(context.resolve(properties['bottom'])),
      left: parseDimension(context.resolve(properties['left'])),
      width: parseDimension(context.resolve(properties['width'])),
      height: parseDimension(context.resolve(properties['height'])),
      duration: _resolveDuration(context.resolve(properties['duration'])),
      curve: _resolveCurve(context.resolve(properties['curve'])),
      onEnd: _onEndCallback(properties['onEnd'], context),
      child: child,
    );
  }
}

class AnimatedDefaultTextStyleWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final styleMap = context.resolve<dynamic>(properties['style']);
    final style =
        styleMap is Map ? _parseTextStyle(styleMap.cast<String, dynamic>(), context) : const TextStyle();
    final childDef = properties['child'] as Map<String, dynamic>?;
    final child =
        childDef != null ? context.buildWidget(childDef) : const SizedBox();

    return AnimatedDefaultTextStyle(
      style: style,
      duration: _resolveDuration(context.resolve(properties['duration'])),
      curve: _resolveCurve(context.resolve(properties['curve'])),
      onEnd: _onEndCallback(properties['onEnd'], context),
      child: child,
    );
  }

  TextStyle _parseTextStyle(
      Map<String, dynamic> style, RenderContext context) {
    return TextStyle(
      fontSize: parseDimension(context.resolve(style['fontSize'])),
      fontWeight: _parseFontWeight(context.resolve(style['fontWeight'])),
      color: parseColor(context.resolve(style['color']), context),
      letterSpacing: parseDimension(context.resolve(style['letterSpacing'])),
      height: parseDimension(context.resolve(style['height'])),
    );
  }

  FontWeight? _parseFontWeight(dynamic value) {
    if (value is num) {
      final idx = (value.toInt() ~/ 100) - 1;
      if (idx >= 0 && idx < FontWeight.values.length) {
        return FontWeight.values[idx];
      }
    }
    if (value is String) {
      switch (value) {
        case 'thin':
        case 'w100':
          return FontWeight.w100;
        case 'extraLight':
        case 'w200':
          return FontWeight.w200;
        case 'light':
        case 'w300':
          return FontWeight.w300;
        case 'normal':
        case 'regular':
        case 'w400':
          return FontWeight.w400;
        case 'medium':
        case 'w500':
          return FontWeight.w500;
        case 'semiBold':
        case 'w600':
          return FontWeight.w600;
        case 'bold':
        case 'w700':
          return FontWeight.w700;
        case 'extraBold':
        case 'w800':
          return FontWeight.w800;
        case 'black':
        case 'w900':
          return FontWeight.w900;
      }
    }
    return null;
  }
}

class HeroWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);
    final tag = context.resolve(properties['tag']) as String? ?? '';
    final transitionOnUserGestures =
        context.resolve(properties['transitionOnUserGestures']) as bool? ??
            false;
    final childDef = properties['child'] as Map<String, dynamic>?;
    final child =
        childDef != null ? context.buildWidget(childDef) : const SizedBox();

    // Spec § hero.flightShuttleBuilder — optional intermediate widget
    // rendered during the morph. Read so the resolver records the
    // author's intent; the actual shuttle wiring routes through
    // Flutter's `flightShuttleBuilder` callback in a later cycle.
    final shuttleDef = properties['flightShuttleBuilder'];

    return Hero(
      tag: tag,
      transitionOnUserGestures: transitionOnUserGestures,
      flightShuttleBuilder: shuttleDef is Map<String, dynamic>
          ? (ctx, anim, dir, fromCtx, toCtx) =>
              context.buildWidget(shuttleDef)
          : null,
      child: child,
    );
  }
}

VoidCallback? _onEndCallback(dynamic action, RenderContext context) {
  if (action is! Map) return null;
  return () {
    context.actionHandler.execute(
      action.cast<String, dynamic>(),
      context,
    );
  };
}
