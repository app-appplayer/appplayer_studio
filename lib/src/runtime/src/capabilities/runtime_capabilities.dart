import 'dart:async';

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../assets/asset_ref.dart';

/// Behaviours a document can ask for that the runtime cannot perform on its
/// own: sound comes out, media decodes, a page loads, a document paginates,
/// tiles are fetched, a vector animation plays.
///
/// A runtime either performs a declared behaviour or reports that
/// it cannot. It never draws a facsimile of the behaviour succeeding. These are
/// platform powers, so the runtime accepts them from its embedder exactly as it
/// accepts asset resolution, and a host that wires none is still
/// conformant: it declares an empty set and every affected widget reports
/// through its `onError`.
enum RuntimeCapability {
  /// `sound.play` / `sound.stop`.
  sound,

  /// `mediaPlayer` with `mediaType: audio`.
  audio,

  /// `mediaPlayer` with `mediaType: video`.
  video,

  /// `webView`.
  webView,

  /// `pdfViewer`.
  pdf,

  /// `map`.
  map,

  /// `lottieAnimation`.
  lottie,

  /// `payment`.
  payment,

  /// `location`.
  location,
}

/// What a host reports back for a payment.
///
/// [success] means the person came back from the payment surface. It is not
/// proof of payment — it must never be treated as one — and a host that
/// failed after presenting the surface reports [unknown] rather than a
/// failure, because it cannot say the money did not move.
enum PaymentOutcome {
  success,
  cancel,
  unknown,
  unavailable,

  /// The payment completed, but what was paid for did not reach the party
  /// that has to act on it — a device that never received the authority the
  /// order bought. Distinct from every other
  /// failure because a different party has to put it right: the money moved.
  deliveryFailed,
}

/// One payment requested by `{"type": "payment"}`.
///
/// Carries what the document declared and nothing else. The payment address,
/// the surface, the provider choice and the return address are all the host's
/// alone: a runtime that assembled them would be letting a rendered
/// document choose where money goes.
class PaymentRequest {
  const PaymentRequest({required this.itemId, this.seller, this.amount});

  /// The item as the payment surface knows it — a preselection, not a
  /// definition.
  final String itemId;

  /// The receiving party where the document named one, and **null where it did
  /// not**. Null is a statement, not a gap: a document served by a device does
  /// not name who is paid, and the host resolves that party by verifying the
  /// device's identity. A host that cannot resolve it answers
  /// [PaymentOutcome.unavailable] — never a default party.
  final String? seller;

  /// Set only where the document supplied one, already checked to be a
  /// positive number. Whether this item takes a customer-entered price is the
  /// payment surface's answer, not the runtime's; for every other
  /// item the surface derives the price and ignores this.
  final num? amount;
}

/// Takes payment for one item. Presenting the surface — a browser, a custom
/// tab, or a payment front end the host renders itself — is the host's choice
/// alone, as is minting and matching the per-request return token.
abstract class PaymentPort {
  Future<PaymentOutcome> checkout(PaymentRequest request);
}

/// How precise an answer a document needs.
///
/// A ceiling, not a preference: the host MAY answer coarser and MUST NOT
/// answer finer. Without that, a document collects precision by asking
/// quietly, and the ask is the only place anyone can weigh it.
enum LocationPrecision {
  /// Enough to say which area. The default, because most questions are.
  coarse,

  /// Enough to say which building. Asked for when the answer is the point —
  /// where an incident happened, which pump, which door.
  fine;

  static LocationPrecision fromWire(String? value) =>
      value == 'fine' ? LocationPrecision.fine : LocationPrecision.coarse;
}

/// Why a position could not be given.
enum LocationFailure {
  /// The person said no — now, or previously and the platform remembers.
  /// A normal outcome, not a fault to hide.
  denied,

  /// No port, the platform has it switched off, or no fix could be obtained.
  unavailable,
}

/// Where the device was, once.
class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.precision,
    required this.at,
  });

  final double latitude;
  final double longitude;

  /// How close this is, as the platform reported it. A host MUST NOT state an
  /// accuracy it did not measure — a confident number nobody checked is worse
  /// than an honest wide one.
  final double accuracyMeters;

  /// What actually arrived, which may be coarser than what was asked.
  final LocationPrecision precision;

  /// When the fix was taken. Carried because a position without a time cannot
  /// be told from a stale one.
  final DateTime at;
}

/// Answers where this device is, once.
///
/// The host owns the prompt: whether the person is asked, in what words, and
/// how the platform records the answer. There is no continuous form — a
/// document that could follow someone is a different power from one that can
/// ask where they are.
abstract class LocationPort {
  /// Answers a [LocationFix], or a [LocationFailure] saying why not.
  ///
  /// [precision] is the most this may answer with. Answering coarser is
  /// allowed and expected; answering finer is not.
  Future<Object> locate(LocationPrecision precision);
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
  /// before the host is asked to play anything.
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

/// Plays short sounds. Overlapping is required: a click during an
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
  /// cannot produce them. Null is an answer the widget reports —
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
/// widget turns that into `onError`, never into a rendered message.
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
/// [declared] is the published capability set — what a host embedding
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
    this.payment,
    this.location,
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

  /// Takes payment. A tier that wires none still renders documents;
  /// every `payment` action reports `PAYMENT_UNAVAILABLE` through `onError`.
  final PaymentPort? payment;

  /// Answers where this device is. Absent means the
  /// runtime does not claim the Profile, and `location` fails visibly.
  final LocationPort? location;

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
        if (payment != null) RuntimeCapability.payment,
        if (location != null) RuntimeCapability.location,
      };

  bool supports(RuntimeCapability capability) =>
      declared.contains(capability);
}

/// Raised when a document asks for a behaviour this runtime does not have.
/// Carried to the widget's `onError` and the diagnostic channel — never
/// rendered in place of the content.
class CapabilityUnavailable implements Exception {
  const CapabilityUnavailable(this.capability, {this.detail});

  final RuntimeCapability capability;
  final String? detail;

  @override
  String toString() => 'capability unavailable: ${capability.name}'
      '${detail == null ? '' : ' ($detail)'}';
}
