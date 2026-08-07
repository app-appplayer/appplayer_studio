/// What the studio's preview can actually perform (UI DSL §6.13).
///
/// The runtime draws the player, resolves the `AssetRef` and routes `onError`;
/// it cannot decode audio, run a browser or rasterise a PDF. Those come from
/// the host. A host that wires nothing is still conformant — but then
/// `mediaPlayer`, `lottieAnimation` and `map` declare the capability absent and
/// draw NOTHING (§6.13.1: no fake picture where the media belongs), which is
/// exactly what this preview did until these ports were wired.
///
/// That is tolerable in a player and wrong in an authoring tool: the studio's
/// preview is where an author checks what they just built, and a widget that
/// silently disappears is not a check. So the studio wires the same ports every
/// AppPlayer tier wires, from the same recipe.
///
/// The set is DECLARED FROM WHAT IS WIRED — it cannot claim more than it does.
/// A build that drops a plugin (web has no `webview_flutter`) reports that
/// honestly rather than drawing a dead frame.
library;

import 'host_media.dart'
    show
        JustAudioSoundPort,
        PlatformMediaPort,
        lottieSurface,
        pdfSurface,
        webViewSurface;

import '../../runtime/flutter_mcp_ui_runtime.dart' show RuntimeCapabilities;

/// Built once: the ports hold decoder/plugin handles, and a fresh set per
/// preview render would leave the previous one's players unreferenced while
/// still open.
RuntimeCapabilities? _cached;

/// The capability set the studio's preview runtimes are given.
///
/// `mediaSupportsVideo` is true because [PlatformMediaPort] decodes both — the
/// flag exists for embedded hosts that are audio-only, and claiming it falsely
/// would make a video document fail at play time instead of reporting up front.
RuntimeCapabilities studioRuntimeCapabilities() {
  return _cached ??= RuntimeCapabilities(
    sound: JustAudioSoundPort(),
    media: PlatformMediaPort(),
    mediaSupportsVideo: true,
    webViewBuilder: webViewSurface(),
    lottieBuilder: lottieSurface(),
    pdfBuilder: pdfSurface(),
  );
}
