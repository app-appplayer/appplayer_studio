// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/host_media/lib/host_media.dart
// Regenerate with debug/tool/sync_host_media_fork.sh.
// Runtime imports are rewritten to the studio's vendored runtime fork.
//
/// host_media — the platform powers a UI DSL runtime declares but cannot
/// perform itself (spec §6.13).
///
/// The runtime draws the player, resolves the `AssetRef`, routes `onError`.
/// What it cannot do is decode audio, run a browser, or rasterise a PDF. Those
/// arrive from the host through the ports here, exactly as asset resolution
/// already did — and a host that wires only some of them is still conformant:
/// what it did not wire is *declared absent*, and the affected widget reports
/// instead of pretending.
///
/// Consumed by path (AppPlayer Pro · X · Custom · Cloud) or vendored
/// (AppPlayer Standard, Studio standard). publish_to: none.
library;

export 'src/web_surface.dart' show iframeWebViewSurface;
export 'src/media_capabilities.dart'
    show
        JustAudioSoundPort,
        PlatformMediaPort,
        playableUri,
        assetBytesForTest,
        waveformPeaks,
        lottieSurface,
        pdfSurface,
        webViewSurface;
