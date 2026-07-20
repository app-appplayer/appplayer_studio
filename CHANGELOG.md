## [0.1.4] - 2026-07-20

### Fixed
- Two connected-server (marketplace or local) tabs could render the SAME served
  app. The workspace keeps every open tab alive in an IndexedStack, but the
  served-app runtime's ThemeManager / WidgetCache / navigatorKey are process
  singletons — two co-mounted served surfaces fought over them and showed each
  other's UI. The served-app body is now active-tab gated (the same
  single-runtime-at-a-time discipline the authoring workspace already uses):
  only the active service tab mounts its runtime; inactive tabs hold a bare
  surface (render future preserved for instant re-entry) and never touch the
  singletons. Locked by a regression test that reproduces two co-mounted tabs
  and asserts the inactive one never even reads its connection.
- A connected-server tab could show a blank / wrong theme after switching to it
  from another server tab (or after a sibling server tab closed). Switching
  tears down the previous tab's runtime, which resets the process-singleton
  ThemeManager; the newly-active tab now re-injects its own theme both
  synchronously and after the frame (so it wins over the sibling's teardown),
  and it also listens on the shared `themeReinjectTick` so a sibling *closing*
  triggers the same re-inject — the exact mechanism the authoring workspace
  already uses. Wired through both the marketplace and local-server surfaces.

### Changed
- Marketplace server connect (Pro tier) cut over to the per-user
  `connectionToken` as the sole Bearer. With the marketplace server retiring
  static-key verification (`SERVER_REQUIRE_TOKEN=true`), the static
  `accessToken` is now dead — never consumed on connect — because a live legacy
  key beside the standard flow would mask whether the standard path works and
  keep a revocation-free credential alive (single-active-path rule). The connect
  path resolves the Bearer from the `connectionToken` only; a missing or
  near-expiry token triggers the silent, screenless re-grant
  (`ServerRef.refresh`), and a grant with neither connects bare so the server
  401s visibly and the next open retries. The dead browser-OAuth wiring
  (loopback authorizer + OAuth token store) was removed rather than left
  flag-gated, and the connect regression locks were flipped to assert the
  static token is never sent (with a resurrection-guard case).
- Marketplace requests (Pro tier) now carry a Firebase App Check attestation
  token (`X-Firebase-AppCheck`) so the marketplace's "our apps only" enforce
  flip does not cut the native app off — App Check is activated at boot (Play
  Integrity / App Attest) and the token provider is wired into the market
  config. Best-effort: on desktop, which has no attestation provider, the
  token is null and requests proceed under the pre-enforce tolerance.

### Added
- Device network provisioning for bundles and agents — a host `provision.*`
  capability that onboards a nearby device onto Wi-Fi so it can serve MCP on
  the LAN (spec 18 sibling of `ble_scan` / `ble_transport` / device discovery).
  Four host-side methods over one "credentials in → terminal join status out"
  contract, from the vendored `ble_provisioning` / `softap_provisioning` /
  `serial_provisioning` / `smartconfig_provisioning` recipes:
  - **BLE** (`provision.candidates` + `provision.commission`) — an on-demand
    scan for devices in provisioning mode, then a GATT credentials write with
    the join awaited over the status NOTIFY. Tolerates the BLE link dropping
    mid-join (device Wi-Fi/BT coexistence): the outcome is re-probed over a
    GATT status READ until terminal, and two consecutive unreachable probes are
    read as the device rebooting into serving mode (`connected`).
  - **SoftAP** (`provision.softap_commission`) — portal HTTP against a device
    in SoftAP mode (the host must already be joined to the device AP).
  - **Serial console** (`provision.serial_ports` + `provision.console`) — the
    node's UART console (`#PROV ` line contract: scan / commission / forget /
    status). The blocking serial I/O runs in a background isolate so it never
    stalls the app or the MCP endpoint, termios is configured on the held-open
    fds (raw / 115200 / `min 0 time 1`), and the command is sent only after a
    boot delay (opening the port resets the board over DTR/RTS).
  - **SmartConfig** (`provision.smartconfig`) — a pure-Dart ESP-Touch v1
    broadcast sender (UDP :7001, ACK :18266); the host must sit on the target
    2.4 GHz band. The tools live on the shared host registry, so a provisioning
    bundle's `type:tool` calls reach them in-process (parity rule). Verified
    end-to-end on a real ESP32: the full onboarding→serving loop (forget →
    BLE candidates → commission → device joins Wi-Fi and reboots → rediscovered
    over mDNS) driven entirely through the Studio tools. Candidate matching
    falls back to the `mcp-prov` advertised name because macOS Core Bluetooth
    does not reliably surface a 128-bit service UUID from a scan advertisement.
- BLE advertisement observation for bundles (`client.mcpStream`, spec 18). The
  vendored `ble_scan` recipe (a sensing capability distinct from a transport or
  device discovery — one physical radio multiplexed across many filtered,
  ref-counted subscriptions) is wired into every render runtime via
  `registerStudioStreamSources`: a bundle's `client.mcpStream` channel with uri
  `ble://scan` (+ serviceUuids/deviceIds/minRssi filters) receives live
  advertisements it can accumulate and bind to lists/charts. The runtime
  namespace-fork was synced to 0.5.2 to gain the `registerStreamSource` seam +
  `mcp_stream_channel`. Radio idles until a channel subscribes; the hub is
  process-shared. Verified end-to-end by an integration test that drives the
  canonical live-monitor bundle through a real runtime over a fake radio
  (initialize, registerStudioStreamSources, `ble://scan` channel, hub,
  advertisement, `onMessage` append to state), plus the vendored recipe tests
  (15). Live dogfood surfaced (and fixed) a missing
  `NSBluetoothAlwaysUsageDescription` in the macOS `Info.plist` — without it the
  BLE scan can't request the CoreBluetooth permission (the same class of gap as
  the discovery `NSBonjourServices` fix); added across the standard/pro trees.
  Real ESP32 render over the hardware radio is a user-present gate — the channel
  runs only in a live app instance (the editing preview is a design canvas).

### Changed
- Ecosystem deps adopted at their published versions (local pre-test path
  overrides removed): `mcp_client` / `mcp_server` **2.1.0** (OAuth 2.1 client
  discovery), `flutter_mcp_ui_runtime` **0.5.2** / `flutter_mcp_ui_core`
  **0.4.2** (the `client.mcpStream` channel type), `mcp_bundle` **0.4.8**. The
  app-builder template seed versions were synced to match (guard test).

### Added
- Discovery manifest trust verification (spec 17 §6). The board-discovery
  wiring gained a Studio-owned `ManifestTrustEvaluator` (over `appplayer_secure`
  — Ed25519 signature over the canonical manifest bytes, validated against the
  facade's root CAs; byte-identical to the recipe's `sign_manifest.dart` signer)
  plus a `TrustEvidence` type. `mcp.discover_boards` now attaches signature
  evidence (`{signed, verified, partnerChainValid}`) to probe-confirmed
  candidates, and — when signature enforcement is on — the auto-connect sweep
  and `connectCandidate` gate on it (fail-closed: an unsigned or unverified
  board is `blocked`, never connected). The host wires the evaluator from a
  bundled root-CA anchor (`assets/root_cas/dev.json` — the dev partner /
  marketplace roots; a production build swaps the asset) and a
  Settings → Auto discovery → "Require signed boards" toggle (default off ⇒
  discovery behaves exactly as before, evidence surfaced either way). The
  anchor loads tier-safe (bare key in the standard package, a
  `packages/appplayer_studio/` prefix fallback in the pro overlay — the
  `_loadSeedAsset` footgun). Verified live in BOTH tiers: the `posix-tcp` dev
  node (which ships a partner-signed trust block) discovers as
  `verified: true` against the wired dev root. Real-crypto
  round-trip + fixture + gate coverage (`discovery_trust_test` 8 ·
  `discovery_trust_fixture_test` 1 · `discovery_trust_gate_test` 5). The vendored
  `device_discovery` / `ble_transport` recipes were re-synced to the canonical
  source (BoardIdentity now carries the raw `manifest`, an mDNS-hostname
  (not point-in-time IP) endpoint, `probeHttpCandidate`, and probe socket
  unhandled-error hardening).
