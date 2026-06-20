# capture/

Built-in capture / overlay / scenario / chat-automation tools shipped as
host MCP surface — same layer as `install/`, `main/`, `settings/`.

Purpose: enable internal AND external LLMs to drive the studio,
record the activity, and produce shareable artefacts (PNG sequence /
MP4 / annotated video). The bundle `scene_builder.mbd` (in the package's
`seed/`) is the user-facing surface; this directory holds
the host primitives the bundle (and any external MCP client) calls.

## Layout

- `recorder/` — frame capture timer + PNG sequence emitter + dedup
  - `RecorderService` (state machine)
  - `studio.recorder.{start, stop, status}` MCP tools
  - `EncoderService` (PNG seq → mp4 + audio mux); `VideoEditService`
    (trim / concat / web-export / click-zoom of **existing** video) +
    `studio.video.{probe, trim, concat, convert, zoom}`
- `overlay/` — in-frame markup layer (subtitle, arrow, check, ...)
  - `OverlayController` (mutable list of active overlays)
  - `OverlayLayer` (Flutter `Stack` mounted inside shell `RepaintBoundary`)
  - `painters/` — one `CustomPainter` per overlay kind
  - `targets/` — `PositionRef` resolver (rect by element / metadata / abs)
  - `studio.overlay.{push, remove, clear, list}` MCP tools
- `scenario/` — step runner that drives `studio.*` tools in sequence
  - `studio.scenario.{run, dryrun, list}` MCP tools
- `input/` — chat-input automation
  - `studio.chat.send` MCP tool (drops a user turn into the active chat)

## Overlay kinds (production toolkit)

The markup layer is the lecture/shorts production surface. Kinds
(`OverlayKind` in `overlay/overlay_models.dart`, natural-name aliases in
`overlayKindFromString`):

- **structural / branding** — `title_card`, `subtitle` (color/background/
  fontSize/position), `step_indicator`, `watermark`, `transition`
  (declared; scene-boundary transition is a no-op today)
- **pointing** — `arrow_pointer`, `speech_bubble`, `pulse_dot`,
  `connector_line`
- **emphasis** — `circle_highlight`, `check_mark`, `cross_mark`,
  `highlighter`, `box_outline`
- **lecture** — `underline`, `strikethrough`, `bracket`, `numbered_label`
- **media** — `floating_icon` (10 named Material icons or image),
  `floating_image`, `slide`

Media kinds (`floating_icon` / `floating_image` / `slide`) resolve their
image from `path` (an on-disk file → `Image.file`, for slides/logos
exported from Keynote/PPT/Figma) or `asset` (bundled). `path` wins. They
animate in via `motion` (`scale` · `rise` · `drop` · `slideLeft` ·
`slideRight` · `none`) driven by the lifecycle entrance progress — this is
what turns a static logo into an animated one. `slide` is a full-frame
presentation slide: backdrop + `BoxFit.contain` image + optional
`caption` strip, one overlay per beat to play a deck inside the video.

Aliases: `presentation`→`slide`, `logo`/`image`→`floating_image`,
`icon`→`floating_icon`, `caption`→`subtitle`, `title`→`title_card`, etc.
An unknown kind throws in `OverlaySpec.fromJson` which the scenario engine
currently SWALLOWS — hence the alias coverage.

## Audio (narration / music)

The encoder muxes audio at encode time — the recorder itself stays
video-only (PNG sequence). Audio tracks are declared as
`[{path, startMs?, volume?}]`:

- **scenario** — first-class `audioTracks` field (alias `audio`), or
  `encodeOptions.audioTracks` as a fallback. Encoded automatically after
  `recorder.stop`.
- **`studio.recorder.encode`** — `audioTracks` arg, to mux audio onto an
  already-recorded PNG sequence.

