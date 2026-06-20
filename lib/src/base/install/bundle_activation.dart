/// Activation contract — the host hands one of these to a domain
/// bundle when its tab opens. The domain's activation routine calls
/// `registerTool` / `registerAgent` / `mountUi` to wire itself into
/// the host's chrome, and the context's `unregisterAll` undoes
/// everything when the tab closes.
///
/// **Phase 1 of `vibe-studio-activation-plan`** — abstract surface
/// only. Phase 2 implements `registerTool` (external MCP path),
/// Phase 3 implements `mountUi`, Phase 4 implements `registerAgent`,
/// Phase 5 adds the in-process JS path.
///
/// **Step 3 of bundle-fork absorption** — the canonical bundle types
/// (`McpBundle` / `ToolEntry` / `AgentDefinition`) come from
/// `package:mcp_bundle`. The host no longer carries fork classes
/// (memory `feedback_bundle_no_fork_extend`).
///
/// The host owns the lifetime — domains must NOT cache the context
/// across activations. Calling any register* method on a context
/// whose `unregisterAll()` has already fired is a no-op (logged for
/// debugging via `studio.debug.*`).
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import 'bundle_loading.dart';

/// Outcome of one register* call. Carries the post-prefix name so
/// the domain can map its declared `query` to the actual
/// `demo_showcase.query` the host advertised.
class RegistrationResult {
  const RegistrationResult({
    required this.ok,
    required this.exposedName,
    this.error,
  });

  final bool ok;

  /// What the host actually registered under (with `<shortId>[_N].`
  /// prefix and any collision suffix applied). Empty when [ok] is
  /// false.
  final String exposedName;

  /// Failure reason — null on success.
  final String? error;
}

/// Context handed to a domain bundle during activation. Each
/// activated tab gets its own context; closing the tab calls
/// [unregisterAll] which removes every tool / agent / UI mount the
/// domain registered through this instance.
abstract class BundleActivationContext {
  /// The bundle being activated — canonical [mb.McpBundle] read by
  /// [readBundleAt] at activation time. The host doesn't mutate it.
  /// Use the [BundleHostAccessors] extension for `shortId`,
  /// `displayLabel`, `resolveAsset`, `resolveJsEntry`, `uiEntry`.
  mb.McpBundle get bundle;

  /// Tab key the activation is bound to (the package's mbdPath, or a
  /// `_N` collision-suffixed variant when the same package is open
  /// in multiple tabs). Use this when scoping persistent state to
  /// the activation instance rather than the bundle on disk.
  String get tabKey;

  /// Register a tool the bundle declared. Host applies the
  /// `<shortId>[_N].<name>` prefix and adds the result to its MCP
  /// server. Returns [RegistrationResult.exposedName] so the domain
  /// knows the post-prefix name (matters when the same shortId
  /// collides with another active tab).
  ///
  /// Phase 2 implements `kind: 'mcp'` (external server). Phase 5
  /// adds `kind: 'js'` (in-process flutter_js).
  Future<RegistrationResult> registerTool(mb.ToolEntry tool);

  /// Register an agent the bundle declared. Host wraps it as a
  /// `VibeAgentProfile` and adds it to the agent stack. Manager
  /// agents become dispatch targets the host's manager can hand off
  /// to. Returns the actual agent id used (collision rules mirror
  /// tool prefix — first plain, second `_2`).
  ///
  /// Phase 4 implementation; Phase 1 stub returns `ok:false`.
  Future<RegistrationResult> registerAgent(mb.AgentDefinition agent);

  /// Register a skill module from `bundle.skills.modules`. Host
  /// delegates to `system.skill.register` so the skill becomes
  /// callable via `SkillFacade.execute(skillId, inputs)` and the
  /// `studio.skill.*` tool surface.
  Future<RegistrationResult> registerSkill(mb.SkillModule skill);

  /// Register a profile from `bundle.profiles.profiles`. Host
  /// delegates to `system.profile.register` so the profile is
  /// resolvable by id (e.g. for `AgentFacade.assignProfileFromPool`).
  Future<RegistrationResult> registerProfile(mb.ProfileDefinition profile);

  /// Register a philosophy / ethos from `bundle.philosophy.philosophies`.
  /// Host delegates to `system.philosophy.register` so prohibition
  /// checks + ethos resolution use this entry.
  Future<RegistrationResult> registerPhilosophy(mb.Philosophy philosophy);

  /// Register a fact from `bundle.factGraph.embedded.facts` (or
  /// `bundle.facts.facts`). Host delegates to `system.facts.writeFacts`
  /// so the fact is queryable via `FactFacade.queryFacts` and the
  /// `studio.fact.*` tool surface.
  Future<RegistrationResult> registerFact(mb.Fact fact);

  /// Register a flow (workflow / pipeline / runbook) from
  /// `bundle.flow.flows`. Host delegates to `system.ops.*`. The flow
  /// type (workflow vs pipeline vs runbook) is discriminated by the
  /// `FlowDefinition` shape — host inspects `trigger` / `steps` to
  /// pick the appropriate `OpsFacade.register*` path.
  Future<RegistrationResult> registerFlow(mb.FlowDefinition flow);

  /// Mount the bundle's UI into the workspace centre. Builder
  /// receives the activation context so it can react to other
  /// register* calls (e.g. surface a tool's result in the UI).
  ///
  /// Phase 3 implementation; Phase 1 stub is a no-op.
  Future<RegistrationResult> mountUi(UiEntryRef entry);

  /// Tear down everything this context registered. Host calls this
  /// when the tab closes or the bundle is uninstalled. Idempotent —
  /// subsequent calls are no-ops.
  Future<void> unregisterAll();

  /// True after [unregisterAll] has fired. Domains can check this in
  /// async code to skip work that would otherwise leak.
  bool get isClosed;
}
