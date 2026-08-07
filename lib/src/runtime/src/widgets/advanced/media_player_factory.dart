import 'package:flutter/material.dart';
import 'dart:async';
import '../../assets/asset_ref.dart';
import '../../capabilities/runtime_capabilities.dart';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Media Player widgets (Advanced conformance level)
/// Implements a functional media player UI with controls
/// Playback is performed by the host's [MediaPort] (spec §6.13). With none
/// wired this widget draws no transport and reports through `onError` — it
/// never advances a position bar over silence.
/// Audio or video, read from the source's extension.
///
/// Unknown stays `video`: that is what this widget did for every source before
/// inference existed, and a stream with no extension is more often a video.
String _inferMediaType(String? source) {
  if (source == null) return 'video';
  final path = source.split('?').first.toLowerCase();
  const audio = <String>[
    '.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.oga', '.opus', '.wma',
    '.aiff', '.aif', '.mid', '.midi',
  ];
  for (final ext in audio) {
    if (path.endsWith(ext)) return 'audio';
  }
  if (path.startsWith('data:audio/')) return 'audio';
  return 'video';
}

class MediaPlayerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract media player properties - support design doc keys and implementation keys
    // Design: src → Implementation: source
    final source = context.resolve<String?>(properties['src'] ?? properties['source']);
    // §10.6 declares the default `inferred`, and this read `video` — so a
    // document that pointed at an mp3 and said nothing asked the host for the
    // VIDEO capability and got a black rectangle with sound. Absent means
    // inferred from the source, which is what the word says; declared still
    // wins, so nothing that named its kind changes.
    final declaredType = context.resolve<String?>(
        properties['type'] ?? properties['mediaType']);
    final mediaType = (declaredType == null || declaredType.isEmpty)
        ? _inferMediaType(context.resolve<String?>(properties['source']))
        : declaredType;
    // Spec §10.6 canonical `autoPlay`; `autoplay` kept as lowercase legacy.
    final autoplay = context.resolve<bool>(
        properties['autoPlay'] ?? properties['autoplay'] ?? false);
    final volume = (dimensionOf(properties['volume'], context))?.toDouble() ?? 1.0;
    final onTimeUpdate = actionOf(properties['onTimeUpdate'], context);
    final onErrorAction = actionOf(properties['onError'], context);
    final controls = context.resolve<bool>(properties['controls'] ?? true);
    final loop = context.resolve<bool>(properties['loop'] ?? false);
    final muted = context.resolve<bool>(properties['muted'] ?? false);
    // Spec §10.6 — `waveform` (audio only). Drawn from the host's amplitude
    // data; reported absent when the host has none.
    final wantsWaveform = context.resolve<bool>(properties['waveform'] ?? false);
    final playerId = context.resolve<String?>(properties['id']);
    final poster = context.resolve<String?>(properties['poster']);
    final title = context.resolve<String?>(properties['title']);
    final duration =
        parseDimension(context.resolve((properties['duration']))) ?? 180.0;
    final width = parseDimension(context.resolve((properties['width'])));
    final height = parseDimension(context.resolve((properties['height']))) ?? 300.0;

    // Extract colors
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context) ??
            Colors.black;
    final controlsColor =
        parseColor(context.resolve(properties['controlsColor']), context) ?? Colors.white;
    final accentColor =
        parseColor(context.resolve(properties['accentColor']), context) ?? Colors.blue;

    // Extract action handlers
    final onPlay = actionOf(properties['onPlay'], context);
    final onPause = actionOf(properties['onPause'], context);
    final onEnded = actionOf(properties['onEnded'], context);
    final onSeek = actionOf(properties['onSeek'], context);

    // Build media player widget
    Widget player = _MediaPlayerWidget(
      source: source,
      mediaType: mediaType,
      autoplay: autoplay,
      controls: controls,
      loop: loop,
      muted: muted,
      poster: poster,
      title: title,
      duration: duration,
      backgroundColor: backgroundColor,
      controlsColor: controlsColor,
      accentColor: accentColor,
      onPlay: onPlay,
      onPause: onPause,
      onEnded: onEnded,
      onSeek: onSeek,
      onTimeUpdate: onTimeUpdate,
      onError: onErrorAction,
      playerId: playerId,
      wantsWaveform: wantsWaveform,
      volume: volume,
      context: context,
    );

    player = SizedBox(
      width: width,
      height: height,
      child: player,
    );

    return applyCommonWrappers(player, properties, context);
  }
}