- Standard OAuth 2.1 for marketplace server connect (Pro tier, FEAT-AUTHZ,
  spec 08 §4). The market embed's `connectServer` is now a thin host override
  that resolves the Bearer as static `accessToken` → `connectionToken` →
  standard OAuth (SDK discovery → PKCE → Bearer, refresh persisted to the OS
  keychain), so a token-less grant can authorize through the marketplace AS
  once the static key is retired. `accessToken` stays primary and the connect
  never pins a protocol version (`statelessMode` unset) so the JS-SDK serverapp
  (max 2025-11-25) negotiates instead of 400-ing. New host seams
  `LoopbackAuthorizer` (RFC 8252) + `VaultOAuthTokenStore`; the recipe stays
  unmodified. Coverage `market_oauth_connect_test` (5 — token priority · OAuth
  fallback · non-stateless).
- Work-flow visibility completed (콘피 문의 B묶음 B2·B3·B4 — all renders
  over EXISTING records, no new collection): the Processes route gained a
  List↔Board toggle (B2 flow board — one swimlane per process, columns =
  its steps + Done, run cards sit at their current step with
  waitingApproval ⏳/blocked/completed states, 4s poll since run state has
  no change tick); the Ops Home gained a "Today's flow" card (B4 — the
  morning briefing as a picture: hour-bucketed lanes for invocations /
  delegations / approval waits / run starts on one midnight→now axis); and
  a Form Builder issue's detail now opens with its JOURNEY (B3 — 기안 →
  each approval gate as-signed → 발행 → correction link, rendered purely
  from the provenance frozen into the issue fact). All three live-verified
  eyes-on. New widgets follow the studio design tokens
  (VibeTokens/vibeMono · OpsColors/OpsCard) — the approvals page and
  journey strip were restyled onto them after initially shipping with raw
  Material colorScheme (design-system inheritance is the rule).
  Design: `docs/makemind_ops/ops-flow-views.md`.
- Form Builder gained REAL approval (전자결재 일반화 — the groupware gap
  where expense requests lived as chat text and the owner's decision queue
  was a hand-managed file): a saved draft can open an ORDERED approval
  line (`form_builder.approval_request` — multi-gate, per-gate designated
  approver, 전결 finalize that skips the rest, rejection with a REQUIRED
  reason returning the draft to `draft`; re-submission replaces the
  approval). The gate is OPT-IN and enforced where it matters:
  `form_builder.issue` refuses (`form_builder.approval_required`) until
  the line completes, and the issued fact freezes the line as provenance
  (who signed each gate, when, with what comment). New `Approvals` route
  (결재함 — pending band with approve/전결/reject dialogs, done band with
  line progress ● ○ ✕ ⤵) and a Compose 상신 action; every act notifies
  the next approver / the requester on the in-app channel (host
  `channel.send`, best-effort with a hang guard). `form_approval` facts
  ride the same per-project FactGraph as drafts/issues (restart-safe —
  regression-tested), authorization is the exact designated approver
  (form projects carry no org tree, so ops-style ancestor escalation is
  explicitly out of scope for now). Live-verified end-to-end over MCP:
  request → issue refused → wrong-actor refused → two-gate approve →
  issue 2026-004 with frozen provenance → in-app 승인 대기 push read back
  from the feed. Seed manual grew an `approval_protocol` doc (+4 allowlist
  entries) so the manager drives the same surface honestly. Design:
  `docs/form_builder/form-approval-line.md`.
- The Ops org chart is ALIVE now (관제탑 B1): the Organization page layers
  a real-time overlay over the static chart — per-unit ⏳ pending-approval
  and ▤ today's-output badges on the unit header (a blocked unit's frame
  turns to the warn color), an activity glow ring on member chips that
  invoked within the last two minutes, and DELEGATION ARROWS that light up
  from the delegating seat to the assignee and fade over ninety seconds.
  `agent_route` now persists the previously-discarded routing decision as
  an `agent.routed` fact (from→to·confidence·reason — the delegation trail
  the chart and the future artifact-journey view read). Activity stores
  emit no change tick, so a 4s polling overlay provider (alive only while
  the page is mounted) feeds the painter; chart geometry still rebuilds
  only on registry mutations, preserving pan/zoom. Live-verified: real
  route decision drew the arrow, invocation counts landed as ▤ badges.
  Design: `docs/makemind_ops/ops-living-org-chart.md`.
- Form Builder screen/issued-content parity + image as an issue medium.
  The on-screen sheet (template preview, compose live view, as-issued
  view) now prints form fields exactly as the issued artifacts do —
  `fieldName: value` with the label bold (the engine renderers' semantic)
  — instead of the bare value, so what you see IS what was issued
  (live-verified against the issued PDF). `image` (png) joined the issue
  media (Compose chip + `form_builder.issue` formats); selective issuing
  re-verified end-to-end: exactly the checked media land on disk
  (live: pdf+image → document.pdf + document.png + the always-frozen
  formdoc record, no html/md; widget matrix asserts the default=pdf-only
  and the checked-combination cases plus PNG magic bytes). Known engine
  boundary, ticketed with repro: the v1 image renderer skips table and
  form-field blocks and ignores placement/page box, so a quotation-grade
  document issued as PNG loses its body — the seed manual now warns
  agents not to offer image as the only medium for such documents.
- mcp_form 0.2.0 round-3: placement now holds in the REAL issued artifacts
  (re-verified by rendering, not by markup inspection — the round-2 HTML
  sign-off below was wrong): short documents keep a full page box in HTML
  (`min-height` from the page size), so bottom anchors mean the PAPER
  bottom instead of "right below the last line", and `style.placement` on
  NON-image blocks (e.g. a bottom-centered company line) now leaves the
  flow in both PDF and HTML — live-verified eyes-on via PDF→PNG and
  headless-Chrome renders (stamp at the paper's bottom-right, company text
  at the bottom center; correction reissued as a superseding snapshot).
  The engine also gained a pure-Dart `image`/`png` renderer (no browser or
  platform canvas; the host's injected CJK font applies through the same
  `standardRendererRegistry` seam — a Korean business card renders real
  glyph pixels through `form.render {format:'image'}`), background images,
  an opt-in page border, and `style.pageBreak` for multi-page report
  structure. Headless e2e grew to 9 (placed text overlay, page-box
  min-height, PNG magic bytes).
- mcp_form 0.2.0 round-2 consumption (re-synced vendored `capability_tools`
  recipe): the host now injects its CJK font through the engine's OFFICIAL
  renderer seam — `formCapabilityTools(rendererRegistry:
  standardRendererRegistry(embeddedFont: …, fallbackFonts: […]))` — retiring
  the temporary vendor-fork font extension. This resolves the known gap
  below: issued Korean PDFs embed a Type0 subset (live-verified — no `?`
  glyphs). The engine's new `style.placement` rendering lands in the issued
  artifacts themselves: the seal prints at the page corner in PDF
  (`maxWidth` capped, single page — previously full-width + page spill) and
  as an absolute overlay in HTML. The issued "formdoc" snapshot now
  consumes the new `form.get_document` (typed document WITH patches
  applied) instead of merging template sections with a uiDsl round-trip —
  one call, exact styles and patch-true table rows; image srcs are restored
  to the template's relative paths (the data-URI embed is for the frozen
  pdf/html; the in-app viewer resolves files) and referenced images are
  still copied next to the artifacts. Headless e2e now covers the 14-verb
  surface, get_document patch fidelity, the placement overlay CSS, and the
  CJK font embed. Known fidelity gap (engine-scoped): `style.placement` on
  NON-image blocks (e.g. a bottom-centered company line) renders in the
  in-app form view but stays in flow in issued PDF/HTML — ticketed
  upstream.
