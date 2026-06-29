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
