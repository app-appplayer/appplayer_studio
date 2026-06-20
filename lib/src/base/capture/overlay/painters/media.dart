/// Floating-image / floating-icon / slide overlays. Plain widgets (no
/// paint loop). Position is absolute when `target.abs` provided, else
/// centred on resolved target rect; falls back to (16,16) when
/// nothing resolves.
///
/// Image source resolution (`floating_image`, `floating_icon`, `slide`):
///   1. `path`  — an absolute file path on disk (`Image.file`). Lets a
///      scenario insert slides/logos exported from Keynote/PPT/Figma
///      without compiling them into the app bundle.
///   2. `asset` — a bundled Flutter asset (`Image.asset`).
/// `path` wins when both are present.
///
/// Entrance motion (`motion` prop, driven by the lifecycle entrance
/// progress 0→1 over `appearMs`): `scale` · `rise` · `drop` ·
/// `slideLeft` · `slideRight` · `none` (default). This is what turns a
/// static logo into an animated one.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import 'shared.dart';

/// Picks the image source from `path` (file) or `asset` (bundled).
/// Returns null when neither is provided.
Widget? imageFromProps(
  Map<String, dynamic> props, {
  required double? width,
  required double? height,
  BoxFit fit = BoxFit.cover,
}) {
  final path = stringProp(props, 'path', '');
  if (path.isNotEmpty) {
    return Image.file(File(path), width: width, height: height, fit: fit);
  }
  final asset = stringProp(props, 'asset', '');
  if (asset.isNotEmpty) {
    return Image.asset(asset, width: width, height: height, fit: fit);
  }
  return null;
}

/// Applies an entrance transform driven by [t] (0→1 over `appearMs`).
Widget applyMotion(Widget child, String motion, double t) {
  if (motion == 'none' || motion.isEmpty) return child;
  final e = Curves.easeOutCubic.transform(t.clamp(0.0, 1.0));
  switch (motion) {
    case 'scale':
      return Transform.scale(scale: 0.6 + 0.4 * e, child: child);
    case 'rise':
      return Transform.translate(offset: Offset(0, 24 * (1 - e)), child: child);
    case 'drop':
      return Transform.translate(
        offset: Offset(0, -24 * (1 - e)),
        child: child,
      );
    case 'slideLeft':
      return Transform.translate(offset: Offset(40 * (1 - e), 0), child: child);
    case 'slideRight':
      return Transform.translate(
        offset: Offset(-40 * (1 - e), 0),
        child: child,
      );
    default:
      return child;
  }
}

class FloatingIconOverlay extends StatelessWidget {
  const FloatingIconOverlay({
    super.key,
    required this.target,
    required this.props,
    this.entrance = 1,
  });
  final Rect? target;
  final Map<String, dynamic> props;
  final double entrance;

  @override
  Widget build(BuildContext context) {
    final iconName = stringProp(props, 'iconName', '');
    final size = doubleProp(props, 'size', 32);
    final color = colorFromProps(props, 'color', kAccentMint);
    final motion = stringProp(props, 'motion', 'none');
    final pos = _resolveTopLeft(target, props, size, size);
    final img = imageFromProps(
      props,
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
    final content =
        img ?? Icon(_iconFromName(iconName), size: size, color: color);
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: applyMotion(content, motion, entrance),
    );
  }
}

class FloatingImageOverlay extends StatelessWidget {
  const FloatingImageOverlay({
    super.key,
    required this.target,
    required this.props,
    this.entrance = 1,
  });
  final Rect? target;
  final Map<String, dynamic> props;
  final double entrance;

  @override
  Widget build(BuildContext context) {
    final w = doubleProp(props, 'width', target?.width ?? 240);
    final h = doubleProp(props, 'height', target?.height ?? 160);
    final radius = doubleProp(props, 'radius', 8);
    final shadow = props['shadow'] == true;
    final motion = stringProp(props, 'motion', 'none');
    final img = imageFromProps(props, width: w, height: h);
    if (img == null) return const SizedBox.shrink();
    final pos = _resolveTopLeft(target, props, w, h);
    final framed = Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow:
            shadow
                ? <BoxShadow>[
                  BoxShadow(
                    color: const Color(0x44000000),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ]
                : const <BoxShadow>[],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(radius), child: img),
    );
    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: applyMotion(framed, motion, entrance),
    );
  }
}

/// Full-frame presentation slide — an image (file or asset) laid over a
/// backdrop with `BoxFit.contain`, optional caption strip. This is how a
/// scenario inserts an actual presentation deck: export each slide to a
/// PNG and push one `slide` overlay per beat.
class SlideOverlay extends StatelessWidget {
  const SlideOverlay({super.key, required this.props, this.entrance = 1});
  final Map<String, dynamic> props;
  final double entrance;

  @override
  Widget build(BuildContext context) {
    final bg = colorFromProps(props, 'background', const Color(0xff0a0a0a));
    final caption = stringProp(props, 'caption', '');
    final captionColor = colorFromProps(props, 'captionColor', kTextOnDark);
    final fitName = stringProp(props, 'fit', 'contain');
    final fit = fitName == 'cover' ? BoxFit.cover : BoxFit.contain;
    final motion = stringProp(props, 'motion', 'none');
    final img = imageFromProps(props, width: null, height: null, fit: fit);
    return Positioned.fill(
      child: ColoredBox(
        color: bg,
        child: applyMotion(
          Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (img != null) Center(child: img),
              if (caption.isNotEmpty)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 36),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      color: kBgScrim,
                      child: Text(
                        caption,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: captionColor,
                          fontSize: doubleProp(props, 'captionSize', 22),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          motion,
          entrance,
        ),
      ),
    );
  }
}

Offset _resolveTopLeft(
  Rect? target,
  Map<String, dynamic> props,
  double width,
  double height,
) {
  if (target != null) {
    return Offset(target.center.dx - width / 2, target.center.dy - height / 2);
  }
  // Fallback corner placement when no target is resolved.
  final corner = stringProp(props, 'corner', 'top-left');
  switch (corner) {
    case 'top-right':
      return Offset(16, 16);
    case 'bottom-left':
      return Offset(16, 16);
    case 'bottom-right':
      return Offset(16, 16);
    case 'top-left':
    default:
      return const Offset(16, 16);
  }
}

IconData _iconFromName(String name) {
  const map = <String, IconData>{
    'lightbulb': Icons.lightbulb_outline,
    'star': Icons.star_outline,
    'flag': Icons.flag_outlined,
    'check_circle': Icons.check_circle_outline,
    'error': Icons.error_outline,
    'warning': Icons.warning_amber_outlined,
    'info': Icons.info_outline,
    'play': Icons.play_arrow_outlined,
    'pause': Icons.pause_outlined,
    'tip': Icons.tips_and_updates_outlined,
  };
  return map[name] ?? Icons.info_outline;
}