/// Stateful media player widget
class _MediaPlayerWidget extends StatefulWidget {
  final String? source;
  final String mediaType;
  final bool autoplay;
  final bool controls;
  final bool loop;
  final bool muted;
  final String? poster;
  final String? title;
  final double duration;
  final Color backgroundColor;
  final Color controlsColor;
  final Color accentColor;
  final Map<String, dynamic>? onPlay;
  final Map<String, dynamic>? onPause;
  final Map<String, dynamic>? onEnded;
  final Map<String, dynamic>? onSeek;
  final Map<String, dynamic>? onTimeUpdate;
  final Map<String, dynamic>? onError;

  /// Names this player for §4.9b media actions. Null when the document did not
  /// name it — such a player can only be driven by its own controls.
  final String? playerId;

  /// The document asked for a waveform. Whether one can be drawn depends on
  /// the host supplying amplitude data (§10.6).
  final bool wantsWaveform;
  final double volume;
  final RenderContext context;

  const _MediaPlayerWidget({
    this.source,
    required this.mediaType,
    required this.autoplay,
    required this.controls,
    required this.loop,
    required this.muted,
    this.poster,
    this.title,
    required this.duration,
    required this.backgroundColor,
    required this.controlsColor,
    required this.accentColor,
    this.onPlay,
    this.onPause,
    this.onEnded,
    this.onSeek,
    this.onTimeUpdate,
    this.onError,
    this.playerId,
    this.wantsWaveform = false,
    this.volume = 1.0,
    required this.context,
  });

  @override
  State<_MediaPlayerWidget> createState() => _MediaPlayerWidgetState();
}

class _MediaPlayerWidgetState extends State<_MediaPlayerWidget> {
  bool _isPlaying = false;
  bool _isMuted = false;
  double _volume = 1.0;
  double _currentPosition = 0.0;
  bool _showControls = true;
  bool _isFullscreen = false;
  Timer? _hideControlsTimer;

  /// The real playback. Null while opening, and forever when this runtime has
  /// no media capability — in which case nothing is drawn that suggests
  /// otherwise (spec §6.13.1).
  MediaSession? _session;
  /// Amplitude envelope, once the host has produced one.
  List<double>? _peaks;
  final List<StreamSubscription<dynamic>> _sessionSubs = [];
  bool _unavailable = false;
  double _durationSeconds = 0.0;

  @override
  void initState() {
    super.initState();
    _isMuted = widget.muted;
    _volume = widget.volume;
    _openSession();
  }

  bool get _wantsVideo => widget.mediaType.toLowerCase() != 'audio';