- **Form Builder built-in app** — create/manage form templates, fill them
  (insert objects — by hand or an LLM constrained to the template schema),
  and ISSUE documents as immutable snapshots: quotations, official letters,
  resumes, periodic reports. One tab = one form project
  (`project.formproj`); four routes (Templates / Compose / Issues / About).
  - Templates persist per project **through the host `form.*` capability**:
    the registration is rebound onto the bound project's FactGraph
    (`FactBackedFormTemplatePort` from the vendored `capability_tools`
    recipe + a kernel `FormTemplateFactStore` binding — one fact per
    (templateId, version), version history + duplicate rejection preserved,
    hydrated on bind, survives restarts). Unbound state falls back to the
    engine's in-memory port. `registerFormCapability` now delegates to the
    vendored recipe (one canonical form wiring) and explicitly
    unregisters-then-registers each verb (the endpoint does not replace
    duplicate tool names).
  - `form_builder.*` tools (host endpoint — in-app manager and external
    LLMs drive the same surface): `draft_save/draft_get/draft_list`
    (durable working copies as project facts; engine documents are
    session-scoped) and `issue/issue_list/issue_get` — issuing renders the
    requested formats, writes artifacts under `forms/<issueNumber>/`
    (project-relative locators), allocates a per-year issue number
    (`<year>-<NNN>`, derived from persisted issues), and freezes content +
    provenance (template version, issuedBy, issuedAt) as an IMMUTABLE
    `form_issue` fact. Corrections are NEW issues linked via `supersedes`
    — issued records never change.
  - Seed `form_builder.mbd`: `form_builder.manager` (per-project
    coordinator clone, explicit tool allowlist) + a 4-doc authoring/issuing
    manual (storage boundary, template authoring, schema-constrained fill
    flow, issue protocol). The app owns no content data (rosters, ledgers)
    — that stays in the knowledge/execution system (Ops); forms project it.
  - mcp_form 0.2.0 (unpublished) via dependency override; publish pending
    dogfood sign-off. Live-verified end-to-end over MCP: template
    save/list, document create/validate, draft save, issue → real
    PDF + HTML artifacts on disk, supersedes correction, numbering
    001→002→003, and full template/draft/issue survival across an app
    restart.
- Fixed while wiring the above: a draft re-save no longer throws
  `FactConflictException` (the fact facade rejects duplicate ids — replace
  is delete-then-write now), and the capability re-registration no longer
  dies with "Tool ... already exists".
- Hardened by a built-in-contract audit: the `form.*` project rebind moved
  behind `ensureBoot`'s staleness check (a boot losing a rapid-rebind race
  can no longer clobber the newer project's binding — last bind wins),
  `canHandle` also recognises the seed manifest id (Ops parity), and
  `form_builder.draft_delete` completes the tool surface (the Compose UI's
  working-copy cleanup now goes through the same tool an external LLM
  uses — button = tool). The host built-ins catalog seed (`studio.mbd`)
  and the design docs now register the fourth built-in.
- Usage-test round (Korean quotation, correction chain, template versioning,
  manager-driven issuing in Korean): Form Builder pages are now keyed by the
  project root, so a rebind (restore → open another project) recreates page
  state instead of showing the PREVIOUS project's templates/drafts/issues;
  the seed manual now tells agents to always pass `issuedBy` (provenance).
  Known gap, engine-side seam pending: Korean PDF renders as `?` until the
  host can inject an embedded font through the form capability
  (`formCapabilityTools` lacks the renderer/font parameter — ticketed);
  HTML output is fully correct.
- Form Builder templates are real FORMS now, and viewing one means seeing
  the document: the template detail's Preview (and the Issues as-issued
  view) render the engine's `uiDsl` output as the actual sheet — white
  paper, the template's own borders, font effects, label shading,
  line-item tables, and seal-stamp images (`FormDslPreview`, a display-only
  mapper over the engine-computed styles; `uiDsl` now rides along as a
  frozen issue artifact by default). Template EDITING is conversational:
  the manager applies "outline the title / bold-red total / add our stamp"
  style requests via get_template → JSON edit → version bump →
  save_template (taught by a new `conversational_editing` seed doc + a
  full styling/block catalog — borders, text marks, tables, images,
  charts — in `template_authoring`; live-verified: three style directives
  in one Korean sentence landed exactly as v1.0.1 with history intact).
- Form Builder document management round (viewer-first): a template card
  now opens a READABLE detail — rendered preview (placeholder values through
  the real create→render pipeline), fields table, section/block structure —
  with JSON editing demoted to an action; issued snapshots open as the
  AS-ISSUED document (the frozen markdown artifact, now issued alongside
  pdf/html by default, rendered in the Studio viewer kit) with artifact
  chips + open-folder; a "Correct & reissue" action hands the snapshot to
  Compose pre-filled with `supersedes` set. Both lists gained search;
  superseded snapshots dim behind a "current only" toggle; picking a
  template in Compose seeds a data skeleton from its schema.
- A **Studio debugging & UI-verification manual** now ships in the host seed
  knowledge (`studio.mbd` → `studio_debug_manual`, fanned out at boot as
  `studio://knowledge/studio_debug_manual/*`). Six workflow docs — overview /
  bootstrap / inspect / drive / verify_and_diagnose / protocol — tie the
  existing per-tool references (`studio.debug.*` / `studio.renderer.*` /
  `studio.ui.*`) into the end-to-end loop an LLM needs to reproduce a UI bug or
  confirm a fix on screen: open an app + bind a project (so its tools register),
  read the screen (`layout_snapshot` for text, `screenshot` for pixels), drive
  it (`studio.ui.tap`/`type`), assert + visual-regress (`image_diff`), and the
  MCP-over-HTTP parsing traps. Fills the gap where the individual tools were
  documented but the driving/verification workflow was not.
- The Ops Home H1 is now a **workspace selector** — it shows which workspace
  (lens) you're viewing and a dropdown switches to any other, right from Home.
  Previously Home showed a static "Home" title with no indication of the active
  workspace and no way to switch without leaving for the Workspaces pane.
  Switching persists through `KnowledgeInit.switchWorkspace` (durable across
  reboots) and every Home card re-derives against the new lens.
