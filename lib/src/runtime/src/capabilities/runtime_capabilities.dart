import 'dart:async';

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../assets/asset_ref.dart';

/// Behaviours a document can ask for that the runtime cannot perform on its
/// own: sound comes out, media decodes, a page loads, a document paginates,
/// tiles are fetched, a vector animation plays.
///
/// Spec §6.13 — a runtime either performs a declared behaviour or reports that
/// it cannot. It never draws a facsimile of the behaviour succeeding. These are
/// platform powers, so the runtime accepts them from its embedder exactly as it
/// accepts asset resolution (§6.12), and a host that wires none is still
/// conformant: it declares an empty set and every affected widget reports
/// through its `onError`.
enum RuntimeCapability {
  /// `sound.play` / `sound.stop` (§4.9a).
  sound,

  /// `mediaPlayer` with `mediaType: audio` (§10.6).
  audio,

  /// `mediaPlayer` with `mediaType: video` (§10.6).
  video,

  /// `webView` (§10.x).
  webView,

  /// `pdfViewer`.
  pdf,

  /// `map`.
  map,

  /// `lottieAnimation`.
  lottie,
}

/// Reads the bytes behind an asset the host cannot open by URI — a sound
/// inside a bundle, one served by an origin, one the client holds.
///
/// The runtime resolves it through the same [AssetResolver] that already makes
/// `bundle://` images work; returning null means the bytes could not be read.
typedef AssetBytesReader = Future<Uint8List?> Function();

/// One sound playback requested by `sound.play`.
class SoundRequest {
  const SoundRequest({
    required this.source,
    required this.readBytes,
    this.volume = 1.0,
    this.id,
    this.loop = false,
  });

  /// Already-resolved reference — the runtime resolves bindings and scheme
  /// (§6.12.2) before the host is asked to play anything.
  final AssetRef source;

  /// Bytes for the forms a platform player cannot take by URI. A bundled sound
  /// is the normal case, not an exotic one: an author who ships a picture with
  /// their app ships the beep the same way, and an image that works beside a
  /// sound that does not is the drift this closes.
  final AssetBytesReader readBytes;
  final double volume;

  /// Names this playback so `sound.stop` can end it.
  final String? id;
  final bool loop;
}

/// Plays short sounds. Overlapping is required by §4.9a: a click during an
/// alarm is both sounds, not the last one.
abstract class SoundPort {
  Future<void> play(SoundRequest request);

  /// Stops the playback named [id], or every sound this document started when
  /// [id] is null.
  Future<void> stop({String? id});
}

/// A media playback the runtime drives from the transport UI.
abstract class MediaSession {
  Stream<Duration> get position;

  /// Total length once known; null while it is not.
  Stream<Duration?> get duration;

  /// True while sound/pictures are actually being produced — not while the UI
  /// merely thinks so.
  Stream<bool> get playing;

  /// Playback reached the end (never fired for a looping session).
  Stream<void> get ended;

  /// Playback failed after it started (a stream died, a decode error).
  Stream<Object> get errors;

  /// Amplitude samples for `mediaPlayer.waveform`, or null when this host
  /// cannot produce them. Null is an answer the widget reports (§6.13.2) —
  /// accepting `waveform: true` and drawing nothing is not.
  Stream<List<double>>? get waveform => null;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setMuted(bool muted);
  Future<void> dispose();
}

/// Opens media. Throws to report that this source cannot be played — the
/// widget turns that into `onError`, never into a rendered message (§6.13.2).
abstract class MediaPort {
  Future<MediaSession> open({
    required AssetRef source,
    required AssetBytesReader readBytes,
    required bool isVideo,
    /// The document asked for `mediaPlayer.waveform`. Producing amplitude data
    /// costs a full read and decode, so a host only pays it when asked; when it
    /// cannot produce it anyway the session leaves [MediaSession.waveform] null
    /// and the widget reports the absence.
    bool wantsWaveform = false,
    bool loop = false,
    bool muted = false,
    double volume = 1.0,
  });

