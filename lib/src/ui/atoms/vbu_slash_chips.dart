import 'package:flutter/material.dart';

import '../tokens.dart';

/// One entry in a [VbuSlashChips] strip — mirrors the shape vibe_studio
/// chat composer uses for `manifest.chat.slashCommands[]` chips. Inert:
/// the atom only consumes resolved values, no manifest reads.
class VbuSlashChipItem {
  const VbuSlashChipItem({
    required this.command,
    this.description,
    this.directDispatch = false,
    this.onTap,
  });

  /// Slash trigger, e.g. `/agents` / `/wire`.
  final String command;

  /// Optional one-line hint shown on hover. Standard pattern is the
  /// chat-side `description` field from the manifest entry.
  final String? description;

  /// `true` when submitting the chip fires a bound MCP tool directly
  /// (manifest's `tool` field set); `false` when the chip is a
  /// template prefill that just drops [command] (plus optional
  /// template) into the composer. Pure visual hint — the atom doesn't
  /// dispatch anything itself; the host's onTap is responsible.
  final bool directDispatch;

  /// Tap handler. Wired by the host that consumes manifest entries;
  /// preview surfaces (Tools mode builder) typically pass null so the
  /// chip renders inert.
  final VoidCallback? onTap;
}

/// Horizontal chip strip — canonical shape of the chat composer's
/// slash hint row. Feed it [chips] (already resolved from manifest)
/// and it lays them out left-to-right with the same dimensions the
/// chat panel uses. Both vibe_studio chat panel and studio_builder's
/// preview surface render the exact same atom, so the user sees the
/// same shape they would in production.
class VbuSlashChips extends StatelessWidget {
  const VbuSlashChips({super.key, required this.chips, this.spacing = 6});

  final List<VbuSlashChipItem> chips;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Wrap(
      spacing: spacing,
      runSpacing: 4,
      children: <Widget>[
        for (final chip in chips)
          Tooltip(
            message: chip.description ?? chip.command,
            child: InkWell(
              onTap: chip.onTap,
              borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: VbuTokens.space2,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
                  border: Border.all(
                    color: chip.directDispatch ? c.mintDim : c.borderSubtle,
                  ),
                ),
                child: Text(
                  chip.command,
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    color: chip.directDispatch ? c.mint : c.textSecondary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