- External channel connectors are now provisionable at runtime. `channel.connect`
  / `channel.disconnect` (from the vendored `channel_drivers` recipe —
  `base/install/channel_drivers/`, io_drivers-homolog, regenerated by
  `debug/tool/sync_channel_drivers_fork.sh`) build a real `mcp_channel` connector
  (slack / telegram / email / kakao; the rest plug in the same way) from
  `{platform, id, params}` and register it into the live connectors map, so
  `channel.send` / `channel.receive` reach it — beyond the built-in `in_app`
  feed. Platform-gated to desktop. No `mcp_channel` core change; a real
  connection just needs the platform credentials in `params`. Inbound from any
  connected channel routes to an agent (the in-app feed uses conversationId ==
  agentId; external conversations map via `channel.bind` / `channel.unbind` /
  `channel.bindings`, persisted per-project), and that agent handles it with its
  normal tools — approve a waiting gate via the existing `process_approve`,
  delegate via `agent_route`, reply/notify via `channel.send`. No bespoke
  notify/approve engine: the host exposes composable primitives, the routing is
  data + agent judgment (generic across Studio / AppPlayer / FlowBrain). Seed
  knowledge (`ops_delegation/external_channels`) teaches agents the pattern.
  Credentials go through a **secure vault** (OS keychain): `channel.credential_set`
  stores a connector's params keyed by `id` (no plaintext read-back — set / list
  ids / remove only), and `channel.connect{id}` resolves them so secrets never
  travel in the connect call / chat / logs. The `id` distinguishes accounts, so
  different accounts on the same platform are just different ids.
- Ops **Channels** page (System group) — a form to register the workspace's
  external accounts: pick a platform (kakao / slack / telegram / email), fill
  its fields (secrets obscured), and Save & connect (stores to the vault via
  `channel.credential_set`, then `channel.connect`). Lists connected + stored
  channels with remove. Pure UI over the host `channel.*` tools.
- Per-member **Contact channel** — from a member's menu (Experts), bind a
  conversation to that member (`channel.bind`) so inbound from it routes to
  them and they can be reached there; lists + unbinds existing bindings. Works
  for person and agent members.
- Org charter — a workspace's doctrine (mission / values / prohibitions /
  north-star) as a single active object that actually governs, instead of being
  copied across members or sitting in a passive doc. `workspace_set_charter`
  writes it as the per-project **active anchor ethos**; the process philosophy
  gate routes through a new per-project `philosophy_check` (replacing the global
  `bk.philosophy.check`) and opted-in agents intervene against the same
  per-project active ethos, so a charter prohibition with a forbidden pattern
  hard-blocks matching output. Members inherit the charter (override only via an
  explicit per-member philosophy fork). `workspace_get_charter` reads it; the
  Organization chart's workspace node shows it. Reuses the kernel Ethos
  (prohibitions gate; mission / north-star are descriptive metadata; provenance
  `kind: anchor` at the payload top level per `specs/platform/07-knowledge-access.md`
  §ethos governance) — no new kernel contract; governance is per-project (not
  the global ethos).
- Org memory — `workspace_record_lesson` / `workspace_lessons` accumulate the
  organization's learnings ("what worked" / rejection patterns) as
  workspace-scoped `org_lesson` facts in the per-project FactGraph, so they
  outlive member turnover and feed the existing workspace knowledge retrieval
  (the learning loop). The Organization chart's workspace node shows the lesson
  count. Reuses the per-project FactGraph (no new store / kernel).
- Organization route — a graphical org-chart with a **lens switch** over the
  same data (no single view can express everything):
  - **Workflow** — process event-topology: each workspace's processes as
    independent unit cards (trigger badge manual / event / task), connected by
    **event edges** (`triggerSource` — one process's completion triggers the
    next; independent processes sit in parallel). Inside a card, steps lay out
    by their `dependsOn` DAG so steps with no ordering between them stack as
    **parallel branches** (not a forced line); approval gates render as a
    sign-off marker (✓) above the gated step, philosophy / quality gates as an
    inline charter checkpoint (◇).
  - **Structure** — the org chart: each workspace (org unit) is a framing
    container box; the unit lead (팀장, `Workspace.leadMemberId`) sits on top
    with reporting lines down to its members; nested workspaces compose
    sub-teams into larger units (hierarchy edges). Members show a 🤖 agent /
    👤 human icon.
  - **Knowledge** — members ↔ the skill / profile / philosophy they reference,
    as a bipartite ownership graph.
  Pan / zoom the canvas (`InteractiveViewer`) with fit-to-view + zoom controls;
  tap any node for detail (workspace summary, process card, agent dialog,
  gate / knowledge card). Pure UI + wiring over existing data (workspace /
  member / process registries); deterministic layout, lens switch is a pure
  re-layout (no re-fetch), live via the change streams.
- Process step `dependsOn` — the process model now carries an explicit
  per-step dependency list (YAML `dependsOn: [stepId, …]`); the behavior
  compiler emits it (falling back to the previous-step linear chain when
  absent), so a single process can express **parallel work** that the behavior
  engine schedules concurrently — not only a forced sequence.
- `task_run` now **drives the assignee agent** (assign + produce): when a task
  is assigned to an agent member, the runner asks that agent to perform it (task
  title / description / skills / inputs become the request) and records the
  member's own turn + returns their deliverable as the run `summary` — instead
  of a headless skill dispatch that left the assignee un-run and the output
  empty. Falls back to skill dispatch for person / unknown assignees. Wired via
  a `TaskRegistry.agentRun` seam bound at boot, so both manual `task_run` and
  the recurring scheduler wake the assignee.
- `agent_route` (a manager/lead dividing work) now resolves `managerId` +
  `candidateAgentIds` to their scoped kernel ids the same way `agent_ask` does —
  bare member ids no longer throw `AgentNotFoundException`, so a lead can
  actually route to its members. New `execute:true` runs the routed member on
  the request and returns their `deliverable` (+ `deliveredBy`) — the
  "assign + request output" flow, so the member's own history records the turn
  instead of the manager fabricating a report.
- Charter + knowledge now **inherit down a workspace's org ancestor chain**
  (same line only — a workspace inherits from its `parentId` chain, never a
  sibling branch), realizing the doctrine in `specs/platform/07 §182`. Charter
  prohibitions **accumulate** (company ∘ department ∘ own — all gate);
  mission / north-star / values take the **nearest** (self-first) value.
  `workspace_get_charter` returns the effective charter + `inheritedFrom`;
  `philosophy_check` enforces the whole chain's prohibitions;
  `knowledge_file_list` / `knowledge_file_read` surface own + inherited
  `knowledge/` files (own shadows an ancestor at the same path, `inheritedFrom`
  marks inherited). Replaces the previous per-project single-active charter /
  copy-only knowledge. (Open, kernel: unifying the charter active with
  `bk.philosophy`'s active.)
- Agent orchestration role is now assignable + profile-driven. The functional
  role (기자 / 편집자 …) IS the **Profile** (persona axis, project-pooled +
  inherited) — no separate role catalog; the org chart's Structure lens now
  labels/groups members by their profile. Orthogonally, `member_create_agent`
  takes an optional `role` (worker / manager / reviewer → `AgentRole`, which
  governs handoff: manager routes, reviewer verdicts); omit it and the agent
  inherits the assigned profile's `defaultRole` (a profile YAML may declare
  `defaultRole:`), else worker. Runtime-created agents are no longer hardcoded
  to worker.
