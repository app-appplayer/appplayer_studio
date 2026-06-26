## [0.1.2] - 2026-06-25

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
