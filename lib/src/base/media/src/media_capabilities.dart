// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/host_media/lib/src/media_capabilities.dart
// Regenerate with debug/tool/sync_host_media_fork.sh.
// Runtime imports are rewritten to the studio's vendored runtime fork.
//
/// Implementations of the runtime's declared behaviours
/// (MCP UI DSL §6.13): sound, media playback, a web engine, PDF, vector
/// animation.
///
/// The runtime owns the widget, the transport UI, the asset reference and the
/// error routing; what it cannot do is decode audio or run a browser. Those are
/// platform powers, so they arrive from here — the same shape asset resolution
/// already used. A tier that wires fewer of them still renders documents; every
/// widget it cannot serve reports the absence rather than drawing a facsimile.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../../../runtime/flutter_mcp_ui_runtime.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:lottie/lottie.dart' as lottie;
import 'package:video_player/video_player.dart' as vp;
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:webview_flutter/webview_flutter.dart' as wv;

import 'local_bytes.dart';

/// Resolves an `AssetRef` to something a platform player can open.
///
/// Public because this is the decision worth testing on its own: which
/// reference forms this host can hand over, and which it must read first. The
/// players themselves need a device.
///
/// A URL or a `data:` payload goes straight through. Everything else — a sound
/// inside a bundle, one served by an origin, one the client holds — is READ and
/// re-offered as a `data:` URI, because those forms are exactly as normal for
/// audio as they already are for images. An author who ships a picture with
/// their app ships the beep the same way, and "the image appears but the sound
/// does not" is a difference nobody asked for.
Future<String> playableUri(AssetRef ref, AssetBytesReader readBytes) async {
  switch (ref.form) {
    case AssetForm.network:
    case AssetForm.data:
    case AssetForm.flutterAsset:
      return ref.uri;
    case AssetForm.bundle:
    case AssetForm.client:
    case AssetForm.origin:
      final bytes = await readBytes();
      if (bytes == null || bytes.isEmpty) {
        throw StateError('could not read ${ref.form.name} media: ${ref.uri}');
      }
      // Inlining costs the file twice over (bytes plus their base64), so a
      // large one is refused WITH A REASON rather than taken until the process
      // dies. Sound effects and short clips are the case this path serves; a
      // long video belongs behind a URL the player can stream.
      if (bytes.lengthInBytes > _maxInlineBytes) {
        throw StateError(
            '${ref.uri} is ${bytes.lengthInBytes ~/ (1024 * 1024)} MB — too '
            'large to inline; serve it over a URL the player can stream');
      }
      return _dataUri(bytes, ref.uri);
    default:
      // `file:` — what a host that installs bundles on disk hands over after
      // rewriting `bundle://` (§6.12.7 placement 1) — plays from its path.
      // Runtimes from 0.7.12 name it `AssetForm.file`; older ones file it
      // under `unknown`. A wildcard rather than named cases, so this adapter
      // compiles against both and a form added later is not a build break.
      if (ref.uri.startsWith('file:')) return ref.uri;
      final unknownBytes = await readBytes();
      if (unknownBytes == null || unknownBytes.isEmpty) {
        throw StateError('cannot play ${ref.uri}: unsupported reference');
      }
      if (unknownBytes.lengthInBytes > _maxInlineBytes) {
        throw StateError('${ref.uri} is too large to inline');
      }
      return _dataUri(unknownBytes, ref.uri);
  }
}

/// Ceiling on inlined media (16 MB). Chosen to comfortably hold sound effects
/// and short clips while refusing the file that would otherwise be held twice
/// in memory with no diagnosis.
const int _maxInlineBytes = 16 * 1024 * 1024;

