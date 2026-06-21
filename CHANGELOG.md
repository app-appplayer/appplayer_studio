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
