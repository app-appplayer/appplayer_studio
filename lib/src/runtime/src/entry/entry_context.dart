/// Entry and identity value types (MCP UI DSL §8.9).
///
/// The types themselves live in `flutter_mcp_ui_core` alongside the other
/// spec value types, so authoring tools, validators and non-runtime consumers
/// can name them without depending on the Flutter runtime. This library
/// re-exports them for the runtime's own imports and for hosts that only
/// depend on the runtime.
///
/// The behaviour that goes with them stays here: `EntrySession` (needs the
/// state manager), the dedicated binding resolution, the read-only guard, and
/// the launch route — none of which mean anything without a running document.
library entry_context;

export 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart'
    show
        EntryContext,
        EntryIssuer,
        EntryNotice,
        IdentityContext,
        IdentityPromotion,
        PromotionOutcome,
        IdentityState,
        IdentitySubjectKind;
