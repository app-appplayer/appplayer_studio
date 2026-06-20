import 'package:flutter/material.dart';

import '../tokens.dart';
import 'vbu_layer_card.dart';

/// One layer entry in the Overview Strip — describes the card and how
/// it maps to the focused-state value.
class VbuOverviewLayer {
  const VbuOverviewLayer({
    required this.id,
    required this.number,
    required this.name,
    required this.color,
    this.patchCount,
  });

  final String id;
  final String number;
  final String name;
  final Color color;
  final int? patchCount;
}

/// 8-layer Overview Strip — horizontal row of [VbuLayerCard] tiles
/// (App · Theme · Component · Dashboard · Navigation · Page · Assets ·
/// Whole). Catalog Part D spec — 96px tall, 168×80 cards, 12px gap,
/// horizontal scroll on overflow, single-source-of-focus state.
///
/// State binding: `focused` selects which card highlights. Card tap
/// fires `onFocus(layerId)` — host updates focused state.
class VbuOverviewStrip extends StatelessWidget {
  const VbuOverviewStrip({
    super.key,
    required this.layers,
    required this.focused,
    this.onFocus,
    this.height = 96,
    this.cardGap = 12,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
  });

  final List<VbuOverviewLayer> layers;
  final String focused;
  final ValueChanged<String>? onFocus;
  final double height;
  final double cardGap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(
          top: BorderSide(color: c.borderSubtle, width: 1),
          bottom: BorderSide(color: c.borderDefault, width: 1),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            for (var i = 0; i < layers.length; i++) ...<Widget>[
              if (i > 0) SizedBox(width: cardGap),
              VbuLayerCard(
                number: layers[i].number,
                name: layers[i].name,
                layerId: layers[i].id,
                color: layers[i].color,
                focused: focused == layers[i].id,
                patchCount: layers[i].patchCount,
                onTap: onFocus == null ? null : () => onFocus!(layers[i].id),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
