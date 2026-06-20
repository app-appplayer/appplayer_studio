import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' as core;

import '../../renderer/render_context.dart';
import '../decoration/box_decoration_resolver.dart';
import '../widget_factory.dart';

/// Factory for Text widgets
class TextWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract and resolve text value.
    // Canonical key is `text` per spec 17_Naming §17.3.2; `content` and `value`
    // are legacy aliases accepted for backward compatibility.
    final textValue = properties[core.PropertyKeys.text] ??
        properties[core.PropertyKeys.content] ??
        properties[core.PropertyKeys.value] ??
        '';
    var value = context.resolve<String>(textValue);

    // Apply text transform
    final textTransform =
        context.resolve<String?>(properties['textTransform']);
    if (textTransform != null) {
      switch (textTransform) {
        case 'uppercase':
          value = value.toUpperCase();
          break;
        case 'lowercase':
          value = value.toLowerCase();
          break;
        case 'capitalize':
          if (value.isNotEmpty) {
            value = value[0].toUpperCase() + value.substring(1);
          }
          break;
      }
    }

    // Resolve `variant` first (M3 typography role) so it can act as the
    // base TextStyle. Inline `style` then layers on top via `merge`.
    final variantValue =
        context.resolve(properties['variant']) as String?;
    final variantStyle = _resolveVariantStyle(variantValue, context);
    final inlineStyle = _parseTextStyle(
        properties[core.PropertyKeys.style], context);
    TextStyle? mergedStyle = variantStyle == null
        ? inlineStyle
        : (inlineStyle == null
            ? variantStyle
            : variantStyle.merge(inlineStyle));

    // Pin an explicit color when the author left it unspecified. Without
    // this `mergedStyle.color == null` falls through to Flutter's
    // ambient `DefaultTextStyle.of(context).color` — which inherits from
    // an ancestor `Theme` whose brightness may briefly diverge from the
    // ThemeManager's effective mode during host tab transitions (an
    // AppRendererScreen remount sees a stale `MediaQuery` /
    // `Theme(brightness:)` frame before the host wrap re-applies its
    // override). Visible in dark mode only — both ambient branches yield
    // near-black under light, so the divergence is invisible there; in
    // dark the same race surfaces as a black-on-dark text frame after
    // tab cycling. Resolving against `theme.color.onSurface` (the M3
    // canonical text colour) breaks the ambient dependency: the colour
    // now follows the ThemeManager's effective mode directly, which is
    // host-override-pinned (see [_resolveEffectiveMode] / [flutterThemeMode]).
    // Spec §5.4.2 deliberately omits a `color` field on typography
    // roles (Material 3 typography / colour separation), so this is a
    // resolved fallback applied at render time — author-supplied
    // `style.color` still wins via `merge` above.
    if (mergedStyle?.color == null) {
      final resolved = context.themeManager.getColorValue('onSurface');
      if (resolved != null) {
        mergedStyle = (mergedStyle ?? const TextStyle())
            .copyWith(color: resolved);
      }
    }

    // Resolve shader-fill: Phase 1.B `style.shader` (Gradient ref).
    // When set we wrap with `ShaderMask` so the gradient covers the
    // glyph bounds at paint time. The base TextStyle's `color` is
    // ignored (white srcIn — the mask provides the colour).
    final inlineStyleMap = _coerceStyleMap(
        properties[core.PropertyKeys.style], context);
    final shaderSpec = inlineStyleMap?['shader'];
    final Gradient? gradient = shaderSpec is Map
        ? BoxDecorationResolver.resolveGradient(shaderSpec, context, this)
        : null;

    // Spec § DropCap — render the first character enlarged with the
    // surrounding text indented for `lines` lines and continuing
    // full-width below. Mutually exclusive with `maxLines`.
    final dropCapSpec = properties['dropCap'];
    if (dropCapSpec is Map) {
      Widget cap = _DropCapText(
        text: value,
        baseStyle: mergedStyle ?? const TextStyle(),
        capStyleMap: dropCapSpec['style'] is Map
            ? Map<String, dynamic>.from(dropCapSpec['style'] as Map)
            : null,
        glyphOverride: dropCapSpec['glyph'] as String?,
        lines: (dropCapSpec['lines'] as num?)?.toInt() ?? 3,
        textAlign: _parseTextAlign(
            context.resolve(properties[core.PropertyKeys.textAlign])),
        capStyleResolver: _parseTextStyle,
        renderContext: context,
      );
      return applyCommonWrappers(cap, properties, context);
    }

    // Build text widget
    Widget text = Text(
      value,
      style: gradient != null
          ? (mergedStyle ?? const TextStyle()).copyWith(color: Colors.white)
          : mergedStyle,
      textAlign: _parseTextAlign(
          context.resolve(properties[core.PropertyKeys.textAlign])),
      textDirection:
          _parseTextDirection(context.resolve(properties['textDirection'])),
      overflow: _parseTextOverflow(context.resolve(properties['overflow'])),
      maxLines: context.resolve(properties[core.PropertyKeys.maxLines]) as int?,
      softWrap: context.resolve(properties['softWrap']) as bool? ?? true,
      textScaler: properties['textScaleFactor'] != null
          ? TextScaler.linear(
              parseDimension(context.resolve(properties['textScaleFactor'])) ?? 1.0)
          : null,
      semanticsLabel:
          context.resolve(properties['semanticsLabel']) as String? ??
              context.resolve(properties['ariaLabel'] ?? properties['aria-label']) as String?,
    );

    if (gradient != null) {
      text = ShaderMask(
        shaderCallback: (bounds) => gradient.createShader(bounds),
        blendMode: BlendMode.srcIn,
        child: text,
      );
    }

    return applyCommonWrappers(text, properties, context);
  }

  /// Coerce the `style` property to a plain `Map` if present, else
  /// null. Shared with [_parseTextStyle]; pulled out so the `shader`
  /// extraction can run before we synthesise a `TextStyle`.
  Map<String, dynamic>? _coerceStyleMap(dynamic style, RenderContext context) {
    if (style == null) return null;
    if (style is String) {
      final resolved = context.resolve<dynamic>(style);
      return resolved is Map ? Map<String, dynamic>.from(resolved) : null;
    }
    return style is Map ? Map<String, dynamic>.from(style) : null;
  }

  /// Resolve an M3 typography role name to its theme-scoped [TextStyle].
  ///
  /// Accepts the canonical M3 names (`displayLarge` … `labelSmall`) and
  /// returns `null` for unknown values so the caller can fall back to
  /// the inline `style` block. Spec §5.4 + 1.3 widget table § 5.1.
  TextStyle? _resolveVariantStyle(String? variant, RenderContext context) {
    if (variant == null || variant.isEmpty) return null;
    return context.themeManager.getTextStyleValue(variant);
  }

  TextStyle? _parseTextStyle(dynamic style, RenderContext context) {
    if (style == null) return null;

    // String form — `style: "{{theme.typography.displayLarge}}"` is a
    // binding expression that resolves to the role's TextStyle map.
    // Run through the binding resolver first; if the result is a map,
    // re-enter the Map branch below.
    if (style is String) {
      final resolved = context.resolve<dynamic>(style);
      if (resolved is Map) {
        style = Map<String, dynamic>.from(resolved);
      } else {
        return null;
      }
    }

    if (style is Map<String, dynamic>) {
      final colorValue = style[core.PropertyKeys.color];
      final resolvedColor = context.resolve(colorValue);
      final parsedColor = parseColor(resolvedColor, context);

      return TextStyle(
        fontSize:
            parseDimension(context.resolve(style[core.PropertyKeys.fontSize])),
        fontWeight: _parseFontWeight(
            context.resolve(style[core.PropertyKeys.fontWeight])),
        fontStyle: _parseFontStyle(context.resolve(style['fontStyle'])),
        color: parsedColor,
        letterSpacing: parseDimension(context.resolve(style['letterSpacing'])),
        wordSpacing: parseDimension(context.resolve(style['wordSpacing'])),
        height: parseDimension(context.resolve(style['height'])),
        decoration: _parseTextDecoration(context.resolve(style['decoration'])),
        decorationColor: parseColor(context.resolve(style['decorationColor']), context),
        decorationStyle: _parseTextDecorationStyle(
            context.resolve(style['decorationStyle'])),
        decorationThickness:
            parseDimension(context.resolve(style['decorationThickness'])),
        fontFamily:
            context.resolve(style[core.PropertyKeys.fontFamily]) as String?,
        fontFeatures: _parseFontFeatures(style['fontFeatures']),
        shadows: _parseShadows(style['shadows'], context),
        backgroundColor: parseColor(
            context.resolve(style['backgroundColor']), context),
      );
    }

    return null;
  }

  FontWeight? _parseFontWeight(dynamic value) {
    if (value == null) return null;

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
        default:
          return null;
      }
    }

    if (value is int) {
      final index = (value ~/ 100) - 1;
      if (index >= 0 && index < FontWeight.values.length) {
        return FontWeight.values[index];
      }
      return null;
    }

    return null;
  }

  FontStyle? _parseFontStyle(String? value) {
    switch (value) {
      case 'italic':
        return FontStyle.italic;
      case 'normal':
        return FontStyle.normal;
      default:
        return null;
    }
  }

  TextAlign? _parseTextAlign(String? value) {
    switch (value) {
      case 'left':
        return TextAlign.left;
      case 'right':
        return TextAlign.right;
      case 'center':
        return TextAlign.center;
      case 'justify':
        return TextAlign.justify;
      case 'start':
        return TextAlign.start;
      case 'end':
        return TextAlign.end;
      default:
        return null;
    }
  }

  TextDirection? _parseTextDirection(String? value) {
    switch (value) {
      case 'ltr':
        return TextDirection.ltr;
      case 'rtl':
        return TextDirection.rtl;
      default:
        return null;
    }
  }

  TextOverflow? _parseTextOverflow(String? value) {
    switch (value) {
      case 'clip':
        return TextOverflow.clip;
      case 'fade':
        return TextOverflow.fade;
      case 'ellipsis':
        return TextOverflow.ellipsis;
      case 'visible':
        return TextOverflow.visible;
      default:
        return null;
    }
  }

  TextDecoration? _parseTextDecoration(String? value) {
    switch (value) {
      case 'none':
        return TextDecoration.none;
      case 'underline':
        return TextDecoration.underline;
      case 'overline':
        return TextDecoration.overline;
      case 'lineThrough':
        return TextDecoration.lineThrough;
      default:
        return null;
    }
  }

  TextDecorationStyle? _parseTextDecorationStyle(String? value) {
    switch (value) {
      case 'solid':
        return TextDecorationStyle.solid;
      case 'double':
        return TextDecorationStyle.double;
      case 'dotted':
        return TextDecorationStyle.dotted;
      case 'dashed':
        return TextDecorationStyle.dashed;
      case 'wavy':
        return TextDecorationStyle.wavy;
      default:
        return null;
    }
  }

  /// Spec [TextStyle.fontFeatures]: array of OpenType feature tags.
  /// Tag form is the standard 4-letter code (`smcp`, `lnum`, `tnum`,
  /// `liga`, `dlig`, …); a `tag=value` form (`zero=1`) is also
  /// accepted to set non-binary feature parameters.
  List<ui.FontFeature>? _parseFontFeatures(dynamic features) {
    if (features is! List) return null;
    final out = <ui.FontFeature>[];
    for (final f in features) {
      if (f is! String || f.isEmpty) continue;
      final eqIdx = f.indexOf('=');
      if (eqIdx == -1) {
        out.add(ui.FontFeature.enable(f));
      } else {
        final tag = f.substring(0, eqIdx);
        final value = int.tryParse(f.substring(eqIdx + 1));
        if (value != null) {
          out.add(ui.FontFeature(tag, value));
        } else {
          out.add(ui.FontFeature.enable(tag));
        }
      }
    }
    return out.isEmpty ? null : out;
  }

  List<Shadow>? _parseShadows(dynamic shadows, RenderContext context) {
    if (shadows == null || shadows is! List) return null;

    return shadows.map((shadow) {
      if (shadow is Map<String, dynamic>) {
        final offset = shadow['offset'] as Map<String, dynamic>?;
        return Shadow(
          color: parseColor(context.resolve(shadow['color']), context) ?? Colors.black,
          offset: offset != null
              ? Offset(
                  parseDimension(context.resolve(offset['x'])) ?? 0,
                  parseDimension(context.resolve(offset['y'])) ?? 0,
                )
              : Offset.zero,
          blurRadius: parseDimension(context.resolve(shadow['blurRadius'])) ?? 0,
        );
      }
      return const Shadow();
    }).toList();
  }
}