  /// The surface a video session draws into. Null for audio-only ports; a
  /// widget that asks for video from such a port reports the capability absent
  /// rather than drawing an empty frame.
  Widget? videoSurface(MediaSession session);
}

/// How a host surface reports back into the document. A hosted web view still
/// has to fire the `onPageFinished` the author wrote, and a hosted PDF still has
/// to report a page change — without this the host draws content the document
/// cannot react to, which is a different way of being disconnected from the
/// truth.
class SurfaceEvents {
  const SurfaceEvents(this._emit);

  final void Function(String name, Map<String, dynamic> payload) _emit;

  /// Fires the widget's declared action for [name] (`onPageFinished`,
  /// `onError`, …) with `event` bound to [payload].
  void emit(String name, [Map<String, dynamic> payload = const {}]) =>
      _emit(name, payload);
}

/// What a hosted surface is given besides its properties: the way to read an
/// asset it cannot fetch by URI.
///
/// A PDF, a Lottie file or a page's HTML can live inside a bundle exactly as an
/// image does. Handing the surface only a URI would make `bundle://` work for
/// pictures and fail for everything else, which is a difference the author
/// never asked for and cannot see coming.
class SurfaceAssets {
  const SurfaceAssets(this._read);

  final Future<Uint8List?> Function(AssetRef ref) _read;

  /// Bytes for [ref], or null when they cannot be read.
  Future<Uint8List?> read(AssetRef ref) => _read(ref);
}

/// Builds a platform surface for a widget the runtime cannot draw itself.
/// Returning null is the same statement as not being wired: the capability is
/// absent, and the widget reports it.
typedef SurfaceBuilder = Widget? Function(
  BuildContext context,
  Map<String, dynamic> properties,
  SurfaceEvents events,
  SurfaceAssets assets,
);

/// The set of behaviours this runtime can actually perform, and the objects
/// that perform them.
///
/// [declared] is the published capability set (§6.13.2) — what a host embedding
/// this runtime can read to know what its documents will get. It is derived
/// from what was wired, so it cannot drift from the truth by being edited.
class RuntimeCapabilities {
  const RuntimeCapabilities({
    this.sound,
    this.media,
    this.webViewBuilder,
    this.pdfBuilder,
    this.mapBuilder,
    this.lottieBuilder,
    this.mediaSupportsVideo = false,
  });

  /// A runtime with no platform powers wired. Conformant: it declares nothing
  /// and every affected widget reports through `onError`.
  static const RuntimeCapabilities none = RuntimeCapabilities();

  final SoundPort? sound;
  final MediaPort? media;
  final SurfaceBuilder? webViewBuilder;
  final SurfaceBuilder? pdfBuilder;
  final SurfaceBuilder? mapBuilder;
  final SurfaceBuilder? lottieBuilder;

  /// Whether [media] decodes video as well as audio. Separate because the
  /// common embedded case is audio-only, and a video widget must be able to
  /// tell that apart from "no media at all".
  final bool mediaSupportsVideo;

  Set<RuntimeCapability> get declared => {
        if (sound != null) RuntimeCapability.sound,
        if (media != null) RuntimeCapability.audio,
        if (media != null && mediaSupportsVideo) RuntimeCapability.video,
        if (webViewBuilder != null) RuntimeCapability.webView,
        if (pdfBuilder != null) RuntimeCapability.pdf,
        if (mapBuilder != null) RuntimeCapability.map,
        if (lottieBuilder != null) RuntimeCapability.lottie,
      };

  bool supports(RuntimeCapability capability) =>
      declared.contains(capability);
}

/// Raised when a document asks for a behaviour this runtime does not have.
/// Carried to the widget's `onError` and the diagnostic channel — never
/// rendered in place of the content (§6.13.2).
class CapabilityUnavailable implements Exception {
  const CapabilityUnavailable(this.capability, {this.detail});

  final RuntimeCapability capability;
  final String? detail;

  @override
  String toString() => 'capability unavailable: ${capability.name}'
      '${detail == null ? '' : ' ($detail)'}';
}
