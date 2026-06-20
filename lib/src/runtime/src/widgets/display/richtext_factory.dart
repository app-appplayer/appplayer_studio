import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for RichText widgets
class RichTextWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract properties
    final textAlign =
        _parseTextAlign(properties['textAlign']) ?? TextAlign.start;
    final textDirection = _parseTextDirection(properties['textDirection']);
    final softWrap = properties['softWrap'] as bool? ?? true;
    final overflow =
        _parseTextOverflow(properties['overflow']) ?? TextOverflow.clip;
    final textScaler = properties['textScaleFactor'] != null
        ? TextScaler.linear(properties['textScaleFactor'].toDouble())
        : TextScaler.noScaling;
    final maxLines = properties['maxLines'] as int?;

    // Build text spans
    final spans = properties['spans'] as List<dynamic>? ?? [];
    final textSpan = _buildTextSpan(spans, context);

    Widget richText = RichText(
      text: textSpan,
      textAlign: textAlign,
      textDirection: textDirection,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
    );

    return applyCommonWrappers(richText, properties, context);
  }

  TextSpan _buildTextSpan(List<dynamic> spans, RenderContext context) {
    if (spans.isEmpty) {
      return const TextSpan(text: '');
    }

    final children = <InlineSpan>[];

    for (final span in spans) {
      if (span is Map<String, dynamic>) {
        final text = context.resolve<String?>(span['text']);
        final style = _parseTextStyle(span['style'], context);
        final childSpans = span['children'] as List<dynamic>?;

        if (childSpans != null && childSpans.isNotEmpty) {
          children.add(TextSpan(
            text: text,
            style: style,
            children: childSpans
                .map((child) =>
                    _buildInlineSpan(child as Map<String, dynamic>, context))
                .toList(),
          ));
        } else {
          children.add(TextSpan(
            text: text,
            style: style,
          ));
        }
      }
    }

    return TextSpan(children: children);
  }

  InlineSpan _buildInlineSpan(
      Map<String, dynamic> span, RenderContext context) {
    final text = context.resolve<String?>(span['text']);
    final style = _parseTextStyle(span['style'], context);

    return TextSpan(
      text: text,
      style: style,
    );
  }

  TextStyle? _parseTextStyle(dynamic style, RenderContext context) {
    if (style == null) return null;

    if (style is Map<String, dynamic>) {
      return TextStyle(
        color: parseColor(context.resolve(style['color']), context),
        backgroundColor: parseColor(context.resolve(style['backgroundColor']), context),
        fontSize: style['fontSize']?.toDouble(),
        fontWeight: _parseFontWeight(style['fontWeight']),
        fontStyle: style['italic'] == true ? FontStyle.italic : null,
        letterSpacing: style['letterSpacing']?.toDouble(),
        wordSpacing: style['wordSpacing']?.toDouble(),
        height: style['height']?.toDouble(),
        decoration: _parseTextDecoration(style['decoration']),
        decorationColor: parseColor(context.resolve(style['decorationColor']), context),
        decorationStyle: _parseTextDecorationStyle(style['decorationStyle']),
      );
    }

    return null;
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

  FontWeight? _parseFontWeight(String? value) {
    switch (value) {
      case 'bold':
        return FontWeight.bold;
      case 'normal':
        return FontWeight.normal;
      case 'w100':
        return FontWeight.w100;
      case 'w200':
        return FontWeight.w200;
      case 'w300':
        return FontWeight.w300;
      case 'w400':
        return FontWeight.w400;
      case 'w500':
        return FontWeight.w500;
      case 'w600':
        return FontWeight.w600;
      case 'w700':
        return FontWeight.w700;
      case 'w800':
        return FontWeight.w800;
      case 'w900':
        return FontWeight.w900;
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
}