/// Drop-cap layout — see `configs/widget/DropCap.yaml`.
///
/// The first character (or `glyph` override) is rendered enlarged in
/// the top-left. The remaining text is laid out twice: once with the
/// cap's column width as left padding for the first `lines` lines,
/// then continuing full-width below the cap. Splitting between the
/// two halves uses `TextPainter` to find the exact character index
/// where the indented portion ends.
class _DropCapText extends StatelessWidget {
  const _DropCapText({
    required this.text,
    required this.baseStyle,
    required this.capStyleMap,
    required this.glyphOverride,
    required this.lines,
    required this.textAlign,
    required this.capStyleResolver,
    required this.renderContext,
  });

  final String text;
  final TextStyle baseStyle;
  final Map<String, dynamic>? capStyleMap;
  final String? glyphOverride;
  final int lines;
  final TextAlign? textAlign;
  final TextStyle? Function(dynamic, RenderContext) capStyleResolver;
  final RenderContext renderContext;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();

    // Pull the cap glyph. `glyphOverride` (e.g. a stylised dingbat)
    // takes precedence; otherwise the first user-perceived character
    // (handles emoji + combining marks via the `characters` package
    // shipped with Flutter).
    final cap =
        glyphOverride != null && glyphOverride!.isNotEmpty
            ? glyphOverride!
            : (text.runes.isEmpty ? '' : String.fromCharCode(text.runes.first));
    final rest = glyphOverride != null && glyphOverride!.isNotEmpty
        ? text
        : text.substring(cap.length);

