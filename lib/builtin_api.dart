/// Public API surface for vibe_studio **builtins** (App Builder ·
/// Scene Builder · Ops) and any future bundle-apps.
///
/// ## Layering
///
/// Host = vibe_studio (OS-layer · may use `brain_kernel` / `mcp_host` /
/// `mcp_server` directly).
/// Builtins + bundle-apps = apps on top of the OS-layer. They import only
/// the wrappers in this file.
///
/// Builtin / bundle-app code MUST NOT import the following directly:
///   - `package:brain_kernel/*`        (kernel)
///   - `package:brain_kernel/mcp_host.dart`
///   - `package:mcp_server/*`          (transport)
///
/// Framing — "as if a Windows app calls OS APIs": a builtin calls the
/// host's tools (`studio.*` · `bk.*`) or registers via a manifest
/// `tools[]` declaration. It does not stand up its own MCP server
/// instance.
///
/// This layer is the source of truth = the same path a user's bundle-app
/// would take → bundle-apps work as-is.
///
/// ## Surface exposed by this wrapper
///
/// | Area | symbol | Builtin usage pattern |
/// |---|---|---|
/// | Canonical model | `Canonical` · `CanonicalChange` · `CanonicalStoragePort` · `ManifestOnlyCanonicalStorage` | DSL workspace read/write |
/// | Originator (change reason) | `CliOriginator` · `ImportOriginator` · `LlmOriginator` · `McpClientOriginator` · `UserOriginator` | specify origin when pushing a canonical change |
/// | Bundle activation | `BundleActivation` | read-only view (activate/deactivate itself is the host's responsibility) |
/// | Tool response model | `KernelContent` · `KernelTextContent` · `KernelToolResult` | return type when a builtin writes its own tool handler. **but the manifest `tools[]` declaration path is recommended** |
/// | LLM adapter | `LlmPortAdapter` | when per-agent LLM dispatch is needed (usually handled by the host) |
///
/// ## Not exposed (zero builtin usage after cleanup)
///
/// - `KernelServerHost` — builtins do not stand up their own server.
/// - `ServerBootstrap` — no direct use of the mcp_host transport.
/// - all `mcp_server.*` symbols — no dependency on an own server.
///
/// When a builtin needs to register a tool:
///   1. **Recommended** — declare it in the manifest `tools[]` with
///      `kind: 'js'` / `'wasm'` / `'mcp'`. The host activation path
///      registers it automatically.
///   2. **Second choice** — call the host's `studio.*` tools directly
///      (e.g. `vibe_studio/base.dart`'s `ChromeBridge.dispatchBundleTool`).
///   3. **Host facade** — the builtin calls a host facade through a
///      chrome bridge slot. The host side exposes it as a tool.
library;

// ── Canonical model ──────────────────────────────────────────────
//
// DSL workspace read/write model. Used most heavily by App Builder
// (page tree · manifest · settings · agents · tools).
export 'package:brain_kernel/brain_kernel.dart'
    show
        Canonical,
        CanonicalChange,
        CanonicalStoragePort,
        ManifestOnlyCanonicalStorage;

// ── Originator (change reason) ───────────────────────────────────
//
// One of the 5 origins when calling `Canonical.apply(change, originator: ...)`.
// Builtin code is required to specify the origin of its own changes.
export 'package:brain_kernel/brain_kernel.dart'
    show
        CliOriginator,
        ImportOriginator,
        LlmOriginator,
        McpClientOriginator,
        UserOriginator;

// ── Bundle activation (read-only view) ───────────────────────────
//
// Used only when a builtin reads its own activation info (exposed
// namespace · bundleId · tools, etc.). activate/deactivate itself is
// the host's responsibility.
export 'package:brain_kernel/brain_kernel.dart' show BundleActivation;

// ── Tool response model ──────────────────────────────────────────
//
// Return type when a builtin writes its own tool handler (e.g. the dart
// facade of a manifest `tools[kind:'dart']`). Use this instead of
// mcp_server's `CallToolResult` — the host activation path aligns
// automatically.
export 'package:brain_kernel/brain_kernel.dart'
    show KernelContent, KernelImageContent, KernelTextContent, KernelToolResult;

// ── Resource response model ──────────────────────────────────────
//
// Return type when a builtin writes a resource handler (e.g. markdown
// docs like `makemind-ops://guide`). The handler return of
// `BuiltinToolRegistry.addResource`.
export 'package:brain_kernel/brain_kernel.dart'
    show KernelResourceContent, KernelReadResourceResult;

// ── LLM adapter ──────────────────────────────────────────────────
//
// When per-agent LLM dispatch is needed inside a builtin (rare · usually
// handled by the host via `chromeBridge.activeChatAgentId`). The
// manifest's agents are the seed source-of-truth path.
export 'package:brain_kernel/brain_kernel.dart' show LlmPortAdapter;

// Canonical file-based KvStoragePort (kernel-provided, host-adoptable) —
// built-ins use this instead of their own file KV. workspace scope via the
// optional `workspaceId`.
export 'package:brain_kernel/brain_kernel.dart' show KvStoragePortAdapter;

// ── Canonical patch + validation type model ──────────────────────
//
// The single canonical authoring model. Built-ins (App Builder) edit the
// canonical through these instead of forking a parallel flat type set:
//   * PatchOp / PatchOriginator (+ the sealed originator subtypes) — the
//     RFC 6902 op + audit-tagged provenance (UserOriginator(note:) carries
//     the free-form authoring tag the old flat `kind` string held).
//   * PatchApplied / PatchRejected — the sealed outcome of a patch apply.
//   * ValidationIssue / ValidationSeverity / ValidationLayer — spec
//     validation findings.
//   * CanonicalChange / CanonicalChangeKind — mutation notifications.
export 'package:brain_kernel/brain_kernel.dart'
    show
        PatchOp,
        PatchOriginator,
        UserOriginator,
        LlmOriginator,
        McpClientOriginator,
        CliOriginator,
        ImportOriginator,
        PatchResult,
        PatchApplied,
        PatchRejected,
        ValidationIssue,
        ValidationSeverity,
        ValidationLayer,
        CanonicalChange,
        CanonicalChangeKind;

// ── Prompt surface (framework r8 — 2026-05-28) ───────────────────
//
// Used when a builtin registers MCP prompts via
// `BuiltinToolRegistry.addPrompt(...)`. Direct dependency on
// `mcp.GetPromptResult` / `mcp.Message` / `mcp.PromptArgument` is
// deprecated (anti-pattern) — use only this wrapper.
export 'package:brain_kernel/brain_kernel.dart'
    show
        KernelPromptArgument,
        KernelPromptMessage,
        KernelGetPromptResult,
        KernelPromptHandler,
        KernelPromptDef;

// ── Knowledge & Agent symbol surface (extended 2026-05-29) ───────
//
// Lets a builtin (Ops · user bundle-apps) access `flowbrain_core` types
// via a one-line wrapper without importing them directly. A direct
// `package:flowbrain_core` import is an anti-pattern (builtin-os-cleanup
// model — host = OS · builtin = app). flowbrain_core is the framework's
// operational logic layer; builtins use only this wrapper.
//
// **Full re-export** — facade-operator builtins like Ops use the deep
// KnowledgeSystem · runtime · facade surface. Narrowing with a show list
// would force incremental extension and cause cascades on framework
// changes. The wrapper is merely an aligned import path; restricting the
// surface is not part of the model.
//
// A user bundle-app depending directly on the deep framework surface is
// not recommended (the manifest declarative path is the source of
// truth). This export is the aligned import path for the builtin area.
export 'package:flowbrain_core/flowbrain_core.dart';