/// Bytes as a `data:` URI. The MIME type is guessed from the reference's
/// extension: players are lenient, but a wrong container type is a decode
/// failure that reads as "the file is broken" rather than "we mislabelled it".
String _dataUri(Uint8List bytes, String hint) {
  final lower = hint.toLowerCase();
  final mime = lower.endsWith('.mp3')
      ? 'audio/mpeg'
      : lower.endsWith('.wav')
          ? 'audio/wav'
          : lower.endsWith('.m4a') || lower.endsWith('.aac')
              ? 'audio/aac'
              : lower.endsWith('.ogg') || lower.endsWith('.opus')
                  ? 'audio/ogg'
                  : lower.endsWith('.mp4') || lower.endsWith('.m4v')
                      ? 'video/mp4'
                      : lower.endsWith('.webm')
                          ? 'video/webm'
                          : lower.endsWith('.mov')
                              ? 'video/quicktime'
                              : 'application/octet-stream';
  return 'data:$mime;base64,${base64Encode(bytes)}';
}

// ---------------------------------------------------------------------------
// Sound effects — §4.9a
// ---------------------------------------------------------------------------

/// Short sounds, overlapping. §4.9a requires that a click during an alarm is
/// both sounds, so each playback gets its own player rather than sharing one
/// that would cut the previous off.
/// Amplitude envelope for `mediaPlayer.waveform`, or null when these bytes are
/// not something this host can decode without a platform decoder.
///
/// Public because this, like [playableUri], is the decision worth testing on
/// its own — it needs no device, and "what can this host actually produce a
/// waveform for" is the answer §10.6 makes the widget report either way.
///
/// Uncompressed PCM (RIFF/WAVE) is decoded here. Compressed audio is not: the
/// platform decoders that play mp3/aac expose no sample stream, and writing a
/// decoder to draw a picture of the sound would be a large amount of code for
/// one property. For those the answer is null, and the widget reports the
/// absence rather than drawing a shape that means nothing.
List<double>? waveformPeaks(Uint8List bytes, {int buckets = 256}) {
  final pcm = _pcmFromWav(bytes);
  if (pcm == null || pcm.isEmpty) return null;

  final n = buckets < 1 ? 1 : buckets;
  final per = pcm.length / n;
  final peaks = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final start = (i * per).floor();
    var end = ((i + 1) * per).floor();
    if (end <= start) end = start + 1;
    if (end > pcm.length) end = pcm.length;
    var peak = 0.0;
    for (var j = start; j < end; j++) {
      final v = pcm[j].abs();
      if (v > peak) peak = v;
    }
    peaks[i] = peak > 1.0 ? 1.0 : peak;
  }
  return peaks;
}

/// Samples in -1..1 from a RIFF/WAVE file, or null if this is not one, or is
/// one in a form we do not read (compressed contents, unknown bit depth).
///
/// Channels are averaged: a waveform is a picture of loudness over time, and
/// two channels drawn as one line is what every player shows.
List<double>? _pcmFromWav(Uint8List bytes) {
  if (bytes.lengthInBytes < 44) return null;
  final d = ByteData.sublistView(bytes);
  if (d.getUint32(0, Endian.big) != 0x52494646) return null; // "RIFF"
  if (d.getUint32(8, Endian.big) != 0x57415645) return null; // "WAVE"

  var format = 0, channels = 0, bits = 0;
  var offset = 12;
  while (offset + 8 <= bytes.lengthInBytes) {
    final id = d.getUint32(offset, Endian.big);
    final size = d.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (size > bytes.lengthInBytes - body) return null; // truncated
    if (id == 0x666d7420 && size >= 16) {
      // "fmt "
      format = d.getUint16(body, Endian.little);
      channels = d.getUint16(body + 2, Endian.little);
      bits = d.getUint16(body + 14, Endian.little);
    } else if (id == 0x64617461) {
      // "data"
      if (channels < 1) return null;
      return _decodeSamples(d, body, size, format, channels, bits);
    }
    offset = body + size + (size.isOdd ? 1 : 0); // chunks are word-aligned
  }
  return null;
}

