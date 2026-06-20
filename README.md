# AppPlayer Studio

A universal desktop host that loads any installed domain bundle (`.mcpb`)
into a workspace. The studio ships **zero domain code** — the shell composes
a chrome around a DSL-driven workspace, and each bundle brings its own MCP
endpoints and UI. The host is a universal launcher.

Runs on **macOS, Windows, and Linux**.

## What it does

- **Loads domain bundles** — drop in a `.mcpb` bundle and the studio renders
  its UI (declarative DSL) and wires its MCP tools, resources, and prompts.
- **Built-in apps** — three first-party surfaces ship in the box:
  - **App Builder** — compose bundle UIs and tools from a chat + atomic edits.
  - **Scene Builder** — record studio activity and produce annotated
    demo videos (overlays, narration, web export).
  - **Ops** — operate workspaces, knowledge, agents, and processes.
- **MCP-native** — any MCP client (an internal agent, an external LLM, or an
  automation script) can drive the studio and any active bundle through the
  standard tool / resource / prompt surface.

## Getting started

```sh
flutter pub get
flutter run -d macos      # or -d windows / -d linux
```

This package resolves entirely from published dependencies, so a fresh
clone builds without any extra setup.

## Built on

AppPlayer Studio composes the published ecosystem packages — `brain_kernel`
(the MCP-native kernel), `flutter_mcp_ui_runtime` (the DSL renderer),
`appplayer_ui_view`, `appplayer_secure`, `appplayer_claude_code_provider`,
`mcp_browser`, and more — all resolved from pub.dev.

## License

MIT — see [LICENSE](LICENSE).
