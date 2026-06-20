/// `LayerId` + `CanonicalPatch` — vibe_app_builder's projection model
/// of editing layers (theme · components · dashboard · navigation ·
/// pages · assets · whole · appStructure) plus the patch envelope that
/// ties a list of [PatchOp]s to one of those layers and a typed
/// originator.
///
/// Lifted into vibe_studio_base so future builder studios can reuse
/// the same projection / patch envelope without re-defining their
/// own. A non-mcp_ui builder can simply ignore the layer values it
/// doesn't use; the enum names are descriptive but the values are
/// open-ended (any builder can use a subset).
library;

import 'package:meta/meta.dart';
import 'package:brain_kernel/brain_kernel.dart' show PatchOp, PatchOriginator;

/// Identifies one of the editing layers projected over the canonical
/// bundle. Covers the mcp_ui surface (appStructure / theme / components /
/// dashboard / navigation / pages / assets) and the bundle-mode surface
/// (knowledge / manifest / tools / agents — the platform's knowledge-
/// category + manifest editing layers). Builders pick the subset that
/// matches their domain; hosts tolerate layers they don't surface.
enum LayerId {
  appStructure,
  theme,
  components,
  dashboard,
  navigation,
  pages,
  assets,
  knowledge,
  manifest,
  tools,
  agents,
  whole,
}

/// A diff to be applied atomically against the canonical bundle.
/// Layer-routed (so a host can shard validators by layer) and
/// originator-tagged (so audit trails can distinguish user / LLM /
/// MCP-client / CLI / import).
@immutable
class CanonicalPatch {
  const CanonicalPatch({
    required this.layer,
    required this.ops,
    required this.originator,
  });

  final LayerId layer;
  final List<PatchOp> ops;
  final PatchOriginator originator;
}