    // Cap font size = lines × parent fontSize × 0.9 (cap-height
    // factor). Authors can override via `style.fontSize`.
    final parentSize = baseStyle.fontSize ?? 14;
    final defaultCapSize = parentSize * lines * 0.9;
    final overrideStyle =
        capStyleResolver(capStyleMap, renderContext) ?? const TextStyle();
    final capStyle = baseStyle
        .copyWith(
          fontSize: defaultCapSize,
          height: 1.0,
        )
        .merge(overrideStyle);

    final dir = Directionality.maybeOf(context) ?? TextDirection.ltr;

    return LayoutBuilder(builder: (ctx, constraints) {
      // Measure the cap's intrinsic size.
      final capPainter = TextPainter(
        text: TextSpan(text: cap, style: capStyle),
        textDirection: dir,
      )..layout();
      final capWidth = capPainter.width + 8;
      final capHeight = capPainter.height;

      final maxWidth = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : MediaQuery.of(ctx).size.width;
      final indentedWidth = maxWidth - capWidth;

      // Lay out the rest of the text with the cap's indent and the
      // requested `lines` cap to find the breakpoint.
      final restPainter = TextPainter(
        text: TextSpan(text: rest, style: baseStyle),
        textDirection: dir,
        maxLines: lines,
      )..layout(maxWidth: indentedWidth.clamp(0, double.infinity));

      // The character index just past the last laid-out glyph.
      final breakOffset = restPainter
          .getPositionForOffset(
            Offset(restPainter.width, restPainter.height),
          )
          .offset;
      final firstPart = rest.substring(0, breakOffset);
      final secondPart = rest.substring(breakOffset);

      return Stack(
        children: [
          Padding(
            padding: EdgeInsetsDirectional.only(start: capWidth),
            child: Text(
              firstPart,
              style: baseStyle,
              textAlign: textAlign,
              maxLines: lines,
            ),
          ),
          Text(cap, style: capStyle),
          if (secondPart.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: capHeight),
              child: Text(
                secondPart,
                style: baseStyle,
                textAlign: textAlign,
              ),
            ),
        ],
      );
    });
  }
}
