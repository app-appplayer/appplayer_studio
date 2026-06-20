/// Widget-form overlays — `title_card`, `subtitle`, `step_indicator`,
/// `watermark`. These don't need custom painting (just Container +
/// Text + Image), but live alongside the painters for discoverability.
library;

import 'package:flutter/material.dart';

import 'shared.dart';

class TitleCardOverlay extends StatelessWidget {
  const TitleCardOverlay({
    super.key,
    required this.props,
    required this.fadeOpacity,
  });
  final Map<String, dynamic> props;
  final double fadeOpacity;

  @override
  Widget build(BuildContext context) {
    final title = stringProp(props, 'title', '');
    final subtitle = stringProp(props, 'subtitle', '');
    final bgColor = colorFromProps(
      props,
      'background',
      const Color(0xff0a0a0a),
    );
    final titleColor = colorFromProps(props, 'titleColor', kTextOnDark);
    final subtitleColor = colorFromProps(
      props,
      'subtitleColor',
      const Color(0xffb0b0b0),
    );
    return IgnorePointer(
      child: Opacity(
        opacity: fadeOpacity,
        child: Container(
          color: bgColor,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (title.isNotEmpty)
                Text(
                  title,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 48,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
              if (subtitle.isNotEmpty) const SizedBox(height: 12),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: TextStyle(
                    color: subtitleColor,
                    fontSize: 22,
                    fontWeight: FontWeight.w400,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SubtitleOverlay extends StatelessWidget {
  const SubtitleOverlay({
    super.key,
    required this.props,
    required this.fadeOpacity,
  });
  final Map<String, dynamic> props;
  final double fadeOpacity;

  @override
  Widget build(BuildContext context) {
    final text = stringProp(props, 'text', '');
    final position = stringProp(props, 'position', 'bottom');
    final bg = colorFromProps(props, 'background', kBgScrim);
    final textColor = colorFromProps(props, 'color', kTextOnDark);
    final fontSize = doubleProp(props, 'fontSize', 18);
    Alignment alignment;
    switch (position) {
      case 'top':
        alignment = Alignment.topCenter;
        break;
      case 'center':
        alignment = Alignment.center;
        break;
      case 'bottom':
      default:
        alignment = Alignment.bottomCenter;
    }
    return IgnorePointer(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Opacity(
            opacity: fadeOpacity,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  text,
                  style: TextStyle(
                    color: textColor,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class StepIndicatorOverlay extends StatelessWidget {
  const StepIndicatorOverlay({
    super.key,
    required this.props,
    required this.fadeOpacity,
  });
  final Map<String, dynamic> props;
  final double fadeOpacity;

  @override
  Widget build(BuildContext context) {
    final current = intProp(props, 'current', 1);
    final total = intProp(props, 'total', 1);
    final color = colorFromProps(props, 'color', kAccentMint);
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Opacity(
            opacity: fadeOpacity,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: kBgScrim,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: color, width: 1),
              ),
              child: Text(
                '$current / $total',
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class WatermarkOverlay extends StatelessWidget {
  const WatermarkOverlay({
    super.key,
    required this.props,
    required this.fadeOpacity,
  });
  final Map<String, dynamic> props;
  final double fadeOpacity;

  @override
  Widget build(BuildContext context) {
    final text = stringProp(props, 'text', '');
    final asset = stringProp(props, 'asset', '');
    final corner = stringProp(props, 'corner', 'bottom-right');
    final opacity = doubleProp(props, 'opacity', 0.6);
    Alignment align;
    switch (corner) {
      case 'top-left':
        align = Alignment.topLeft;
        break;
      case 'top-right':
        align = Alignment.topRight;
        break;
      case 'bottom-left':
        align = Alignment.bottomLeft;
        break;
      case 'bottom-right':
      default:
        align = Alignment.bottomRight;
    }
    Widget content;
    if (asset.isNotEmpty) {
      content = Image.asset(asset, height: 32);
    } else {
      content = Text(
        text,
        style: const TextStyle(
          color: kTextOnDark,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      );
    }
    return IgnorePointer(
      child: Align(
        alignment: align,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Opacity(opacity: opacity * fadeOpacity, child: content),
        ),
      ),
    );
  }
}
