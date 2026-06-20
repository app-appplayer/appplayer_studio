/// MCP server Dart pattern reference. The LLM receives this verbatim
/// when the user clicks Build, plus the canonical bundle JSON and the
/// chosen output paths. The LLM then calls `write_file` / `edit_file`
/// to materialise a runnable Dart MCP server.
///
/// Keep this guide spec-truthful — every example here is what vibe
/// expects to see in shipped artifacts. When the underlying packages
/// (`mcp_server`, `mcp_bundle`) change, update this string and bump
/// the version pins below.
const String mcpServerDartPattern = r'''
# MCP server Dart pattern (AppPlayer Builder)

You are generating a runnable Dart MCP server inside the user's
project. The host has already chosen:

- **Output components**: bundle (.mcpb) and/or server and/or native app.
- **Packaging** for server / native: `bundle` (loads `.mbd/` from
  disk) or `inline` (bakes the bundle JSON into source).
- **Source channel**: which `.mbd/` to use for the bundle archive.

You must produce the matching files using `write_file`. Use stable,
predictable paths inside the requested output directory. Never write
outside the project root.

## Reach for makemind packages first

Before writing custom Dart in `server.dart` / `lib/main.dart`,
consider whether the capability the user asked for is already a
**makemind ecosystem package** — vibe exists to propagate that
ecosystem. The full catalog (32 packages, 7 layers) lives at
https://app-appplayer.github.io/makemind and inside `vibe://about`
under the **makemind ecosystem** section. Common picks:

| User asks for | Package |
|---------------|---------|
| Forms / inputs | `mcp_form` |
| Background jobs / multi-step automation | `mcp_flow_runtime` |
| Pub/sub between widgets | `mcp_channel` |
| Charts / canvas drawing | `mcp_canvas` |
| Tabular analysis | `mcp_analysis` |
| Data ingestion / ETL | `mcp_ingest` |
| Headless browsing / scraping | `mcp_browser` |
| AI memory + facts | `mcp_knowledge` (+ `mcp_fact_graph`, `mcp_profile`) |
| LLM in the loop | `mcp_llm` |
| Modbus / CAN / serial / OPC UA / SCPI | `mcp_io_<protocol>` + `mcp_io` |
| WebSocket / HTTP / MQTT transport | `mcp_io_websocket` / `_http` / `_mqtt` |
| Multi-server routing | `mcp_gateway` |
| Connection lifecycle | `appplayer_core` |

**Workflow when you accept a feature request:**

1. Match the request to a package (or compose a few). Add the
   package(s) to `pubspec.yaml` with caret pins (`^x.y.z`, latest
   from pub.dev) — never vendor sources.
2. `dart pub get` (headless target) or `flutter pub get` (native).
3. Import + wire inside the existing marker block (`// custom tools`
   / `// custom resources`). Don't move the markers.
4. Hand-rolled logic stays for project glue only — domain
   capabilities live in their canonical package so the user inherits
   tests + future fixes.

When unsure of an API shape, fetch the package's pub.dev page or
its makemind catalog entry before guessing.

## Tool action wiring (`{type: "tool", ...}` in canonical)

mcp_ui DSL 1.3 spec defines two cooperating mechanisms (§3.10 +
§4.4.1 / §4.4.2):

### Default — auto-merge (§3.10)

> When a `tool` action succeeds, the runtime parses the response
> text as JSON and merges each top-level key into page state.

Make handler response keys match the page's state binding names
1:1. The host folds them automatically — no `onSuccess` needed.

```json
"onTap": {
  "type": "tool",
  "tool": "calculate",
  "params": {"expression": "{{expression}}"}
}
```

Handler returns `{"result": "<computed>"}` → host folds
`state.result = "<computed>"` → UI re-renders `{{result}}`.

This is the canonical pattern verified across MCP hosts (AppPlayer,
demo_mcp_server reference). Use it whenever response keys can be
named after the bindings the page reads.

### Variant — explicit onSuccess / onError (§4.4.2)

Only when you need to *transform* the response, *route to a
different binding*, or run a non-state side effect.

> Inside `onSuccess`: the full response is available as `event.*`
> (`event.name`, `event.value`, etc.). Inside `onError`:
> `event.code`, `event.message`, `event.details`.

```json
"onSuccess": {
  "type": "state", "action": "set",
  "binding": "displayName",
  "value": "{{event.firstName}} {{event.lastName}}"
},
"onError": {
  "type": "notification",
  "message": "Error: {{event.message}}",
  "severity": "error"
}
```

**Variable name is `event.*` — not `response.*`, not bare `error`.**
Other action frameworks use those names; this DSL does not.

### `bindResult` — opt out of auto-merge

Set `bindResult: "<state.path>"` on the tool action to store the
raw result at that path and skip the §3.10 auto-merge. Useful when
the response is a list or an opaque blob the page treats atomically.

### Response shape rule (always)

Keep handler return-keys minimal. Each top-level key auto-merges
into the same-named page binding (§3.10) — extra keys silently
overwrite same-named bindings. Errors: `_register` converts thrown
exceptions into `{"error": "<message>"}` (also auto-merged), so a
binding `{{error}}` can display them directly without onError.

### Implementation caveat — current runtime gap

The `flutter_mcp_ui_runtime` package today does NOT implement either
spec point on its own:
- §3.10 auto-merge: ToolActionExecutor stores the result at
  `tools.<tool>.result` (namespaced) only. `StateManager.mergeState`
  is defined but never invoked on tool responses.
- §4.4.2: ActionHandler registers the response under `'response'`
  (and the error under bare `'error'`) instead of `'event'`. The
  `binding_engine` does have an `event.*` resolver path, but the
  child context never holds an `event` key.

What that means for vibe-built apps:
- **Serving**: external hosts (AppPlayer) compensate via their own
  fold — AppPlayer's `ToolDispatcher` runs `runtime.stateManager.set`
  for each top-level key after `client.callTool`. Plain `{type:"tool",
  ...}` actions therefore work over MCP. **Don't add `onSuccess`** —
  AppPlayer's `_onToolCall` is `Future<void>`, so the runtime sees
  `result.data = null` and `onSuccess` overwrites the just-folded
  state with null.
- **Self-UI**: `_register` here wraps the specific executor with
  `runtime.stateManager.mergeState(result)` so the same §3.10
  behaviour fires in-process. Without that wrapper the runtime
  alone would not update bindings on tool actions.
- `{{event.*}}` is the spec-correct variable name and the resolver
  understands it, but until ActionHandler registers under `'event'`
  the path resolves to null in practice. Treat §4.4.2 as
  *forward-compatible* — write code as if it worked, but rely on
  §3.10 auto-merge for actual state updates today.

## Transports — one binary, three modes

The headless `inline` and `bundle` targets emit a single binary that
supports all three MCP transports. Pick at launch:

```
./<binary>                                    # stdio (default)
./<binary> --http                             # streamable HTTP on
                                              # 127.0.0.1:8080/mcp
./<binary> --http --port 9000                 # custom port
./<binary> --http --host 0.0.0.0 --port 8080
./<binary> --sse                              # SSE (legacy)
./<binary> --endpoint /api/mcp                # override path
```

Default = stdio so spawn-based hosts (Claude Desktop, AppPlayer's
stdio transport, mcp_client stdio) just work without any args.
Add `--http` / `--sse` when you need a network-attached transport;
the same binary serves the same canonical UI and handlers either
way. Bundle variant additionally accepts `--bundle <path>` to
override the sibling `app.mbd/` lookup.

Native (`native_inline` / `native_bundle`) variants follow the same
contract — `main(List<String> args)` parses transport options and
the server connects accordingly. `open <app>` (Finder double-click)
supplies no args → stdio mode starts but the inherited stdin is
detached, so the MCP wire is idle while the Flutter GUI keeps
running (self-UI tool calls dispatch in-process via the runtime).
Launch the binary with `--http` / `--sse` from a script when an
external client needs to attach over the network.

## Channels in one paragraph

Every project has a `serving` channel — the required spine that
backs `mcpb` packaging and the headless `bundle` / `inline` server
targets. A project may also have a `native` channel — an optional
second `.mbd/` whose UI is meant for native Flutter delivery. Native
build targets default to the `native` channel when present and
enabled; otherwise they automatically use `serving`. The full
channel docs (create / activate / copy / swap / disable / purge)
live in `vibe://about` under the **Channels** section.

## Build preset (start here when the user says "build")

The project may already have a saved Build preset. Always check it
first when the user asks for a build without specifying details:

1. `vibe_build_config_get` → returns `{preset: {...}}` when the user
   clicked **Save** or **Build** in the GUI dialog before, or
   `{preset: null}` when the project has no preset yet.
2. If `preset` is non-null, just call `vibe_build_run` (no args).
   The preset already encodes target / channel / outDir.
3. If `preset` is null, call `vibe_build_config_set target=<x>
   channel=<y> outDir=<z>` first — pick sensible defaults from the
   user\'s phrasing (e.g. "build the native app" ⇒ `target:
   native_inline`, channel `serving` if `native` is disabled). Then
   `vibe_build_run`.
4. If the user explicitly asks for a different target this time, pass
   it as an arg to `vibe_build_run` — overrides apply for that run
   only and do **not** mutate the saved preset.

This means the user can say "build it" / "rebuild" / "make the build" with
no extra detail and you can act without follow-up questions, as long
as the preset is set.

## Target taxonomy — two orthogonal axes

The four Dart-source targets are the **product of two axes**, picked
independently. Treat them as a matrix, not a list.

**Axis 1 — UI location** (where the ApplicationDefinition lives at
runtime):
- `bundle`: UI loaded from a sibling `app.mbd/` on disk (or Flutter
  assets for native variants). Editable post-build.
- `inline`: UI baked into the source as a Dart string constant.
  One file to ship; not editable without a rebuild.

**Axis 2 — Rendering responsibility** (who draws the UI):
- *Headless*: only the MCP server runs. An external client (Claude
  Desktop, MCP Inspector, AppPlayer) connects and renders the UI.
- *Native (self-UI)*: the same MCP server runs **and** the process
  itself renders the UI via `flutter_mcp_ui_runtime`. Native still
  serves over MCP for external clients — self-UI is *added*, not
  *substituted*.

Crossing the axes — four variants:

|                     | UI on disk (`bundle`) | UI baked (`inline`)   |
|---------------------|-----------------------|-----------------------|
| **Headless**        | `bundle`              | `inline`              |
| **Native (self-UI)**| `native_bundle`       | `native_inline`       |

All four share the **MCP server** core. `native_*` simply adds
self-rendering. The two axes are independent: pick any combination.

Plus one packaging output (off the matrix):

- `mcpb` — single archive AppPlayer installs in place. Not a server,
  not an app — just the bundle as a zip.

| Target | Folder | Package | Role |
|--------|--------|---------|------|
| `mcpb` | `build/mcpb/` | (`bundle.mcpb`) | Packaging only |
| `bundle` | `build/bundle/` | `{project}_bundle` | MCP server, UI on disk, headless |
| `inline` | `build/inline/` | `{project}_inline` | MCP server, UI baked, headless |
| `native_bundle` | `build/native_bundle/` | `{project}_native_bundle` | MCP server + self-UI, UI on disk |
| `native_inline` | `build/native_inline/` | `{project}_native_inline` | MCP server + self-UI, UI baked |

Each target folder is **self-contained** — `cd build/<target> &&
dart pub get && dart compile exe -o <name> server.dart` should work
without reaching back into the project root. Layout is **flat** at
the target root: `server.dart`, `pubspec.yaml`, `README.md`, the
compiled binary (named after the package, e.g. `calc_inline`), and
the `app.mbd/` copy for the bundle variants. No `bin/` / `tool/`
sub-directories.

The project root itself is owned by vibe (`project.apbproj`,
`bundles/`, `prefs.json`, `history.jsonl`, `undo.json`) plus optional
`src/` and `assets/` for **author-written, non-derived** helpers
that the LLM may add when the user asks for them.

## Hosted dependencies

Generated `pubspec.yaml` MUST reference hosted pub versions, never
local paths. Current pins:

```yaml
mcp_server: ^2.0.0
mcp_bundle: ^0.3.0
```

## Native variants (MCP server + self-UI Flutter app)

`native_bundle` and `native_inline` emit a **standard Flutter app**
that runs an MCP server **and** renders the same UI itself. The
scaffold is split into single-responsibility modules so domain code
(handlers, services, integrations) lives in dedicated files and the
base scaffolding stays untouched. Same 5-file shape regardless of
the UI-location axis — only `lib/ui_loader.dart` differs:

```
build/native_inline/                 build/native_bundle/
├── lib/                             ├── lib/
│   ├── main.dart                   │   ├── main.dart
│   ├── native_app.dart             │   ├── native_app.dart
│   ├── mcp_server_setup.dart       │   ├── mcp_server_setup.dart
│   ├── ui_loader.dart  (inline)    │   ├── ui_loader.dart  (rootBundle)
│   └── handlers.dart               │   └── handlers.dart
├── pubspec.yaml                     ├── pubspec.yaml         (+ assets)
└── README.md                        ├── README.md
                                     └── app.mbd/  (Flutter assets)
```

Module responsibilities:

- **`main.dart`** — entry point; `runApp(const NativeApp())` only.
- **`native_app.dart`** — Flutter UI shell (Scaffold + status bar)
  that hosts MCPUIRuntime, kicks off the MCP server, wires handlers.
  Edit-points: scaffold chrome, theme. Do NOT add domain code here.
- **`mcp_server_setup.dart`** — `ServerConfig` + `startMcpServer()`.
  Publishes the same `ui://app`, `ui://pages/<id>`, `ui://app/info`
  resources the headless variants serve. Edit `serverConfig` for a
  different transport / host / port / auth.
- **`ui_loader.dart`** — variant-specific. Inline parses a baked
  `_uiJson` constant; bundle reads `app.mbd/ui/*` via `rootBundle`.
  Returns the same `ApplicationDefinition` map either way.
- **`handlers.dart`** — domain tool registrations. **The only file
  most additions touch.** Use the included `_register(...)` helper
  to wire each handler on BOTH surfaces (runtime for self-UI button
  taps, server for external MCP clients) with one call.

Markers inside `handlers.dart`:

```dart
// ─── custom tools (LLM inserts _register(...) calls below) ───
// ─── custom resources (LLM inserts server?.addResource(...) below) ───
```

Adding a tool only changes `handlers.dart`. Splitting handlers into
per-feature files (e.g. `lib/handlers_calc.dart`,
`lib/handlers_sensor.dart`) is encouraged once the module grows
beyond a few tools — `registerHandlers` becomes a dispatcher that
calls each feature module's own register fn.

A bare `flutter create .` lands platform folders alongside the
existing `lib/` + `pubspec.yaml` without touching authored code.

Platform scaffolding: vibe's GUI **Build** dialog runs `flutter create
--project-name <slug> .` automatically when the "Run flutter create
after emit" checkbox stays on (default). When driving the converter
externally via MCP, run the same command yourself once per build
folder via `vibe_build_run_shell flutter create --project-name <slug>
.` — it adds android/ios/macos/linux/windows/web folders without
touching `lib/main.dart` or `pubspec.yaml`. Skip the step on
subsequent rebuilds: the helper is idempotent but the GUI also
short-circuits when any platform folder is already present.

Channel routing: `native_bundle` and `native_inline` source the
**`native`** channel by default (when enabled), so the self-rendered
output matches the channel meant for native Flutter delivery. Override
with `vibe_convert_dart channel=<id>` when you need a different
channel.

## Headless variants (Dart MCP server, 5-file layout)

`bundle` and `inline` emit a **standard Dart CLI package** with the
same module split the native variants use, minus the Flutter shell:

```
build/inline/                     build/bundle/
├── bin/                          ├── bin/
│   └── server.dart               │   └── server.dart
├── lib/                          ├── lib/
│   ├── mcp_server_setup.dart     │   ├── mcp_server_setup.dart
│   ├── ui_loader.dart  (inline)  │   ├── ui_loader.dart  (bundle)
│   └── handlers.dart             │   └── handlers.dart
├── pubspec.yaml                  ├── pubspec.yaml
└── README.md                     ├── README.md
                                  └── app.mbd/
```

Module responsibilities mirror the native shape:

- **`bin/server.dart`** — entry only. Calls `setup.runServer(args)`.
- **`lib/mcp_server_setup.dart`** — stdio transport + ui:// resource
  registration. Bundle variant reads disk via `mcp_bundle`; inline
  reads the constant from `ui_loader.dart`.
- **`lib/ui_loader.dart`** — variant-specific UI source.
- **`lib/handlers.dart`** — domain tool registrations. Same
  `_register(...)` pattern as native handlers.dart, minus the
  runtime parameter (headless has only the server surface).

Adding a tool only changes `handlers.dart`. Larger features split
into `lib/handlers_<feature>.dart` files that `handlers.dart`
dispatches to — same scaling rule as the native variants.

Run / compile:

```sh
dart pub get
dart run bin/server.dart                     # inline
dart run bin/server.dart --bundle ./app.mbd  # bundle
# or single binary:
dart compile exe bin/server.dart -o <slug>
```

## Cleaning build artifacts

`vibe_build_clean target=<slug>` deletes `build/<slug>/` (generated
artifacts only — `bundles/`, `prefs.json`, `history.jsonl` are
never touched). Omit `target` to wipe the whole `build/` tree. The
GUI Build dialog has a left-aligned coral **Clean** button that
calls the same backend after a confirm. Use Clean before
regenerating when you suspect stale files from a previous variant
or when switching variants in the same folder.
''';
