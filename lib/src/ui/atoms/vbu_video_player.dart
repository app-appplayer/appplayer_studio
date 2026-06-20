/// Inline video player — wraps `package:video_player` with a tone-
/// matched control strip (play/pause toggle, scrub bar, time
/// readout). Used by Scene Builder's recordings preview and any
/// future surface that ships .mp4 / .webm output.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../tokens.dart';

class VbuVideoPlayer extends StatefulWidget {
  const VbuVideoPlayer({
    super.key,
    required this.src,
    this.autoplay = false,
    this.loop = false,
    this.showControls = true,
    this.aspectRatio,
  });

  /// Absolute file path (`/Users/...mp4`) or `file://` / `http(s)://`
  /// URL. Resolved via [VideoPlayerController.file] /
  /// [VideoPlayerController.networkUrl].
  final String src;

  final bool autoplay;
  final bool loop;
  final bool showControls;

  /// Override container aspect ratio. When null, matches the video's
  /// own `value.aspectRatio` once loaded.
  final double? aspectRatio;

  @override
  State<VbuVideoPlayer> createState() => _VbuVideoPlayerState();
}

class _VbuVideoPlayerState extends State<VbuVideoPlayer> {
  VideoPlayerController? _controller;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant VbuVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src) {
      _controller?.dispose();
      _ready = false;
      _error = null;
      _attach();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _attach() {
    final src = widget.src;
    try {
      final ctl =
          src.startsWith('http')
              ? VideoPlayerController.networkUrl(Uri.parse(src))
              : VideoPlayerController.file(
                File(
                  src.startsWith('file://') ? Uri.parse(src).toFilePath() : src,
                ),
              );
      _controller = ctl;
      ctl
          .initialize()
          .then((_) {
            if (!mounted) return;
            setState(() => _ready = true);
            if (widget.loop) ctl.setLooping(true);
            if (widget.autoplay) ctl.play();
          })
          .catchError((Object e) {
            if (!mounted) return;
            setState(() => _error = e.toString());
          });
    } catch (e) {
      _error = e.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    if (_error != null) {
      return _placeholder(
        Icons.error_outline,
        c.coral,
        'video load failed: $_error',
      );
    }
    if (!_ready || _controller == null) {
      return _placeholder(Icons.movie_outlined, c.textTertiary, 'loading…');
    }
    final ctl = _controller!;
    final ar = widget.aspectRatio ?? ctl.value.aspectRatio;
    return AspectRatio(
      aspectRatio: ar > 0 ? ar : 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          VideoPlayer(ctl),
          if (widget.showControls)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _Controls(controller: ctl),
            ),
        ],
      ),
    );
  }

  Widget _placeholder(IconData icon, Color iconColor, String text) {
    final c = VbuTokens.colorOf(context);
    return AspectRatio(
      aspectRatio: widget.aspectRatio ?? 16 / 9,
      child: Container(
        color: c.surface2,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 32, color: iconColor),
            const SizedBox(height: 6),
            Text(
              text,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Controls extends StatefulWidget {
  const _Controls({required this.controller});
  final VideoPlayerController controller;

  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_pull);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_pull);
    super.dispose();
  }

  void _pull() {
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final v = widget.controller.value;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space2,
        vertical: VbuTokens.space1,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.transparent, Colors.black.withOpacity(0.8)],
        ),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            icon: Icon(
              v.isPlaying ? Icons.pause : Icons.play_arrow,
              color: c.textPrimary,
            ),
            iconSize: 20,
            onPressed:
                () =>
                    v.isPlaying
                        ? widget.controller.pause()
                        : widget.controller.play(),
          ),
          Expanded(
            child: VideoProgressIndicator(
              widget.controller,
              allowScrubbing: true,
              colors: VideoProgressColors(
                playedColor: c.mint,
                bufferedColor: c.textTertiary.withOpacity(0.5),
                backgroundColor: c.textTertiary.withOpacity(0.2),
              ),
            ),
          ),
          const SizedBox(width: VbuTokens.space2),
          Text(
            '${_fmt(v.position)} / ${_fmt(v.duration)}',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              color: c.textPrimary,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