- Workspace `leadMemberId` + `workspace_set_lead` tool — an org unit's lead
  (팀장 / unit head): the top of its hierarchy in the structure org-chart and
  the natural default approver / escalation target. Realizes the team-lead tier
  deferred in `specs/platform/12-flowbrain-runtime` (workspace = recursive org
  unit per `07-knowledge-access`); no separate Team entity.
- Interactive-auth (`browser.*`) can now **reuse a human's real browser session**
  instead of driving a login inside automation (which SSO providers like Google
  block). Two host-configured session sources for the headful auth engine:
  `settings.browserAuthAttachEndpoint` attaches to a Chrome the user launched
  themselves (`--remote-debugging-port`) so `open_login` / `auth_capture` seal an
  already-signed-in session; `settings.browserAuthUserDataDir` reuses a persistent
  real profile. Only the headful auth engine attaches/persists — the headless
  scraping engine still spawns fresh and injects the sealed profile. Wiring rides
  `mcp_browser` 0.1.3's `ChromiumLauncher.attach` / `userDataDir` (ownership-aware
  `close()`: an attached Chrome is never killed, a caller profile never deleted).
  Verified end-to-end against a real Google session: attach → `auth_capture`
  (sealed `.enc`, AEAD) → re-inject into a fresh headless context → authenticated
  page. The public `browser.*` op surface is unchanged; only the session *source*
  is new.
- Seed knowledge **`ops_operating_playbook`** (makemind_ops.mbd) — an operating
  playbook of field experience (the HOW) layered on the existing tool manual (the
  WHAT), so a fresh coordinator / external LLM can read it alone and stand up +
  continuously run a real organization of any kind (company, newsroom, church,
  academy, research lab, shop). Nine documents: how-to-use + layering, doctrine,
  build sequence, member design, doctrine/knowledge tree inheritance, workflow,
  operating patterns, field-measured pitfalls, verification culture. Universal
  core only; domain- and country-specific practice (regulations, tax, local
  customs) is called out as a separate, replaceable layer seeded into the org's
  own `knowledge/`. Fanned out as `studio://knowledge/ops_operating_playbook/*`
  MCP resources at boot, so the coordinator + members read it as a tool surface.

### Fixed
- Organization chart (structure lens) now renders top-down with a clean
  central spine. Staff (support) units used to hang off the parent in a
  reserved far-LEFT column, which pushed the whole subtree right and left the
  top unit cramped against its operational row. The line (operational) units
  are now the centered spine — the unit box sits over them and a straight
  stem drops to the line row — while staff units step aside into a band
  offset to the RIGHT of that stem (drawn in the muted support color), above
  the line row. So the chart reads top → (staff to the side) → execution,
  and the reporting stem is never crossed. The parent→child connector's
  horizontal bus was moved to just above the child row so the stem clears the
  staff band; single-tier charts (no staff) are pixel-identical.
- Organization Directory now orders units the same as the Home switcher.
  The directory sorted siblings by raw id alphabetically, so its order
  disagreed with the Home workspace tree (which honors the operator-set
  `sortOrder`, then staff-before-line, then id). Extracted that ordering
  into a single `orgWsSiblingCompare` source of truth in the org model —
  the chart layout, the directory nav list, and the card tree all defer to
  it, so every organization lens reads one order.
