## [0.1.0] - 2026-06-21 - Initial open release

### Added
- AppPlayer Studio universal host — a single desktop app (macOS / Windows /
  Linux) that loads any installed domain bundle (`.mcpb`) into a workspace.
  Domain code is zero; the shell composes the base chrome with the workspace
  DSL renderer. Bundles ship their own MCP endpoints + DSL UI.
- Built on the published ecosystem packages (`appplayer_secure`,
  `appplayer_ui_view`, `appplayer_claude_code_provider`, `brain_kernel`,
  `mcp_browser`, `flutter_mcp_ui_runtime`, …) resolved from pub.dev.
