/// Bundle session module — re-export of brain_kernel's
/// `src/system/bridge/` (extracted 2026-05-25:
/// `bundle-host-bridge-package-extracted-2026-05-25.md`).
///
/// Module was lifted into brain_kernel as the canonical home; this
/// barrel keeps the in-vibe_studio import path (`base/session/session.dart`)
/// alive so the 15+ call sites don't churn — they continue to import
/// the same symbols from the same path, just resolved through
/// brain_kernel now.
library;

export 'package:brain_kernel/brain_kernel.dart'
    show
        BridgeResourceHandler,
        BridgeResourceServerAdapter,
        BridgeServerAdapter,
        BridgeToolDef,
        BridgeToolHandler,
        BundleSessionBridge,
        DispatchContext,
        DispatchSession,
        KbFacade,
        KbFacadeName,
        KbResourceRef,
        SessionHandle,
        SessionRegistry,
        TestSessionHandle;