List<double>? _decodeSamples(
  ByteData d,
  int start,
  int size,
  int format,
  int channels,
  int bits,
) {
  const pcmInt = 1, pcmFloat = 3, extensible = 0xFFFE;
  if (format != pcmInt && format != pcmFloat && format != extensible) {
    return null; // compressed contents in a WAV wrapper
  }
  final bytesPerSample = bits ~/ 8;
  if (bytesPerSample == 0) return null;
  final frame = bytesPerSample * channels;
  final frames = size ~/ frame;
  if (frames == 0) return null;

  final out = List<double>.filled(frames, 0);
  for (var f = 0; f < frames; f++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      final at = start + f * frame + c * bytesPerSample;
      double v;
      if (format == pcmFloat && bits == 32) {
        v = d.getFloat32(at, Endian.little);
      } else if (bits == 8) {
        v = (d.getUint8(at) - 128) / 128.0; // 8-bit WAV is unsigned
      } else if (bits == 16) {
        v = d.getInt16(at, Endian.little) / 32768.0;
      } else if (bits == 24) {
        final lo = d.getUint8(at) | (d.getUint8(at + 1) << 8);
        final hi = d.getInt8(at + 2);
        v = ((hi << 16) | lo) / 8388608.0;
      } else if (bits == 32) {
        v = d.getInt32(at, Endian.little) / 2147483648.0;
      } else {
        return null;
      }
      sum += v;
    }
    out[f] = sum / channels;
  }
  return out;
}

class JustAudioSoundPort implements SoundPort {
  JustAudioSoundPort({this.maxConcurrent = 8});

  /// Ceiling on simultaneous players. Sounds are short; without a ceiling a
  /// document in a loop could open players until the platform refuses, and the
  /// failure would land on whatever unlucky sound came next.
  final int maxConcurrent;

  final Map<String, ja.AudioPlayer> _named = {};
  final List<ja.AudioPlayer> _anonymous = [];

  @override
  Future<void> play(SoundRequest request) async {
    final player = ja.AudioPlayer();
    try {
      await player.setUrl(await playableUri(request.source, request.readBytes));
      await player.setVolume(request.volume.clamp(0.0, 1.0));
      if (request.loop) {
        await player.setLoopMode(ja.LoopMode.one);
      }

      final id = request.id;
      if (id != null && id.isNotEmpty) {
        // A second play under the same name replaces the first: the name is
        // how the document refers to one sound, not to a pile of them.
        await _named.remove(id)?.dispose();
        _named[id] = player;
      } else {
        _anonymous.add(player);
        // Over the ceiling, the OLDEST unnamed sound is dropped — it may still
        // be playing. That is the deliberate trade: an unnamed sound is by
        // definition one the document does not track, and the alternative is
        // opening players until the platform refuses, which would fail the
        // NEXT sound instead — the one someone is actually waiting to hear.
        while (_anonymous.length > maxConcurrent) {
          await _anonymous.removeAt(0).dispose();
        }
        // Anonymous sounds cannot be stopped by name, so they release
        // themselves when they finish.
        player.processingStateStream
            .firstWhere((s) => s == ja.ProcessingState.completed)
            .then((_) {
          _anonymous.remove(player);
          player.dispose();
        }).catchError((_) {});
      }
      await player.play();
    } catch (e) {
      await player.dispose();
      rethrow;
    }
  }

  @override
  Future<void> stop({String? id}) async {
    if (id != null && id.isNotEmpty) {
      await _named.remove(id)?.dispose();
      return;
    }
    final all = [..._named.values, ..._anonymous];
    _named.clear();
    _anonymous.clear();
    for (final p in all) {
      await p.dispose();
    }
  }
}

// ---------------------------------------------------------------------------
// Media playback — §10.6
// ---------------------------------------------------------------------------

class _JustAudioSession implements MediaSession {
  _JustAudioSession(this._player, {List<double>? peaks}) : _peaks = peaks;

  final ja.AudioPlayer _player;