- The form view is a PACKAGE now — `appplayer_form_view` (utils/, the
  appplayer_ui_view precedent; promotes the early `tools/core/view/form`
  try). It renders a typed `FormDocument` as the actual paper form and
  exists for more than display: every block carries a
  `MetaData {type: formBlock, id}` tag so LLM drivers locate blocks by
  coordinate (`studio.ui.find` matches block ids), `onBlockTap` +
  `selectedBlockId` seed the tap-to-inspect/editor loop, a
  `FormViewController.capturePng()` lets an LLM verify what it built by
  looking at it, and the page model covers full-page sheets and
  section-per-page splits. Form Builder consumes it (the in-app
  `FormDslPreview` mapper is gone): the Templates panel gains an App
  Builder-style block inspector (tap a block → its properties + "edit by
  chat" guidance), and the Issues as-issued view renders frozen `uiDsl`
  artifacts through the package's `formDocumentFromUiDsl` adapter — the
  only tool-surface freeze that carries `form.patch` results today
  (`form.get_document` requested engine-side). Typed input also fixes
  what the uiDsl path lost: image maxWidth/alignment now render exactly
  (the screenshot-caught runaway-seal bug), and `studio.ui.find` returns
  ONE rect shape ({x, y, width, height}) for tagged and visible-text
  matches alike.
- Per-domain project locations now actually work. Every built-in's Domain
  Settings has a "Workspace folder" field (Scene Builder / Ops / Form
  Builder gained it; App Builder already showed one), and — the real fix —
  the override is CONSUMED everywhere a project gets created: the New
  dialog default parent, `studio.project.new`, and
  `studio.scene.project.new` all resolve the active domain's override
  first, then the studio-wide workspaceDir. Previously App Builder's field
  was saved but never read, the other three had no field at all, and
  project creation silently fell back to the studio dir (or
  `~/AppPlayerProjects`) — "projects landing in the wrong place".
- The synthetic UI driver (`studio.ui.*`) is now reliable for LLM-driven
  verification — three defects fixed as a set (found driving Form Builder):
  - `studio.ui.find` falls back to VISIBLE TEXT (a live element-tree walk
    over RichText) when the inspectTag search finds nothing, so text on
    native built-in pages — rail labels, list cards, dialog buttons — is
    findable and tappable via the returned rect (previously 0 matches).
  - Synthetic taps/drags dispatch as TOUCH (flutter_test parity). A
    mouse-kind Down/Up without a preceding PointerAddedEvent tripped
    MouseTracker's device-lifecycle assertion and the corrupted tracker
    then swallowed later taps. Mouse-only paths (hover / right-click /
    wheel) now ride one persistent synthetic mouse device that is
    properly added first.
  - `studio.debug.screenshot` / `studio.renderer.screenshot` capture the
    WHOLE render view (root-navigator overlays included) with the shell
    boundary as fallback — open dialogs no longer vanish from shots,
    which had read as "the tap did nothing" and misdiagnosed working UI
    (Ops's ui_capture already did this; the shell path now matches).
  The seeded Studio debugging manual teaches the find→tap flow and the
  overlay-inclusive screenshot semantics.

- `workspace_delete` is now **persistent + consistent** — a deleted workspace
  no longer resurrects on reboot. A workspace has two on-disk homes: the
  type-nested metadata dir (`<root>/<type>/<name>`, scanned for `workspace_list`)
  and the content bundle (`<root>/<slug>.mbd`, holding members / skills /
  processes read directly by `member_list({workspaceId})` and the Ops tab).
  `delete` removed only the metadata dir — a path typo (`<root>/<id>` instead of
  `wsContentRoot`) leaked the `.mbd`, so `workspace_list` showed the workspace
  gone while its members stayed resolvable by explicit id and the tab
  re-discovered it on the next boot (half-delete inconsistency). `delete` now
  removes both homes; the `workspace_delete` handler additionally evicts the
  member registry's per-workspace cache (`MemberRegistry.evictWorkspace`) so the
  removal is consistent in-session too, not just after a reboot.
- Ops Home no longer lands on nothing. The active workspace is only a view, but
  when it resolved to the empty reserved `_system` slot Home showed "—" with
  blank cards — most visibly right after deleting the active workspace. Now a
  sensible lens is always selected: (a) boot defaults `_system`/absent → the
  first real workspace; (b) creating the first workspace in a fresh project
  selects it; (c) deleting the active workspace reselects the first remaining
  (falling back to `_system` only when the last one is gone). Every reselect
  goes through `KnowledgeInit.switchWorkspace`, which now persists the
  per-project active pointer for ALL callers (UI + MCP) — previously only the
  MCP `workspace_switch` handler wrote it, so a UI switch reset on the next boot.
- The kernel agent runtime is now **workspace-complete** — boot mirrors *every*
  workspace's agents into flowbrain, not just the active one. Previously only
  the boot-active workspace was loaded (`loadActive`), so `agent_ask({agentId,
  workspaceId})` for another department threw `AgentNotFoundException` even
  though the member existed on disk (the member resolved, but the kernel runtime
  held no such agent), and `bk.agent.*` (e.g. assign-facts) could not see
  per-project members outside the active lens. `loadAll` loads all workspaces
  (active last, so it still wins any shared skill-pool / profile-registry id
  collision and owns the active philosophy), matching the "all departments run
  concurrently — active is a UI lens, not an execution gate" model. Cross-workspace
  `agent_ask` / `agent_route` now resolve any member regardless of the active
  workspace.
- Worker agents now carry a **self-identity** system prompt ("You are
  `<displayName>`, a `<role>` in the `<workspace title>` workspace") seeded at
  mirror time, so an agent answers with its own name and department instead of
  guessing the operator or another persona from ambient context. Applied on
  create and re-seeded on an already-mirrored agent whose prompt drifted (a
  `.kv`-persisted agent created before this wiring gains its identity on the
  next boot).
- `knowledge_fact_save` / `workspace_record_lesson` now take a `workspaceId` so a
  fact can be attributed to the department it is ABOUT — e.g. an HR-pinned agent
  recording an onboarding fact for an `org/media` member — instead of always
  landing in the caller's active / execution-pinned workspace. `saveFact`
  defaults to the bound workspace but routes an explicit target to the
  project-wide FactGraph (the KV mirror stays the active workspace's sandbox —
  its adapter guards cross-workspace reads/writes — so a cross-workspace fact
  lives in the graph alone), and `query(workspaceId:)` round-trips it. Facts do
  not leak into the caller's own workspace.
- The host no longer dies on an uncaught async error raised OUTSIDE a tool
  handler's `await` chain — e.g. a long-running agent turn (the Claude Code
  fallback subprocess) surfacing an error from a stream / timer / unawaited
  callback. `StudioMain.run` installs a top-level `PlatformDispatcher.onError`
  (and `FlutterError.onError`) backstop that logs to stderr and keeps the
  process alive; per-tool errors are still returned to callers by the tool
  wrapper's own try/catch. Previously an out-of-band error of this class could
  take the whole host process down mid-run.
- Home header no longer overflows on a narrow content area — the title now
  takes flexible space (and ellipsizes) so the Filter / New task buttons stay
  in view instead of a `RenderFlex overflowed` stripe. `OpsCrumb` clips to a
  single line (ellipsis) rather than wrapping character-by-character.
- Home KPI tiles now **wrap responsively** (4-wide → 2 → 1 via a `Wrap` sized by
  `kpiColumnsFor`) so a narrow content area flows the tiles onto extra rows
  instead of squeezing each until its label stacks character-by-character.
- Active workspace is now remembered **per project**, not in a single shared
  global. `workspace_switch` previously persisted the active workspace to one
  global `~/.makemind-ops/config.yaml` `activeWorkspace` field shared by every
  host and project — so switching workspaces in one project (e.g. a debug
  scratch project) overwrote it with an id absent from another project (e.g. the
  live ops project), whose boot then failed the "does this workspace exist here"
  guard and fell back to the empty `_system` slot, making the project open on a
  blank Home / chat with its members + data seemingly gone. The active workspace
  now persists to a per-project `<projectRoot>/.makemind-ops-active` file that
  boot restores from (validated against the project); the global field is no
  longer written by a switch, so no host/project can contaminate another.
- Built-in last-project binding is now **per host** (Ops + App Builder). It
  previously lived in a single hardcoded per-app config folder
  (`~/.config/makemind_ops/`, `~/.config/app_builder_vibe/`), shared by the
  debug (`vibe_studio_debug`) and release (`vibe_studio`) hosts — so opening a
  project in one host made the other reopen it too (and for Ops, booting the
  live project wrote lifecycle facts into it). The pointer now lives as a
  **value** in the per-host host config store (`VibeSettings.domainLastProject`,
  keyed by the built-in's id) — no hardcoded project folder, and the
  already-separated host config dirs keep the two instances independent.
  (Existing users re-open the project once after upgrade.) Scene Builder has no
  project binding, so it was unaffected.
- Process gates in a bound project now judge for real instead of the
  crash-guard stub's always-`proceed` (0.5). The per-project `OpsRuntime` is
  assembled with real ports — facts / claims from the disk-backed FactGraph
  (`factGraph.facts` / `.claims`), and a Decision port adapting the project's
  own `ProfileRuntime` (real `DefaultDecisionEnginePort` + `Passthrough`
  expression engine) via `mcp_profile`'s `DecisionPortAdapter`. `mcp_profile`
  is now a direct dependency (was transitive). Appraisal stays stubbed — the
  real `AppraisalEnginePort` bridge does not yet exist in `mcp_profile` (only
  a stub + caching decorator), so that one axis is deferred. All per-project
  (no global routing).
- Bound project now restores the last active workspace on open instead of
  always falling back to the reserved `_system` slot. A reopened project landed
  on the empty `_system` workspace, so its members / agents / created data were
  not visible (the data was intact under the user's workspace, e.g. `org/devmag`
  — just not the active one). `_withProjectRoot` now keeps the saved
  `activeWorkspace` when its bundle dir exists under the project root, falling
  back to `_system` only for a stale id from a different project (the original
  hazard the unconditional reset was guarding against). Verified end-to-end: a
  reopen now binds the saved workspace and its members list immediately.
- Per-project agent LLM resolution — a bound project builds its own per-project
  agent subsystem (agents isolate per project, like its facts / knowledge / chat),
  but that subsystem resolved an agent's model only from the project's configured
  key pool, so on a keyless setup a worker tagged `claude` returned empty content.
  The host's global agent LLM session pool (carrying the claude-code fallback) is
  now merged in as a base layer — project-configured keys still win — so a
  per-project agent resolves its model while staying per-project.
- `process_start` in a bound project — the per-project KnowledgeSystem is now
  assembled with an `OpsRuntime` (stub consumed ports + the project-rooted KV, via
  the published `OpsRuntime.fromConsumedPorts`), so gate / handoff process runs no
  longer throw "OpsRuntime not configured".
- `system_agent_set_model` — bound projects now seed their own `_ops_admin` system
  agent (the seed gate widened to any self-built system, not just standalone), and
  the tool falls back to the shared host registry when the target is a
  workspace-scoped chat manager (`ops.manager.<unit>`), so setting a model no
  longer throws AgentNotFound for the default or a scoped manager.
- Resources route refreshes live on a knowledge mutation — `KnowledgeRegistry`
  now emits a change stream (fact save / knowledge file write / delete) that the
  assets list watches, so a `knowledge_fact_save` appears without a manual tab
  reload.
- `studio.fs.list` lists the workspaceDir root when `path` is empty / omitted
  (read / write / delete still require a concrete path).
- `knowledge_ingest_file` notes when it produced 0 fragments (no embedding
  provider configured → not RAG-searchable) instead of silently implying success.
- Ops tool workspace resolution no longer depends on the **global mutable active
  workspace**, which concurrent actors flipped via `workspace_switch` — a
  multi-agent race where one agent touring departments and another monitoring
  clobbered each other's active, so a tool read the wrong workspace. Resolution
  order is now: explicit `workspaceId` arg → the caller's execution-scoped
  workspace (`WorkspaceExecutionContext`, a per-run zone value an agent is pinned
  to) → active (UI lens fallback only). Twelve tools gained a uniform optional
  `workspaceId` (`member_list` · `member_get` · `task_list` · `task_create` ·
  `process_list` · `process_save` · `skill_list` · `skill_get` · `skill_save` ·
  `status_snapshot` · `workspace_get_charter` · `agent_ask`), and an agent run is
  pinned to a stable workspace so its own tool calls don't drift when another
  actor switches the UI lens mid-run. "Active" is demoted to a dashboard lens +
  last-resort fallback; concurrent multi-department operation is race-free for
  explicit / pinned calls. Host-only — the per-workspace registries were already
  parameterized; no kernel change. (`workspace_record_lesson` fact scope is a
  separate FactGraph-KV layer, tracked for a follow-up.)

### Changed
- The Ops organization chart opens at **natural size (1:1)** instead of
  fit-to-view — a large org must stay READABLE and be explored by pan/zoom,
  not shrunk whole into the viewport (12+ units rendered illegibly small).
  Fit-to-view stays as the explicit Fit button; a `1:1` button returns to
  actual size; max zoom raised to 3x; content edits no longer reset the
  user's pan/zoom (only a lens switch re-anchors). The chart header now
  degrades gracefully on narrow panes (scrolling legend, ellipsized hint,
  fully scrollable strip when even the lens switch doesn't fit) instead of
  overflowing.
- `workspace_create` rejects a slug containing `/` up front (registry-level
  invariant + tool-level guidance). A slash slug composed an id whose
  metadata dir nested one level deeper than the reload scan reads, so the
  workspace was created and worked in-session, then silently vanished from
  `workspace_list` on the next boot. Nesting is `workspace_set_parent`, not
  a path-like slug.
- Ops seed knowledge (`ops_overview`/agents) corrected: `ops.manager`'s tool
  access is the explicit 83-entry allowlist in the seed's agents block (bk.* 10
  · browser.* 3 · ops 70), not an "empty list (wildcard)" — the old sentence
  contradicted the manifest's actual `tools` value.
- Ops operating-playbook seed knowledge refined from a chat-simulation pass
  (konpi) — three behaviors the coordinator under-applied on a small org are now
  imperative: `build_sequence` scales the doctrine step to the request (state
  assumptions + confirm for a one-liner instead of silently skipping it);
  `member_design` forbids role-only agent names (always "Name · Role", never a
  nameless "Note-keeper"); `workflow` requires a recurring need ("every week")
  to become a cron heartbeat task, not a manual process.
- `mcp_browser` ^0.1.2 → ^0.1.3 — attach mode + persistent profile for the
  interactive-auth session-reuse wiring above (published, hosted-clean resolve).
- `brain_kernel` ^0.1.4 → ^0.1.5 — picks up the `KvStoragePortAdapter.keys(prefix:)`
  string-prefix contract fix, so `bk.philosophy.list` (and any flat colon-keyed
  listing) returns its entries instead of an empty array. Resolved from pub.dev.
- `studio.fs.write` description clarifies it writes under the configured
  workspaceDir (not the bound project / per-workspace bundle) and points
  per-workspace content / assets at `knowledge_file_*`.
- Agent knowledge seeds synced to the tool surface — the Ops tool catalog's
  `system_agent_set_model` entry and the shared `studio.mbd` `studio.fs.*` doc now
  describe the per-project / scoped-manager routing and the workspace write
  surface.
- Ops chat is now a **single per-project coordinator**, not one manager per
  workspace. `ops.manager` is scoped by the ops project path alone (`_applyOpsScopedManager`),
  exactly like App Builder / Scene Builder — the Studio-level command channel for
  the whole project, not a member of any workspace's org chart. Switching the
  active workspace no longer re-scopes the chat manager or re-keys its
  conversation; it changes only the data lens (the chat roster refreshes to the
  now-viewed department's agents, the coordinator + its single conversation stay
  put). Enabled by the workspace-complete boot (`loadAll`) above, so the one
  coordinator can `agent_ask` / `agent_route` / `process_start` across every
  workspace. Asset locators (`knowledge_fact_save` `capability:fs`) now relativise
  against the ops **project root** to match the single project chat / `fs.*`
  anchor — workspaces are logical lenses, so assets are project-shared and connect
  to a workspace / agent by reference, not by a per-workspace filesystem base.
  Seed knowledge (`ops_overview/agents`, `ops_concepts/matrix_model`) teaches the
  coordinator model (one interface, workspaces = concurrent views, department
  isolation at the data layer).
- Ops boot skips redundant 4-axis re-forks. Because "active workspace" is a view
  (all departments load at boot via `loadAll`), every member's skill / profile /
  philosophy forks were re-applied on every boot — the dominant cost, growing
  with the roster. Each mirrored agent now carries an `ops_fork_sig` tag =
  hash(workspace pool CONTENT fingerprint + the member's 4-axis refs); a boot
  whose signature matches skips the re-fork (the owned forks already persist).
  Editing any pool yaml or a member's assignments re-stamps the signature so the
  fork re-fires and picks up the change (content hash, not mtime — boot re-save
  can bump mtime without changing bytes). Measured on a 16-workspace project:
  4-axis fork ops on a warm reboot dropped ~183 → ~64.
- Ops tab renders without waiting for the whole org. Boot now loads only the
  ACTIVE workspace on the critical path (`loadActive`) and streams the remaining
  departments in the background (`loadAll`, which re-loads the active workspace
  last so the shared-pool "active wins" ordering + active philosophy are
  preserved). The tab paints as soon as the viewed department is ready instead
  of spinning through every workspace — decoupling tab-render latency from org
  size. `KnowledgeInit.workspacesReady` completes when the background load
  finishes; await it when you need every department resolvable right after boot
  (a cross-workspace `agent_ask`, or a test). Trade-off: a brief post-render
  window where a not-yet-streamed department's agent is unresolvable.

## [0.1.3] - 2026-06-30

### Added
- Operational asset management — a new Ops **Resources** route for registering
  and operating a workspace's operational assets (databases, files, code, repos,
  homepages, deploy targets, APIs — internal or external alike; location is just
  an attribute). Assets are a convention over the existing knowledge fact model
  (no schema change): a `category:"asset"` fact carries `kind` / `location` /
  `locator` / `capability` / `credentialRef` in its metadata, with the secret
  body never in the fact. `asset_open` operates an asset through its capability
  (`fs.read` / `db.query` / `browser.page_view` / an authenticated HTTP GET),
  resolving any credential internally — the secret is never returned.
- Credential vault — `secret.*` (set / exists / remove / list) over the OS
  keychain, exposing no plaintext `get` (a secret is only resolved internally
  when a capability needs it). An asset holds only a `credentialRef`; the secret
  body lives in the vault. The Resources page edits credentials inline (state
  shown as a lock; value obscured on input, never read back).
- Cross-machine credential migration — `credentials_export` / `credentials_import`
  seal a workspace's asset credentials under a passphrase into a portable blob
  (PBKDF2 → AEAD; the keychain key never leaves the device) and restore them on
  another machine. Driven from the Resources **Migrate** dialog. `.opspack`
  export/import gain an `includeSecrets` option that carries the sealed blob with
  a full workspace pack (the blob is opaque — it is never unpacked to disk, and a
  wrong passphrase restores nothing).
- Per-project knowledge persistence — each bound project's knowledge FactGraph
  now persists to disk under `<projectRoot>/.factgraph` (and its KV registry
  under `<projectRoot>/.kv`) instead of a single in-memory graph shared across
  every project. Facts survive restarts, isolate per project, and travel with
  the project folder (the `<project>/chat.jsonl` precedent). New Ops tools
  `knowledge_fact_export` / `knowledge_fact_import` back up and restore a
  project's graph as a portable map, and `knowledge_purge` deletes it; `.opspack`
  export/import carry the graph snapshot when `includeFacts` is set. Built on the
  vendored `knowledge_persistence` recipe (disk-backed storage ports over an
  unchanged `mcp_fact_graph` core); an unbound (no-project) session still uses an
  in-memory graph.
- Plugins — a host-level plugin surface (`plugin.register` / `unregister` /
  `list`) that pulls a bundle / MCP server / hub into the shared tool catalog as
  `<pluginId>.<tool>` for any app or agent. Server and hub plugins persist to a
  shared on-disk registry (available to any AppPlayer host on the machine) and
  reconnect on boot; local-subprocess `server` plugins are gated off mobile.
  Reached from a Home entry (right of the BUILT-IN APPS title) that opens a
  full-surface manager with list / icon views. Built on the vendored
  `plugin_host` recipe — host wiring only, no kernel change.
- Studio viewer kit + Ops **Files** route — a Studio-themed multi-format document
  viewer with a light view↔edit toggle (`VbuDocumentViewer` / `VbuDocumentPanel`)
  that wraps the shared `flutter_mcp_ui_runtime` renderers (markdown / code /
  table / image / webview) in IDE chrome. Its first consumer is a new Ops Files
  route that browses and edits the bound project's files; App Builder / Scene
  Builder can embed the same panel.

### Changed
- Dependencies: `appplayer_secure` ^0.1.0 → ^0.1.1 (passphrase-keyed sealing for
  credential migration). Resolved from pub.dev.
- The host security capabilities (`secret.*` vault + the passphrase migration
  core + `secure.*` at-rest seal/open) are now adopted through the vendored
  `secure_capability` recipe in `lib/src/base/install/capability_recipes/`
  (a committed in-tree copy, like `capability_tools`), so every host shares one
  reference instead of a host-local implementation.
- `mcp_fact_graph` resolves 0.2.3 from pub.dev (constraint unchanged at
  `^0.2.2`); its storage-port injection seam backs the new per-project knowledge
  persistence through the vendored `knowledge_persistence` recipe.
- Model catalog refreshed — Claude Opus 4.8 is the default option, alongside new
  GPT-5.5 / GPT-5.4 mini and Gemini 3.1 Pro / 3.5 Flash entries, in both the chat
  model picker and the Ops LLM model catalog.
- Built-in app knowledge seeds refreshed — the Ops / Scene Builder / App Builder
  agent seeds gained methodology playbooks and an updated host capability/tool
  surface, and the shared `studio.mbd` host seed was synced to the live tool
  surface.

## [0.1.2] - 2026-06-26

### Added
- Capability coverage — `fs.*` / `db.*` (datastore: a config-root-jailed
  filesystem source plus a sqlite source), `canvas.*` (CDL 2D/3D), `kv.*`, and
  `analysis.*` exposed on the shared host registry, alongside the existing
  `io.*` / `channel.*` / `browser.*` / `form.*` / `ingest.*` packs. Wiring is the
  vendored `capability_tools` recipe (`lib/src/base/install/capability_recipes/`,
  a committed in-tree copy for a hosted-clean clone); the engines and policy live
  in the published `mcp_*` packages. Datastore writes are role-gated
  (manager/operator) and destructive ops (`fs.remove`) require an explicit
  commit. Registration is the single `registerCoverageCapabilities` wiring point
  (`lib/src/base/install/coverage_capabilities.dart`), unit-tested in
  `test/base/install/coverage_capabilities_test.dart`.
- Agent seed knowledge — the built-in apps' seed bundles
  (`seed/{studio,makemind_ops,app_builder}.mbd`) now document the full host
  capability surface (a shared `studio_host_tools/capabilities` catalog plus
  `studio_capability_recipes` usage patterns) and are reconciled with the current
  Ops operating model and the `mcp_bundle` 1.0 spec, so agents author bundles and
  design operations from accurate knowledge.

### Changed
- Dependencies: `mcp_bundle` ^0.4.4 → ^0.4.5 (the datastore port contract moved
  into `mcp_bundle`), `mcp_io` ^0.2.2, `mcp_io_process` ^0.1.1; added
  `mcp_canvas` ^0.1.0, `mcp_analysis` ^0.1.1, `mcp_datastore` ^0.1.0,
  `mcp_datastore_sqlite` ^0.1.0. All resolved from pub.dev (no overrides).

### Fixed
- macOS app name — the dock / menu bar / Finder showed the internal build name
  instead of the product name. `PRODUCT_NAME` is now `AppPlayer Studio` (bundle
  identifier `com.makemind.vibeStudio` unchanged).
- Ops last-project restore — closing the Ops tab and reopening it dropped to the
  welcome panel instead of the previously bound project. `OpsShell` now persists
  and reopens its `lastProjectPath` on mount (App Builder / Scene Builder parity).

## [0.1.1] - 2026-06-22

### Added
- io capability — OS process execution + connection device drivers exposed as
  the fixed `io.*` tool surface plus `io.connect_device` / `io.disconnect_device`
  on the shared host registry. Wiring is the vendored `io_drivers` recipe
  (`lib/src/base/install/io_drivers/`, a committed copy kept in-tree for a
  hosted-clean clone); the drivers themselves are the published `mcp_io*`
  packages. `process` (OS execution, deny-by-default sandbox: allowlist +
  plan→commit) registers at boot; network drivers (`modbus` / `mqtt` / `http` /
  `scpi`) provision at runtime via `io.connect_device`. Desktop platform.

## [0.1.0] - 2026-06-21 - Initial open release

### Added
- AppPlayer Studio universal host — a single desktop app (macOS / Windows /
  Linux) that loads any installed domain bundle (`.mcpb`) into a workspace.
  Domain code is zero; the shell composes the base chrome with the workspace
  DSL renderer. Bundles ship their own MCP endpoints + DSL UI.
- Built on the published ecosystem packages (`appplayer_secure`,
  `appplayer_ui_view`, `appplayer_claude_code_provider`, `brain_kernel`,
  `mcp_browser`, `flutter_mcp_ui_runtime`, …) resolved from pub.dev.