  Future<void> _openSession() async {
    final caps = widget.context.capabilities;
    final needed =
        _wantsVideo ? RuntimeCapability.video : RuntimeCapability.audio;
    final ref = AssetRef.parse(widget.source);

    if (ref == null) {
      _reportUnavailable(const CapabilityUnavailable(RuntimeCapability.audio,
          detail: 'source is not an asset reference'));
      return;
    }
    if (caps.media == null || !caps.supports(needed)) {
      // §6.13.2 — the absence is a capability fact reported to the document,
      // never a message drawn where the media belongs.
      _reportUnavailable(CapabilityUnavailable(needed));
      return;
    }

    try {
      final session = await caps.media!.open(
        source: ref,
        readBytes: () => widget.context.assetResolver.bytesFor(ref),
        isVideo: _wantsVideo,
        wantsWaveform: widget.wantsWaveform,
        loop: widget.loop,
        muted: widget.muted,
        volume: widget.volume,
      );
      if (!mounted) {
        await session.dispose();
        return;
      }
      _session = session;
      final id = widget.playerId;
      if (id != null && id.isNotEmpty) {
        widget.context.mediaRegistry?.register(id, session);
      }
      // §10.6 — a waveform needs per-sample amplitude, which only the host can
      // produce. Accepting the property and drawing nothing is what §6.13.1
      // forbids, so an unmet request is reported once.
      final waveform = session.waveform;
      if (widget.wantsWaveform && waveform == null) {
        _reportError(const CapabilityUnavailable(RuntimeCapability.audio,
            detail: 'waveform data'));
      } else if (widget.wantsWaveform && waveform != null) {
        _sessionSubs.add(waveform.listen((peaks) {
          if (mounted) setState(() => _peaks = peaks);
        }));
      }
      _sessionSubs.addAll([
        session.position.listen((p) {
          if (mounted) setState(() => _currentPosition = p.inMilliseconds / 1000);
          // §4.9b — an author building their own scrubber has no other way to
          // know where playback is.
          _emitTimeUpdate(p);
        }),
        session.duration.listen((d) {
          if (mounted && d != null) {
            setState(() => _durationSeconds = d.inMilliseconds / 1000);
          }
        }),
        session.playing.listen((p) {
          if (mounted) setState(() => _isPlaying = p);
          _triggerEvent(p ? widget.onPlay : widget.onPause);
        }),
        session.ended.listen((_) => _triggerEvent(widget.onEnded)),
        session.errors.listen(_reportError),
      ]);
      if (widget.autoplay) await session.play();
      if (mounted) setState(() {});
    } catch (e) {
      _reportUnavailable(e);
    }
  }