  /// Computed once when the document asked for it and these bytes could be
  /// decoded; null otherwise, which is what the widget reports.
  final List<double>? _peaks;

  @override
  Stream<List<double>>? get waveform {
    final peaks = _peaks;
    if (peaks == null) return null;
    // A single value, not a live feed: the envelope of a file does not change
    // while it plays. `Stream.value` completes after delivering it, so a widget
    // that subscribes late still gets the picture.
    return Stream<List<double>>.value(peaks);
  }

  @override
  Stream<Duration> get position => _player.positionStream;

  @override
  Stream<Duration?> get duration => _player.durationStream;

  @override
  Stream<bool> get playing => _player.playingStream;

  @override
  Stream<void> get ended => _player.processingStateStream
      .where((s) => s == ja.ProcessingState.completed);

  @override
  Stream<Object> get errors {
    // The player reports failures as errors ON the event stream, not as
    // events. Transforming them into a stream of error VALUES is what lets the
    // widget route them to `onError`; swallowing them here would be the same
    // silence §6.13 exists to end — and it is easy to write by accident, which
    // is how the first draft of this file did exactly that.
    final out = StreamController<Object>.broadcast();
    _errorSub = _player.playbackEventStream.listen(
      (_) {},
      onError: (Object e, StackTrace _) => out.add(e),
    );
    out.onCancel = () => _errorSub?.cancel();
    return out.stream;
  }

  StreamSubscription<dynamic>? _errorSub;

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  @override
  Future<void> setMuted(bool muted) => _player.setVolume(muted ? 0 : 1);
  @override
  Future<void> dispose() async {
    await _errorSub?.cancel();
    await _player.dispose();
  }
}

class _VideoSession implements MediaSession {
  _VideoSession(this._controller) {
    _controller.addListener(_onTick);
  }

  final vp.VideoPlayerController _controller;
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _ended = StreamController<void>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  bool _wasPlaying = false;
  bool _wasEnded = false;
  Duration? _lastPosition;
  Duration? _lastDuration;
  String? _lastError;

  /// The controller notifies on every frame. Everything below is emitted only
  /// when it CHANGED — otherwise a document that writes state in `onTimeUpdate`
  /// is rebuilt sixty times a second for a value that did not move, and a
  /// single failure fires `onError` forever instead of once.
  void _onTick() {
    final v = _controller.value;

    if (v.position != _lastPosition) {
      _lastPosition = v.position;
      _position.add(v.position);
    }
    if (v.duration != _lastDuration) {
      _lastDuration = v.duration;
      _duration.add(v.duration);
    }
    if (v.isPlaying != _wasPlaying) {
      _wasPlaying = v.isPlaying;
      _playing.add(v.isPlaying);
    }
    if (v.isCompleted && !_wasEnded) {
      _wasEnded = true;
      _ended.add(null);
    } else if (!v.isCompleted) {
      _wasEnded = false;
    }
    final err = v.errorDescription;
    if (err != null && err != _lastError) {
      _lastError = err;
      _errors.add(err);
    }
  }

  vp.VideoPlayerController get controller => _controller;

  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration?> get duration => _duration.stream;
  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<void> get ended => _ended.stream;
  @override
  Stream<Object> get errors => _errors.stream;

  /// No amplitude data for video: `video_player` exposes frames, not samples.
  @override
  Stream<List<double>>? get waveform => null;

  @override
  Future<void> play() => _controller.play();
  @override
  Future<void> pause() => _controller.pause();
  @override
  Future<void> seek(Duration position) => _controller.seekTo(position);
  @override
  Future<void> setVolume(double volume) => _controller.setVolume(volume);
  @override
  Future<void> setMuted(bool muted) => _controller.setVolume(muted ? 0 : 1);

  @override
  Future<void> dispose() async {
    _controller.removeListener(_onTick);
    await _controller.dispose();
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _ended.close();
    await _errors.close();
  }
}