`path` is an on-disk audio file, `startMs` offsets it on the timeline
(narration that begins a few seconds in), `volume` scales gain (1.0 =
unchanged; ~0.2 for music sat under a voiceover). Multiple tracks are
mixed (`amix`, no normalize so levels are preserved); output is trimmed
to the shorter of video / audio (`-shortest`). The pure command builder
(`buildEncodeCommand`) is unit-tested without invoking ffmpeg.

## Video editing (trim / concat)

`VideoEditService` (`recorder/video_edit_service.dart`) edits **existing**
video files — distinct from `EncoderService` (PNG seq → mp4). Surfaced as
`studio.video.{probe, trim, concat, convert}`:

- **probe** — `FFprobeKit` duration (seconds) — sizes the editor's trim
  handles.
- **trim** — `[startSec, endSec]`, frame-accurate (output-side `-ss`/`-to`,
  re-encode to libx264/yuv420p). `endSec` omitted = clip end.
- **concat** — joins clips in order via the concat demuxer,
  stream-copy. Clips must share codec/resolution/fps (studio recordings +
  clips trimmed here do).
- **convert** — web-friendly export for homepage demos: `webm`(VP9+Opus,
  autoplay-loop), animated `webp`(libwebp, looped), `gif`(palettegen/
  paletteuse for clean colors), or `mp4`(libx264). `fps`/`width` trim
  weight; gif/webp drop audio. Homepage demos prefer these over raw mp4.

Pure command builders (`buildTrimCommand` / `buildConcatCommand` /
`buildConcatListFile` / `buildConvertCommand`) are unit-tested without
ffmpeg; the graphs are ffmpeg-smoke-verified (trim 3s→1s, concat 1s+3s→4s,
convert mp4→webm/gif/webp all produce output). The Scene Builder **Video**
mode (`scene_builder/feat/editor_view.dart`) is the UI: import a video
(file picker) → trim each (RangeSlider) → pick export format (mp4/webm/gif/
webp) → Export = per-clip trim + concat + optional convert. Builtin = UI +
wiring; all logic is here in the host primitive.

## Cursor motion + click zoom (demo motion)

The recorder captures the shell `RepaintBoundary`, which does **not**
include the OS mouse pointer — so polished product demos need motion
synthesized:

- **Synthetic cursor** — `OverlayKind.cursor` (`painters/cursor.dart`).
  A single `target` parks the pointer; `targets: [from, to]` travels A→B
  over `appearMs` (eased). `{click:true, clickMs, clickColor}` adds a
  click ripple when travel completes. Drawn inside the RepaintBoundary, so
  it lands in every recorded frame. Pushed via `studio.overlay.push`
  (kind `cursor` / aliases `mouse`, `pointer`).
- **Click zoom** — `studio.video.zoom` → `VideoEditService.zoom` (pure
  `buildZoomCommand` / `buildZoomExpr`). Screen-Studio-style: a
  time-varying ffmpeg `crop` zooms the frame toward a normalized focus
  point `(focusX, focusY)` between `startSec`/`endSec` (trapezoidal z(t):
  eased in → hold → eased out), then `scale` back to source size. Source
  dims probed via `probeSize` when omitted. Pairs with the cursor overlay
  to emphasize a click. ffmpeg-smoke-verified: identity outside the window
  (PSNR ~48 dB vs source), clearly zoomed at peak (~14 dB), dims preserved.

## Always-on

These tools are built-in (always registered) so any MCP client — internal
agent, external LLM, automation script — can record any package's
workflow regardless of which bundle is active. There is no enable/
disable toggle; the tools are cheap when idle and the capability is
load-bearing for cross-domain recording.

## Module boundary

`capture/` does NOT depend on any other `src/base/` module
beyond `main/chrome_bridge.dart` (for `captureScreenshot` /
`captureRootKey` slots) and `chat/chat_controller.dart` (for
`studio.chat.send`). Keeps the module deletable / replaceable.

Host wiring:
- `vibe_studio_host_app.dart` registers tools via `registerCaptureTools`
- `standard_studio_shell.dart` mounts `OverlayLayer` inside the
  RepaintBoundary so overlays appear in screenshots
