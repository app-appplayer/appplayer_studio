import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' as core;

import '../../renderer/render_context.dart';
import '../decoration/box_decoration_resolver.dart';
import '../widget_factory.dart';

/// Factory for Container widgets
class ContainerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Container is a single-child widget, so child should be in properties
    Widget? child;
    final childDef = properties['child'] as Map<String, dynamic>?;
    if (childDef != null) {
      child = context.buildWidget(childDef);
    }

    // Resolve properties that might contain bindings
    final padding =
        _resolveEdgeInsets(properties[core.PropertyKeys.padding], context);
    final margin =
        _resolveEdgeInsets(properties[core.PropertyKeys.margin], context);
    // Use parseDimension to support MCP UI DSL v1.0 format
    final width =
        parseDimension(context.resolve(properties[core.PropertyKeys.width]));
    final height =
        parseDimension(context.resolve(properties[core.PropertyKeys.height]));

    // Build BoxDecoration via the shared resolver. It accepts the full
    // `decoration: {...}` map AND any flat top-level shorthand fields
    // (color/backgroundColor/borderRadius/border/gradient/image/shadow/...)
    // so callers can mix freely. See `BoxDecorationResolver.resolve`.
    //
    // Spec § 2.4.1 documents `color` as a top-level box shorthand; merge
    // the legacy `backgroundColor` alias into the same slot before
    // dispatching so the resolver only has to look at one key. Only
    // overlay when at least one top-level value is actually present —
    // overwriting `color` with null would silently shadow whatever the
    // caller put inside `decoration: {color: ...}` and the resolver's
    // flat-vs-nested override pass would erase it.
    final boxColor = properties['color'] ?? properties['backgroundColor'];
    final flatProps = boxColor != null
        ? <String, dynamic>{...properties, 'color': boxColor}
        : properties;
    final decoration = BoxDecorationResolver.resolve(
      flatProps,
      context,
      host: this,
    );
    final backdropSigma = BoxDecorationResolver.backdropBlurSigma(flatProps);

    // Constraints — accept either the nested object form
    // (`constraints: {minWidth, maxWidth, minHeight, maxHeight}`) OR
    // top-level shorthand fields (`minWidth: ..., maxWidth: ..., ...`)
    // per spec § 2.4.1. The flat form lets `box` fully absorb what the
    // legacy `constrained` widget expressed.
    BoxConstraints? boxConstraints =
        parseConstraints(properties['constraints']);
    final flatMinW =
        parseDimension(context.resolve(properties['minWidth']));
    final flatMaxW =
        parseDimension(context.resolve(properties['maxWidth']));
    final flatMinH =
        parseDimension(context.resolve(properties['minHeight']));
    final flatMaxH =
        parseDimension(context.resolve(properties['maxHeight']));
    if (flatMinW != null ||
        flatMaxW != null ||
        flatMinH != null ||
        flatMaxH != null) {
      final base = boxConstraints ?? const BoxConstraints();
      boxConstraints = base.copyWith(
        minWidth: flatMinW,
        maxWidth: flatMaxW,
        minHeight: flatMinH,
        maxHeight: flatMaxH,
      );
    }

    // Build container
    Widget container = Container(
      padding: padding,
      margin: margin,
      width: width,
      height: height,
      constraints: boxConstraints,
      decoration: decoration,
      alignment: parseAlignment(properties[core.PropertyKeys.alignment]),
      child: child,
    );

    if (backdropSigma != null) {
      container = BoxDecorationResolver.wrapWithBackdrop(
        container,
        sigma: backdropSigma,
        radius: decoration?.borderRadius is BorderRadius
            ? decoration!.borderRadius as BorderRadius
            : null,
      );
    }

    return applyCommonWrappers(container, properties, context);
  }

  EdgeInsets? _resolveEdgeInsets(dynamic value, RenderContext context) {
    if (value == null) return null;

    // Top-level responsive override (e.g. `padding: {compact: 8,
    // expanded: 24}`) — opt in to the per-form-factor picker before we
    // inspect the value as a structural EdgeInsets shape. The picker
    // returns null for non-responsive Maps so the existing path runs.
    if (value is Map) {
      final picked = context.pickResponsive(value);
      if (picked != null) {
        value = picked;
      }
    }
    if (value == null) return null;

    if (value is Map<String, dynamic>) {
      // Resolve all values in the map; also expand `{token: 'md'}` form.
      final resolved = <String, dynamic>{};
      value.forEach((key, val) {
        resolved[key] = context.resolve(val);
      });
      if (resolved['token'] is String) {
        final tokenValue =
            parseSpacingToken(resolved['token'] as String, context);
        if (tokenValue != null) {
          return EdgeInsets.all(tokenValue);
        }
      }
      return parseEdgeInsets(resolved);
    }

    // For simple values, resolve and parse.
    final resolved = context.resolve(value);
    // String M3 spacing token shorthand: `padding: "md"` → resolves
    // through `theme.spacing.md` to a uniform inset.
    if (resolved is String) {
      final tokenValue = parseSpacingToken(resolved, context);
      if (tokenValue != null) {
        return EdgeInsets.all(tokenValue);
      }
    }
    return parseEdgeInsets(resolved);
  }
}
