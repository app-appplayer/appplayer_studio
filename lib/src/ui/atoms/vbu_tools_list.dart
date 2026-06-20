import 'package:flutter/material.dart';

import '../tokens.dart';

/// One entry in a [VbuToolsList] — mirrors the shape vibe_studio uses
/// for `manifest.tools.tools[]` entries (name + kind + source). Inert:
/// the atom consumes resolved values, doesn't read manifest itself.
class VbuToolItem {
  const VbuToolItem({
    required this.name,
    this.kind = 'host',
    this.description,
    this.subLabel,
    this.selected = false,
    this.onTap,
  });

  /// Canonical bare name — `addTool`, `create_package`, etc.
  final String name;

  /// Runtime carrier — `host` (in-process) · `mcp` (external server) ·
  /// `cloud` (HTTP) · `js` (flutter_js). Drives the trailing pill.
  final String kind;

  /// Optional one-line description shown beneath the name.
  final String? description;

  /// Optional secondary label — typically the resolved endpoint
  /// (`mcp · http://...` / `cloud · https://...`) or `in-process ·
  /// builtin`. Lets the user see "where is this verb coming from"
  /// at a glance.
  final String? subLabel;

  /// Highlights the row (mint underline / surface3 background).
  final bool selected;

  /// Tap handler — typically opens the tool detail editor.
  final VoidCallback? onTap;
}

/// Vertical list of tool rows — canonical shape of the Studio Builder
/// Tools tab's left list. Each row is a leading wrench chip + name +
/// optional sub-label + kind pill. Inert atom: the host supplies an
/// already-resolved [tools] list, so the same widget renders the same
/// shape in chrome and in studio_builder's preview surface.
class VbuToolsList extends StatelessWidget {
  const VbuToolsList({super.key, required this.tools});

  final List<VbuToolItem> tools;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final t in tools)
          InkWell(
            onTap: t.onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: VbuTokens.space3,
                vertical: 6,
              ),
              color: t.selected ? c.surface3 : Colors.transparent,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.surface2,
                      borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
                      border: Border.all(color: c.borderSubtle),
                    ),
                    child: Icon(
                      Icons.build_outlined,
                      size: 16,
                      color: t.selected ? c.mint : c.textSecondary,
                    ),
                  ),
                  const SizedBox(width: VbuTokens.space2),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: VbuTokens.fontMono,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: t.selected ? c.textPrimary : c.textSecondary,
                          ),
                        ),
                        if (t.subLabel != null && t.subLabel!.isNotEmpty)
                          Text(
                            t.subLabel!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: VbuTokens.fontMono,
                              fontSize: 10,
                              color: c.textTertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: VbuTokens.space1),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface2,
                      borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
                      border: Border.all(color: c.borderSubtle),
                    ),
                    child: Text(
                      t.kind,
                      style: TextStyle(
                        fontFamily: VbuTokens.fontMono,
                        fontSize: 9,
                        color: c.mintDim,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
