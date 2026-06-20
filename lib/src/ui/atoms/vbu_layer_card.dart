import 'package:flutter/material.dart';

import '../tokens.dart';
import 'vbu_mini_preview.dart';

/// Single layer card for the Overview Strip — 168×80 with a 3px left
/// stripe (layer color), labelSmall number ("01"), bodyMedium name
/// ("App"), and a VbuMiniPreview sketch.
///
/// State machine (catalog Part D):
///   normal   — surface2 bg · borderDefault 1px
///   focused  — surface3 bg · layer-color 1.5px border · textPrimary
///              label · scale 1.02 (160ms easeStandard)
///   hover    — borderStrong 1.5px · cursor click
///
/// Optional `patchCount` shows a mint pill (top-right) when > 0.
class VbuLayerCard extends StatelessWidget {
  const VbuLayerCard({
    super.key,
    required this.number,
    required this.name,
    required this.layerId,
    required this.color,
    this.focused = false,
    this.patchCount,
    this.onTap,
    this.width = 168,
    this.height = 80,
  });

  final String number;
  final String name;
  final String layerId;
  final Color color;
  final bool focused;
  final int? patchCount;
  final VoidCallback? onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return MouseRegion(
      cursor:
          onTap != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: VbuTokens.durFast,
          curve: VbuTokens.easeStandard,
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: focused ? c.surface3 : c.surface2,
            borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
            border: Border.all(
              color: focused ? color : c.borderDefault,
              width: focused ? 1.5 : 1,
            ),
          ),
          child: Stack(
            children: <Widget>[
              // Left stripe
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Container(width: 3, color: color),
              ),
              // Content
              Padding(
                padding: const EdgeInsets.fromLTRB(11, 8, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          number,
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(
                            color: focused ? c.textPrimary : c.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          name,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
                            color: focused ? c.textPrimary : c.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: VbuMiniPreview(
                          layer: layerId,
                          size: Size(width - 22, height - 36),
                          color: color,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Patch badge
              if (patchCount != null && patchCount! > 0)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: c.mint,
                      borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
                    ),
                    child: Text(
                      patchCount.toString(),
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: c.bg,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
