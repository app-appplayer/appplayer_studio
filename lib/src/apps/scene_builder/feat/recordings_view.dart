import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart' show ChromeBridge, inspectTag;
import 'package:appplayer_studio/ui.dart';

/// Recordings — live recorder status + finished recordings list.
class RecordingsView extends StatefulWidget {
  const RecordingsView({
    super.key,
    required this.bundlePath,
    required this.chromeBridge,
  });

  final String bundlePath;
  final ChromeBridge chromeBridge;

  @override
  State<RecordingsView> createState() => _RecordingsViewState();
}

class _RecordingsViewState extends State<RecordingsView> {
  List<Map<String, dynamic>> _entries = const <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _status = const <String, dynamic>{'active': false};
  Timer? _statusTimer;
  String? _busy;

  @override
  void initState() {
    super.initState();
    _refreshList();
    _refreshStatus();
    _statusTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshStatus(),
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, dynamic> params,
  ) async {
    final fn = widget.chromeBridge.callHostTool;
    if (fn == null) {
      return <String, dynamic>{'ok': false, 'error': 'chrome bridge not wired'};
    }
    return fn(tool, params);
  }

  Map<String, dynamic>? _unwrap(Map<String, dynamic> result) {
    final content = result['content'];
    if (content is List && content.isNotEmpty) {
      final first = content.first;
      if (first is Map && first['text'] is String) {
        try {
          final decoded = jsonDecode(first['text'] as String);
          if (decoded is Map<String, dynamic>) return decoded;
        } catch (_) {
          /* fall through */
        }
      }
    }
    return null;
  }