/// Audio through `just_audio`, video through `video_player`.
class PlatformMediaPort implements MediaPort {
  @override
  Future<MediaSession> open({
    required AssetRef source,
    required AssetBytesReader readBytes,
    required bool isVideo,
    bool wantsWaveform = false,
    bool loop = false,
    bool muted = false,
    double volume = 1.0,
  }) async {
    final uri = await playableUri(source, readBytes);
    if (!isVideo) {
      final player = ja.AudioPlayer();
      await player.setUrl(uri);
      await player.setLoopMode(loop ? ja.LoopMode.one : ja.LoopMode.off);
      await player.setVolume(muted ? 0 : volume.clamp(0.0, 1.0));
      // Only read and decode when the document asked: a waveform costs the
      // whole file, and most players never draw one.
      List<double>? peaks;
      if (wantsWaveform) {
        try {
          // `readBytes` covers the forms the runtime can reach; the file path
          // AppPlayer rewrites `bundle://` into is not one of them.
          final bytes = await readBytes() ?? await localFileBytes(source.uri);
          if (bytes != null) peaks = waveformPeaks(bytes);
        } catch (_) {
          // Unreadable source — the sound may still play. Null means the widget
          // reports the waveform absent, which is the honest answer here.
          peaks = null;
        }
      }
      return _JustAudioSession(player, peaks: peaks);
    }
    final controller = vp.VideoPlayerController.networkUrl(Uri.parse(uri));
    await controller.initialize();
    await controller.setLooping(loop);
    await controller.setVolume(muted ? 0 : volume.clamp(0.0, 1.0));
    return _VideoSession(controller);
  }

  @override
  Widget? videoSurface(MediaSession session) {
    if (session is! _VideoSession) return null;
    return vp.VideoPlayer(session.controller);
  }
}

// ---------------------------------------------------------------------------
// Surfaces — web view, PDF, vector animation
// ---------------------------------------------------------------------------

/// A real web engine. Page events are routed back to the document, so the
/// `onPageFinished` an author wrote fires when the page actually finished.
SurfaceBuilder webViewSurface() {
  return (context, properties, events, assets) {
    final url = properties['url'];
    final html = properties['html'];
    if (url is! String && html is! String) return null;

    final controller = wv.WebViewController()
      ..setJavaScriptMode(
        (properties['enableJavaScript'] as bool? ?? true)
            ? wv.JavaScriptMode.unrestricted
            : wv.JavaScriptMode.disabled,
      )
      ..setNavigationDelegate(
        wv.NavigationDelegate(
          // §10.18 `allowNavigation: false` pins the view to the page it was
          // given — the document decided that, and only the engine can
          // enforce it.
          onNavigationRequest: (request) {
            final allowed = properties['allowNavigation'] as bool? ?? true;
            if (allowed) return wv.NavigationDecision.navigate;
            events.emit('onNavigationBlocked', {'url': request.url});
            return wv.NavigationDecision.prevent;
          },
          onPageStarted: (u) => events.emit('onPageStarted', {'url': u}),
          onPageFinished: (u) => events.emit('onPageFinished', {'url': u}),
          onWebResourceError: (e) => events.emit('onError', {
            'code': e.errorCode,
            'message': e.description,
          }),
        ),
      );

    if (url is String) {
      controller.loadRequest(Uri.parse(url));
    } else {
      controller.loadHtmlString(html as String);
    }
    return wv.WebViewWidget(controller: controller);
  };
}

