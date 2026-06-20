import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart' show inspectTag;

import '../theme/tokens.dart';
import '../core/layer_projection.dart';
import '../core/types.dart';

/// Per `handoff/widgets/overview_strip.md` — always-visible map of the six
/// layers. Six 168×80 cards with a layer-color left stripe, layer name,
/// patch badge, and a mini visual signature.
class OverviewStrip extends StatefulWidget {
  const OverviewStrip({
    super.key,
    required this.projection,
    required this.focused,
    required this.onFocus,
    required this.layers,
    this.patchCounts = const <LayerId, int>{},
  });

  final LayerProjection projection;
  final LayerId focused;
  final ValueChanged<LayerId> onFocus;
  final Map<LayerId, int> patchCounts;

  /// Cards to render — set by the parent based on the active
  /// `CenterMode`. UI mode passes 8 layers, Bundle mode passes 4.
  /// Debug mode does not render this strip at all.
  final List<LayerId> layers;

  @override
  State<OverviewStrip> createState() => _OverviewStripState();
}

class _OverviewStripState extends State<OverviewStrip> {
  LayerId? _hovered;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      height: VibeTokens.stripHeight,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(
          top: BorderSide(color: c.borderSubtle),
          bottom: BorderSide(color: c.borderDefault),
        ),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space3,
        vertical: VibeTokens.space2,
      ),
      child: SingleChildScrollView(
        key: const Key('vibe.overview.strip'),
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            for (var i = 0; i < widget.layers.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  right:
                      i == widget.layers.length - 1
                          ? 0
                          : VibeTokens.stripCardGap,
                ),
                child: _Card(
                  index: i + 1,
                  layer: widget.layers[i],
                  projection: widget.projection,
                  focused: widget.focused == widget.layers[i],
                  hovered: _hovered == widget.layers[i],
                  patches: widget.patchCounts[widget.layers[i]] ?? 0,
                  onTap: () => widget.onFocus(widget.layers[i]),
                  onHover:
                      (h) => setState(() {
                        _hovered = h ? widget.layers[i] : null;
                      }),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.index,
    required this.layer,
    required this.projection,
    required this.focused,
    required this.hovered,
    required this.patches,
    required this.onTap,
    required this.onHover,
  });

  final int index;
  final LayerId layer;
  final LayerProjection projection;
  final bool focused;
  final bool hovered;
  final int patches;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  static String _name(LayerId id) {
    switch (id) {
      case LayerId.appStructure:
        return 'App';
      case LayerId.theme:
        return 'Theme';
      case LayerId.components:
        return 'Template';
      case LayerId.dashboard:
        return 'Dashboard';
      case LayerId.navigation:
        return 'Navigation';
      case LayerId.pages:
        return 'Page';
      case LayerId.assets:
        return 'Assets';
      case LayerId.knowledge:
        return 'Knowledge';
      case LayerId.manifest:
        return 'Manifest';
      case LayerId.tools:
        return 'Tools';
      case LayerId.agents:
        return 'Agents';
      case LayerId.whole:
        return 'Whole';
    }
  }

  Color _layerColor() {
    final l = VibeTokens.layer;
    switch (layer) {
      case LayerId.appStructure:
        return l.app;
      case LayerId.theme:
        return l.theme;
      case LayerId.components:
        return l.component;
      case LayerId.dashboard:
        return l.dashboard;
      case LayerId.navigation:
        return l.navigation;
      case LayerId.pages:
        return l.page;
      case LayerId.assets:
        return l.assets;
      case LayerId.knowledge:
        return l.knowledge;
      case LayerId.manifest:
        return l.manifest;
      case LayerId.tools:
        return l.tools;
      case LayerId.agents:
        return l.agents;
      case LayerId.whole:
        return l.whole;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final layerColor = _layerColor();
    final borderColor =
        focused
            ? layerColor
            : hovered
            ? c.borderStrong
            : c.borderDefault;
    final borderWidth = focused ? 1.5 : 1.0;
    final cardBg = focused ? c.surface3 : c.surface2;
    final nameColor = focused ? c.textPrimary : c.textSecondary;

    return inspectTag(
      type: 'overview_card',
      id: layer.name,
      label: _name(layer),
      extra: <String, dynamic>{'index': index, 'focused': focused},
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(true),
        onExit: (_) => onHover(false),
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: VibeTokens.durFast,
            curve: VibeTokens.easeStandard,
            width: VibeTokens.stripCardWidth,
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(VibeTokens.radiusLg),
              border: Border.all(color: borderColor, width: borderWidth),
            ),
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 3, color: layerColor),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    VibeTokens.space2 + 3,
                    VibeTokens.space2,
                    VibeTokens.space2,
                    VibeTokens.space2,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '${index.toString().padLeft(2, '0')} ${_name(layer)}',
                              style: TextStyle(
                                fontFamily: VibeTokens.fontSans,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: nameColor,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (patches > 0) _PatchBadge(count: patches),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Expanded(
                        child: _MiniPreview(
                          layer: layer,
                          projection: projection,
                          color: layerColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PatchBadge extends StatelessWidget {
  const _PatchBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.mint,
        borderRadius: BorderRadius.circular(VibeTokens.radiusFull),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontFamily: VibeTokens.fontMono,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: c.bg,
        ),
      ),
    );
  }
}

class _MiniPreview extends StatelessWidget {
  const _MiniPreview({
    required this.layer,
    required this.projection,
    required this.color,
  });
  final LayerId layer;
  final LayerProjection projection;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _MiniPainter(
        layer: layer,
        color: color,
        palette: VibeTokens.colorOf(context),
      ),
      size: Size.infinite,
    );
  }
}