  Future<void> _refreshList() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await _call(
      'studio.recorder.recordings.list',
      const <String, dynamic>{},
    );
    if (!mounted) return;
    if (result['ok'] == false) {
      setState(() {
        _loading = false;
        _error = result['error']?.toString() ?? 'failed';
        _entries = const <Map<String, dynamic>>[];
      });
      return;
    }
    final body = _unwrap(result) ?? result;
    final list = body['recordings'] ?? body['entries'] ?? const <dynamic>[];
    final out = <Map<String, dynamic>>[];
    if (list is List) {
      for (final e in list) {
        if (e is Map<String, dynamic>) out.add(e);
      }
    }
    setState(() {
      _loading = false;
      _entries = out;
    });
  }

  Future<void> _refreshStatus() async {
    final result = await _call(
      'studio.recorder.status',
      const <String, dynamic>{},
    );
    if (!mounted) return;
    final body = _unwrap(result) ?? result;
    setState(() => _status = body);
  }

  Future<void> _startRecording() async {
    setState(() => _busy = 'start');
    final result = await _call('studio.recorder.start', const <String, dynamic>{
      'fps': 24,
      'area': 'window',
    });
    if (!mounted) return;
    setState(() => _busy = null);
    final body = _unwrap(result) ?? result;
    final ok = body['ok'] != false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Recording started · ${body['recordingId'] ?? ''}'
              : 'Start failed · ${body['reason'] ?? body['error'] ?? 'unknown'}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    _refreshStatus();
  }

  Future<void> _stopRecording() async {
    setState(() => _busy = 'stop');
    final result = await _call(
      'studio.recorder.stop',
      const <String, dynamic>{},
    );
    if (!mounted) return;
    setState(() => _busy = null);
    final body = _unwrap(result) ?? result;
    final ok = body['ok'] != false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Stopped · ${body['frameCount'] ?? 0} frames · '
                  '${body['durationMs'] ?? 0}ms'
              : 'Stop failed · ${body['reason'] ?? body['error'] ?? 'unknown'}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    _refreshStatus();
    _refreshList();
  }

  void _playMp4(String path, String id) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final c = VbuTokens.colorOf(context);
        return Dialog(
          backgroundColor: c.bg,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920, maxHeight: 640),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    VbuTokens.space3,
                    VbuTokens.space3,
                    VbuTokens.space2,
                    VbuTokens.space2,
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          id,
                          style: TextStyle(
                            fontFamily: VbuTokens.fontMono,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, color: c.textSecondary),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: VbuTokens.space3,
                    ),
                    color: Colors.black,
                    child: VbuVideoPlayer(
                      src: path,
                      autoplay: true,
                      showControls: true,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(VbuTokens.space3),
                  child: Text(
                    path,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 10,
                      color: c.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _encode(String id) async {
    setState(() => _busy = 'encode::$id');
    final result = await _call('studio.recorder.encode', <String, dynamic>{
      'id': id,
    });
    if (!mounted) return;
    setState(() => _busy = null);
    final body = _unwrap(result) ?? result;
    final ok = body['ok'] != false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Encoded · ${body['mp4'] ?? id}'
              : 'Encode failed · ${body['error'] ?? 'unknown'}',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    _refreshList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[_toolbar(), _statusBar(), Expanded(child: _list())],
    );
  }

  Widget _toolbar() {
    final c = VbuTokens.colorOf(context);
    final active = _status['active'] == true;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.borderSubtle, width: 1)),
      ),
      child: Row(
        children: <Widget>[
          _toolbarButton(
            icon:
                active ? Icons.fiber_manual_record : Icons.fiber_manual_record,
            label: active ? 'Recording…' : 'Start 24fps',
            tint: active ? c.coral : c.mint,
            onTap: active || _busy == 'start' ? null : _startRecording,
          ),
          const SizedBox(width: VbuTokens.space2),
          _toolbarButton(
            icon: Icons.stop,
            label: 'Stop',
            onTap: !active || _busy == 'stop' ? null : _stopRecording,
          ),
          const SizedBox(width: VbuTokens.space2),
          _toolbarButton(
            icon: Icons.refresh,
            label: 'Refresh',
            onTap: _refreshList,
          ),
          const Spacer(),
          Text(
            '${_entries.length} recording${_entries.length == 1 ? '' : 's'}',
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              color: c.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBar() {
    final c = VbuTokens.colorOf(context);
    final active = _status['active'] == true;
    if (!active) return const SizedBox.shrink();
    final id = _status['id']?.toString() ?? '';
    final frames = _status['frameCount']?.toString() ?? '0';
    final elapsed = _status['elapsedMs'];
    final elapsedSec =
        elapsed is int ? (elapsed / 1000).toStringAsFixed(1) : '0';
    final fps = _status['fps']?.toString() ?? '?';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      decoration: BoxDecoration(
        color: c.coral.withValues(alpha: 0.08),
        border: Border(bottom: BorderSide(color: c.coral, width: 1)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.fiber_manual_record, size: 12, color: c.coral),
          const SizedBox(width: 8),
          Text(
            id,
            style: TextStyle(
              fontFamily: VbuTokens.fontMono,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(width: 16),
          _statusChip('$frames frames'),
          const SizedBox(width: 8),
          _statusChip('${elapsedSec}s'),
          const SizedBox(width: 8),
          _statusChip('${fps}fps'),
        ],
      ),
    );
  }

  Widget _statusChip(String text) {
    final c = VbuTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 10,
          color: c.textSecondary,
        ),
      ),
    );
  }

  Widget _list() {
    final c = VbuTokens.colorOf(context);
    if (_loading) {
      return Center(
        child: Text(
          'Loading…',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.textTertiary,
          ),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Text(
          'Failed: $_error',
          style: TextStyle(
            fontFamily: VbuTokens.fontMono,
            fontSize: 11,
            color: c.coral,
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.videocam_outlined, size: 32, color: c.textTertiary),
            const SizedBox(height: VbuTokens.space2),
            Text(
              'No recordings yet',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 12,
                color: c.textSecondary,
              ),
            ),
            const SizedBox(height: VbuTokens.space1),
            Text(
              'Start one with the Start button or via studio.recorder.start.',
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textTertiary,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      itemCount: _entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: VbuTokens.space2),
      itemBuilder: (_, i) => _row(_entries[i]),
    );
  }

  Widget _row(Map<String, dynamic> entry) {
    final c = VbuTokens.colorOf(context);
    final id = (entry['id'] ?? '').toString();
    final source = (entry['source'] ?? '').toString();
    final dir = (entry['dir'] ?? '').toString();
    final mp4 = entry['mp4'] as String?;
    final frameCount = entry['frameCount'];
    final hasMp4 = mp4 != null && mp4.isNotEmpty;
    return inspectTag(
      type: 'recording_row',
      id: id,
      extra: <String, dynamic>{'hasMp4': hasMp4, 'source': source},
      child: Container(
        padding: const EdgeInsets.all(VbuTokens.space3),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.borderDefault, width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  hasMp4 ? Icons.movie : Icons.image_outlined,
                  size: 14,
                  color: hasMp4 ? c.mint : c.textTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    id,
                    style: TextStyle(
                      fontFamily: VbuTokens.fontMono,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                ),
                if (frameCount != null) ...<Widget>[
                  _statusChip('$frameCount frames'),
                  const SizedBox(width: 6),
                ],
                _statusChip(source),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              dir,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 10,
                color: c.textMuted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: VbuTokens.space2),
            Row(
              children: <Widget>[
                if (hasMp4)
                  _rowAction(
                    icon: Icons.play_arrow,
                    label: 'Play',
                    onTap: () => _playMp4(mp4, id),
                  ),
                if (hasMp4) const SizedBox(width: VbuTokens.space2),
                if (!hasMp4)
                  _rowAction(
                    icon: Icons.movie_creation_outlined,
                    label: 'Encode mp4',
                    busy: _busy == 'encode::$id',
                    onTap: () => _encode(id),
                  ),
                if (hasMp4)
                  _rowAction(
                    icon: Icons.copy,
                    label: 'Copy path',
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: SelectableText(mp4),
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbarButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    Color? tint,
  }) {
    final c = VbuTokens.colorOf(context);
    final disabled = onTap == null;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.borderDefault, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 14,
              color: disabled ? c.textMuted : (tint ?? c.textSecondary),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: disabled ? c.textMuted : c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rowAction({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool busy = false,
  }) {
    final c = VbuTokens.colorOf(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.borderDefault, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              busy ? Icons.hourglass_top : icon,
              size: 13,
              color: c.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: VbuTokens.fontMono,
                fontSize: 11,
                color: c.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