  void _reportUnavailable(Object error) {
    // After the frame: the capability check runs inside initState, and both
    // setState and firing the document's `onError` would otherwise land while
    // the tree is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _unavailable = true);
      _reportError(error);
    });
  }

  void _emitTimeUpdate(Duration position) {
    final action = widget.onTimeUpdate;
    if (action == null) return;
    final child = widget.context.createChildContext(
      variables: {
        'event': {
          'currentTime': position.inMilliseconds / 1000,
          'duration': _effectiveDuration,
        },
      },
    );
    widget.context.actionHandler.execute(action, child);
  }

  void _reportError(Object error) {
    final onError = widget.onError;
    if (onError == null) return;
    final eventContext = widget.context.createChildContext(
      variables: {'event': {'error': error.toString()}},
    );
    widget.context.actionHandler.execute(onError, eventContext);
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    for (final sub in _sessionSubs) {
      sub.cancel();
    }
    final id = widget.playerId;
    final session = _session;
    if (id != null && id.isNotEmpty && session != null) {
      widget.context.mediaRegistry?.unregister(id, session);
    }
    session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAudio = widget.mediaType.toLowerCase() == 'audio';

    // §6.13.1/§6.13.2 — with no capability there is no player. Not a transport
    // that cannot transport, and not a box reading "unsupported": the failure
    // went to `onError` and the diagnostic channel. A declared `poster` is the
    // author's own content, so it still shows.
    if (_unavailable) {
      final poster = widget.poster;
      if (!isAudio && poster != null && poster.isNotEmpty) {
        final image = widget.context.resolveAssetImage(poster);
        if (image != null) {
          return Image(image: image, fit: BoxFit.contain);
        }
      }
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: _toggleControlsVisibility,
      child: Container(
        decoration: BoxDecoration(
          color: widget.backgroundColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Media display area
              _buildMediaDisplay(isAudio),

              // Controls overlay
              if (widget.controls)
                AnimatedOpacity(
                  opacity: _showControls ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: _buildControlsOverlay(isAudio),
                ),

              // Status badges
              _buildStatusBadges(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMediaDisplay(bool isAudio) {
    if (isAudio) {
      return _buildAudioDisplay();
    } else {
      return _buildVideoDisplay();
    }
  }

  Widget _buildAudioDisplay() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            widget.accentColor.withValues(alpha: 0.3),
            widget.backgroundColor,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // The waveform when the document asked for one and the host
            // produced it — drawing the artwork square over real amplitude
            // data would accept the property and show nothing (§6.13.1).
            if (_peaks != null)
              SizedBox(
                height: 96,
                width: double.infinity,
                child: CustomPaint(
                  painter: _WaveformPainter(
                    peaks: _peaks!,
                    progress: _durationSeconds > 0
                        ? (_currentPosition / _durationSeconds).clamp(0.0, 1.0)
                        : 0.0,
                    played: widget.accentColor,
                    remaining: widget.controlsColor.withValues(alpha: 0.35),
                  ),
                ),
              )
            else
            // Album art or music icon
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: widget.accentColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Icon(
                Icons.music_note,
                size: 60,
                color: widget.controlsColor.withValues(alpha: 0.8),
              ),
            ),
            const SizedBox(height: 24),
            // Title
            if (widget.title != null)
              Text(
                widget.title!,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: widget.controlsColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            // Source info
            if (widget.source != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _getFileName(widget.source!),
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.controlsColor.withValues(alpha: 0.6),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoDisplay() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Video placeholder or poster
        if (widget.poster != null)
          Image.network(
            widget.poster!,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) =>
                _buildVideoPlaceholder(),
          )
        else
          _buildVideoPlaceholder(),

        // Play button overlay when paused
        if (!_isPlaying)
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(
                  Icons.play_arrow,
                  size: 48,
                  color: widget.controlsColor,
                ),
                onPressed: _play,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildVideoPlaceholder() {
    return Container(
      color: widget.backgroundColor,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.videocam,
              size: 48,
              color: widget.controlsColor.withValues(alpha: 0.3),
            ),
            if (widget.title != null) ...[
              const SizedBox(height: 12),
              Text(
                widget.title!,
                style: TextStyle(
                  fontSize: 14,
                  color: widget.controlsColor.withValues(alpha: 0.6),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildControlsOverlay(bool isAudio) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: 0.7),
          ],
          stops: const [0.0, 0.5, 1.0],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          // Progress bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _buildProgressBar(),
          ),
          const SizedBox(height: 4),
          // Time display
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(_currentPosition),
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.controlsColor.withValues(alpha: 0.8),
                  ),
                ),
                Text(
                  _formatDuration(_effectiveDuration),
                  style: TextStyle(
                    fontSize: 12,
                    color: widget.controlsColor.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Control buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Skip backward
                IconButton(
                  icon: Icon(Icons.replay_10, color: widget.controlsColor),
                  onPressed: () => _seek(_currentPosition - 10),
                  iconSize: 28,
                ),
                // Play/Pause
                Container(
                  decoration: BoxDecoration(
                    color: widget.accentColor,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: Icon(
                      _isPlaying ? Icons.pause : Icons.play_arrow,
                      color: widget.controlsColor,
                    ),
                    onPressed: _togglePlayPause,
                    iconSize: 32,
                  ),
                ),
                // Skip forward
                IconButton(
                  icon: Icon(Icons.forward_10, color: widget.controlsColor),
                  onPressed: () => _seek(_currentPosition + 10),
                  iconSize: 28,
                ),
                // Volume
                _buildVolumeControl(),
                // Fullscreen (video only)
                if (!isAudio)
                  IconButton(
                    icon: Icon(
                      _isFullscreen
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                      color: widget.controlsColor,
                    ),
                    onPressed: _toggleFullscreen,
                    iconSize: 28,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar() {
    final progress = _effectiveDuration > 0
        ? (_currentPosition / _effectiveDuration).clamp(0.0, 1.0)
        : 0.0;

    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: widget.accentColor,
        inactiveTrackColor: widget.controlsColor.withValues(alpha: 0.3),
        thumbColor: widget.accentColor,
        overlayColor: widget.accentColor.withValues(alpha: 0.3),
      ),
      child: Slider(
        value: progress,
        onChanged: (value) {
          _seek(value * _effectiveDuration);
        },
      ),
    );
  }

  Widget _buildVolumeControl() {
    return PopupMenuButton<double>(
      icon: Icon(
        _isMuted || _volume == 0
            ? Icons.volume_off
            : _volume < 0.5
                ? Icons.volume_down
                : Icons.volume_up,
        color: widget.controlsColor,
      ),
      itemBuilder: (context) => [
        PopupMenuItem(
          enabled: false,
          child: SizedBox(
            width: 150,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Volume'),
                    Text('${(_volume * 100).toInt()}%'),
                  ],
                ),
                Slider(
                  value: _volume,
                  onChanged: (value) {
                    setState(() {
                      _volume = value;
                      _isMuted = value == 0;
                    });
                    Navigator.pop(context);
                  },
                  activeColor: widget.accentColor,
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isMuted = !_isMuted;
                    });
                    Navigator.pop(context);
                  },
                  child: Text(_isMuted ? 'Unmute' : 'Mute'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusBadges() {
    return Positioned(
      top: 8,
      right: 8,
      child: Row(
        children: [
          if (_isPlaying)
            _buildBadge('Playing', Colors.green),
          if (widget.loop) ...[
            const SizedBox(width: 4),
            _buildBadge('Loop', Colors.blue),
          ],
          if (_isMuted) ...[
            const SizedBox(width: 4),
            _buildBadge('Muted', Colors.orange),
          ],
        ],
      ),
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 10,
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  void _play() {
    final session = _session;
    if (session == null) return; // nothing is playing, so nothing is shown as playing
    unawaited(session.play());
  }

  void _pause() {
    final session = _session;
    if (session == null) return;
    unawaited(session.pause());
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _pause();
    } else {
      _play();
    }
  }

  void _seek(double position) {
    final session = _session;
    final max = _durationSeconds > 0 ? _durationSeconds : widget.duration;
    final target = position.clamp(0.0, max);
    if (session == null) return;
    unawaited(session.seek(Duration(milliseconds: (target * 1000).round())));

    if (widget.onSeek != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {'position': target, 'duration': max},
        },
      );
      widget.context.actionHandler.execute(widget.onSeek!, eventContext);
    }
  }

  void _toggleFullscreen() {
    setState(() {
      _isFullscreen = !_isFullscreen;
    });
  }

  void _toggleControlsVisibility() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      _resetHideControlsTimer();
    }
  }

  void _resetHideControlsTimer() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 3), () {
      if (_isPlaying) {
        setState(() {
          _showControls = false;
        });
      }
    });
  }

  void _triggerEvent(Map<String, dynamic>? action) {
    if (action != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'position': _currentPosition,
            'duration': widget.duration,
            'isPlaying': _isPlaying,
            'volume': _volume,
            'isMuted': _isMuted,
          },
        },
      );
      widget.context.actionHandler.execute(action, eventContext);
    }
  }

  /// What the platform reported, falling back to the declared `duration` only
  /// while nothing has been reported yet.
  double get _effectiveDuration =>
      _durationSeconds > 0 ? _durationSeconds : widget.duration;

  String _formatDuration(double seconds) {
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor();
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String _getFileName(String path) {
    final parts = path.split('/');
    return parts.last;
  }
}

/// Draws the amplitude envelope the host produced, with the played part in
/// the accent colour.
///
/// Bars rather than a filled curve: a waveform is read for where the loud
/// parts are, and bars keep that legible at any width without smoothing the
/// peaks away.
class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.played,
    required this.remaining,
  });

  final List<double> peaks;
  final double progress;
  final Color played;
  final Color remaining;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0) return;
    final slot = size.width / peaks.length;
    final barWidth = slot * 0.6;
    final mid = size.height / 2;
    final playedUpTo = size.width * progress;
    final paint = Paint()..strokeCap = StrokeCap.round;
    for (var i = 0; i < peaks.length; i++) {
      final x = slot * i + slot / 2;
      // A silent bucket still gets a hairline: a gap in the middle of a
      // waveform reads as missing data rather than as quiet.
      final half = (peaks[i].clamp(0.0, 1.0) * mid).clamp(1.0, mid);
      paint.color = x <= playedUpTo ? played : remaining;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x - barWidth / 2, mid - half, x + barWidth / 2,
              mid + half),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.peaks != peaks ||
      old.played != played ||
      old.remaining != remaining;
}