class _MiniPainter extends CustomPainter {
  _MiniPainter({
    required this.layer,
    required this.color,
    required this.palette,
  });
  final LayerId layer;
  final Color color;
  // Captured at build time by the caller (`_Card.build`) so paint —
  // which Flutter calls without a BuildContext — still resolves
  // brightness-aware tones through the active Theme. Typed `dynamic`
  // to avoid exporting the private `_Colors` class.
  final dynamic palette;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()..color = palette.borderStrong;
    final accent = Paint()..color = color;
    switch (layer) {
      case LayerId.appStructure:
        final rect = Rect.fromLTWH(0, size.height / 2 - 6, 12, 12);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(3)),
          accent,
        );
        for (var i = 0; i < 4; i++) {
          canvas.drawCircle(Offset(20 + i * 10.0, size.height / 2), 2, dim);
        }
        break;
      case LayerId.theme:
        final colors = <Color>[
          palette.mint,
          palette.violet,
          palette.amber,
          palette.blue,
          palette.pink,
        ];
        for (var i = 0; i < colors.length; i++) {
          final paint = Paint()..color = colors[i];
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(i * 12.0, size.height / 2 - 4, 8, 8),
              const Radius.circular(2),
            ),
            paint,
          );
        }
        break;
      case LayerId.components:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, size.height / 2 - 5, 30, 10),
            const Radius.circular(3),
          ),
          accent,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(36, size.height / 2 - 5, 30, 10),
            const Radius.circular(3),
          ),
          dim,
        );
        break;
      case LayerId.dashboard:
        for (var i = 0; i < 3; i++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(i * 20.0, size.height / 2 - 6, 16, 12),
              const Radius.circular(2),
            ),
            dim,
          );
        }
        break;
      case LayerId.navigation:
        // Mini drawer-like sketch: a slim rail on the left with three
        // item dashes — visually distinct from `pages` and `whole`.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, 6, size.height),
            const Radius.circular(2),
          ),
          accent,
        );
        for (var i = 0; i < 3; i++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(12, 2.0 + i * 7, size.width * 0.6, 4),
              const Radius.circular(2),
            ),
            dim,
          );
        }
        break;
      case LayerId.pages:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, size.width, 5),
            const Radius.circular(2),
          ),
          accent,
        );
        for (var i = 0; i < 2; i++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(0, 10.0 + i * 7, size.width * 0.8, 4),
              const Radius.circular(2),
            ),
            dim,
          );
        }
        break;
      case LayerId.assets:
        // Asset-catalog mini sketch — a folder tab + 3 stacked rows
        // suggesting "files inside". Distinct from `pages` (top bar +
        // text rows) and `components` (two side-by-side cards).
        final tab =
            Path()
              ..moveTo(0, 4)
              ..lineTo(0, size.height)
              ..lineTo(size.width, size.height)
              ..lineTo(size.width, 1)
              ..lineTo(size.width * 0.5, 1)
              ..lineTo(size.width * 0.42, 4)
              ..close();
        canvas.drawPath(tab, accent);
        for (var i = 0; i < 3; i++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(4, 8.0 + i * 4, size.width * 0.6, 2),
              const Radius.circular(1),
            ),
            dim,
          );
        }
        break;
      case LayerId.knowledge:
        // Knowledge mini sketch — accented book spine on the left with
        // three dim text lines suggesting indexed content.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, 4, size.height),
            const Radius.circular(1),
          ),
          accent,
        );
        for (var i = 0; i < 3; i++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(10, 2.0 + i * 7, size.width * 0.7, 3),
              const Radius.circular(1),
            ),
            dim,
          );
        }
        break;
      case LayerId.manifest:
        // Manifest mini sketch — accented header band over a small
        // field list suggesting `{id, name, version, ...}`.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, size.width * 0.55, 4),
            const Radius.circular(1),
          ),
          accent,
        );
        for (var i = 0; i < 3; i++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(0, 8.0 + i * 5, size.width * 0.85, 3),
              const Radius.circular(1),
            ),
            dim,
          );
        }
        break;
      case LayerId.tools:
        // Tools mini sketch — three accented chips suggesting MCP
        // verbs `{addX, removeY, listZ}` lined up under a thin rail.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, size.width, 2),
            const Radius.circular(1),
          ),
          dim,
        );
        for (var i = 0; i < 3; i++) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(i * 14.0, 6, 10, 5),
              const Radius.circular(1.5),
            ),
            accent,
          );
        }
        break;
      case LayerId.agents:
        // Agents mini sketch — three stacked accent dots (heads) with
        // dim shoulder rows below suggesting agent profile cards.
        for (var i = 0; i < 3; i++) {
          canvas.drawCircle(Offset(6.0, 6.0 + i * 8), 2, accent);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(12, 4.0 + i * 8, size.width * 0.65, 3),
              const Radius.circular(1),
            ),
            dim,
          );
        }
        break;
      case LayerId.whole:
        for (var r = 0; r < 2; r++) {
          for (var col = 0; col < 3; col++) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromLTWH(col * 18.0, r * 13.0, 14, 9),
                const Radius.circular(2),
              ),
              dim,
            );
          }
        }
        break;
    }
  }

  @override
  bool shouldRepaint(_MiniPainter oldDelegate) =>
      oldDelegate.layer != layer || oldDelegate.color != color;
}
