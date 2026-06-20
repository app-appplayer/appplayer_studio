import 'package:flutter/material.dart';
import 'dart:async';
import '../../renderer/render_context.dart';
import '../widget_factory.dart';

/// Factory for Media Player widgets (Advanced conformance level)
/// Implements a functional media player UI with controls
/// Actual playback requires platform integration
class MediaPlayerWidgetFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    // Extract media player properties - support design doc keys and implementation keys
    // Design: src → Implementation: source
    final source = context.resolve<String?>(properties['src'] ?? properties['source']);
    // Design: type → Implementation: mediaType
    final mediaType =
        context.resolve<String>(properties['type'] ?? properties['mediaType'] ?? 'video');
    // Spec §10.6 canonical `autoPlay`; `autoplay` kept as lowercase legacy.
    final autoplay = context.resolve<bool>(
        properties['autoPlay'] ?? properties['autoplay'] ?? false);
    // ignore: unused_local_variable
    final volume = (properties['volume'] as num?)?.toDouble();
    // ignore: unused_local_variable
    final onTimeUpdate = properties['onTimeUpdate'] as Map<String, dynamic>?;
    // ignore: unused_local_variable
    final onErrorAction = properties['onError'] as Map<String, dynamic>?;
    final controls = context.resolve<bool>(properties['controls'] ?? true);
    final loop = context.resolve<bool>(properties['loop'] ?? false);
    final muted = context.resolve<bool>(properties['muted'] ?? false);
    // Spec § mediaPlayer v1.3 — `waveform` (audio mode only). Read
    // so the resolver records the author's intent; the actual
    // waveform rendering ships in a later runtime cycle.
    final _ = context.resolve(properties['waveform']);
    final poster = context.resolve<String?>(properties['poster']);
    final title = context.resolve<String?>(properties['title']);
    final duration =
        context.resolve<double?>(properties['duration']) ?? 180.0;
    final width = context.resolve<double?>(properties['width']);
    final height = context.resolve<double?>(properties['height']) ?? 300.0;

    // Extract colors
    final backgroundColor =
        parseColor(context.resolve(properties['backgroundColor']), context) ??
            Colors.black;
    final controlsColor =
        parseColor(context.resolve(properties['controlsColor']), context) ?? Colors.white;
    final accentColor =
        parseColor(context.resolve(properties['accentColor']), context) ?? Colors.blue;

    // Extract action handlers
    final onPlay = properties['onPlay'] as Map<String, dynamic>?;
    final onPause = properties['onPause'] as Map<String, dynamic>?;
    final onEnded = properties['onEnded'] as Map<String, dynamic>?;
    final onSeek = properties['onSeek'] as Map<String, dynamic>?;

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
  Timer? _playbackTimer;

  @override
  void initState() {
    super.initState();
    _isMuted = widget.muted;
    if (widget.autoplay) {
      _play();
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _playbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isAudio = widget.mediaType.toLowerCase() == 'audio';

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
                  _formatDuration(widget.duration),
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
    final progress = widget.duration > 0
        ? (_currentPosition / widget.duration).clamp(0.0, 1.0)
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
          _seek(value * widget.duration);
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
    setState(() {
      _isPlaying = true;
    });

    // Simulate playback progression
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!_isPlaying) {
        timer.cancel();
        return;
      }

      setState(() {
        _currentPosition += 0.1;
        if (_currentPosition >= widget.duration) {
          if (widget.loop) {
            _currentPosition = 0;
          } else {
            _isPlaying = false;
            _currentPosition = widget.duration;
            timer.cancel();
            _triggerEvent(widget.onEnded);
          }
        }
      });
    });

    _triggerEvent(widget.onPlay);
    _resetHideControlsTimer();
  }

  void _pause() {
    setState(() {
      _isPlaying = false;
    });
    _playbackTimer?.cancel();
    _triggerEvent(widget.onPause);
  }

  void _togglePlayPause() {
    if (_isPlaying) {
      _pause();
    } else {
      _play();
    }
  }

  void _seek(double position) {
    setState(() {
      _currentPosition = position.clamp(0.0, widget.duration);
    });

    if (widget.onSeek != null) {
      final eventContext = widget.context.createChildContext(
        variables: {
          'event': {
            'position': _currentPosition,
            'duration': widget.duration,
          },
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