/// Vector animation. `lottie` renders Lottie JSON; a Rive file is not one and
/// is reported rather than drawn as an empty box.
SurfaceBuilder lottieSurface() {
  return (context, properties, events, assets) {
    final raw = properties['source'] ?? properties['src'];
    final ref = AssetRef.parse(raw);
    if (ref == null) return null;
    final loop = properties['loop'] as bool? ?? true;
    final autoPlay =
        properties['autoPlay'] as bool? ?? properties['autoplay'] as bool? ?? true;

    switch (ref.form) {
      case AssetForm.network:
        return lottie.Lottie.network(ref.uri, repeat: loop, animate: autoPlay);
      case AssetForm.flutterAsset:
        return lottie.Lottie.asset(ref.uri, repeat: loop, animate: autoPlay);
      default:
        // A bundled animation is as ordinary as a bundled image; read it.
        return _FromBytes(
          load: () => _assetBytes(ref, assets),
          build: (bytes) =>
              lottie.Lottie.memory(bytes, repeat: loop, animate: autoPlay),
          onError: (e) => events.emit('onError', {'message': e.toString()}),
        );
    }
  };
}

/// PDF rendering. A document the host cannot fetch is reported rather than
/// shown as an empty page — an empty page is indistinguishable from a document
/// that really is blank.

/// Bytes for [ref], through the runtime's resolver and — when that answers
/// nothing — the file system.
///
/// AppPlayer rewrites `bundle://` to an installed file path before the runtime
/// sees it, and the resolver has no reader for that form (it runs on the web
/// too). Playback did not care, because a player opens a path itself; anything
/// that needs the BYTES — a PDF, a Lottie file, a waveform — got null and drew
/// an empty box. The media port already goes through this; the surfaces did not.
@visibleForTesting
Future<Uint8List?> assetBytesForTest(AssetRef ref, SurfaceAssets assets) =>
    _assetBytes(ref, assets);

Future<Uint8List?> _assetBytes(AssetRef ref, SurfaceAssets assets) async {
  final bytes = await assets.read(ref);
  if (bytes != null && bytes.isNotEmpty) return bytes;
  return localFileBytes(ref.uri);
}

SurfaceBuilder pdfSurface() {
  return (context, properties, events, assets) {
    final ref = AssetRef.parse(properties['src'] ?? properties['source']);
    if (ref == null) return null;
    switch (ref.form) {
      case AssetForm.network:
        return pdfrx.PdfViewer.uri(
          Uri.parse(ref.uri),
          params: pdfrx.PdfViewerParams(
            onPageChanged: (page) =>
                events.emit('onPageChanged', {'page': page ?? 0}),
          ),
        );
      case AssetForm.flutterAsset:
        return pdfrx.PdfViewer.asset(
          ref.uri,
          params: pdfrx.PdfViewerParams(
            onPageChanged: (page) =>
                events.emit('onPageChanged', {'page': page ?? 0}),
          ),
        );
      default:
        return _FromBytes(
          load: () => _assetBytes(ref, assets),
          build: (bytes) => pdfrx.PdfViewer.data(
            bytes,
            sourceName: ref.uri,
            params: pdfrx.PdfViewerParams(
              onPageChanged: (page) =>
                  events.emit('onPageChanged', {'page': page ?? 0}),
            ),
          ),
          onError: (e) => events.emit('onError', {'message': e.toString()}),
        );
    }
  };
}

/// Renders content that has to be read first. Shows nothing while reading and
/// nothing on failure — the failure goes to the document's `onError`, never to
/// the screen (spec §6.13.2).
class _FromBytes extends StatefulWidget {
  const _FromBytes({
    required this.load,
    required this.build,
    required this.onError,
  });

  final Future<Uint8List?> Function() load;
  final Widget Function(Uint8List bytes) build;
  final void Function(Object error) onError;

  @override
  State<_FromBytes> createState() => _FromBytesState();
}

class _FromBytesState extends State<_FromBytes> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    widget.load().then((b) {
      if (!mounted) return;
      if (b == null || b.isEmpty) {
        widget.onError(StateError('asset could not be read'));
        return;
      }
      setState(() => _bytes = b);
    }).catchError((Object e) {
      if (mounted) widget.onError(e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return bytes == null ? const SizedBox.shrink() : widget.build(bytes);
  }
}
