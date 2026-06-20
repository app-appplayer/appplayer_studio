/// Scene Builder "Editor" mode — import existing video clips, trim each,
/// and concat (join) into one MP4.
///
/// Pure UI + wiring: every operation goes through `studio.video.*` MCP
/// tools (probe / trim / concat). The editing LOGIC is the host
/// `VideoEditService` — this view never touches ffmpeg directly.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart' show ChromeBridge, inspectTag;
import 'package:appplayer_studio/ui.dart';

/// One clip on the editor timeline. [startSec]..[endSec] is the kept
/// range; [endSec] null = to clip end.
class _Clip {
  _Clip(this.path) : name = p.basename(path);
  final String path;
  final String name;
  double? durationSec;
  double startSec = 0;
  double? endSec;

  bool get trimmed =>
      startSec > 0.01 ||
      (endSec != null && durationSec != null && endSec! < durationSec! - 0.01);
}

class EditorView extends StatefulWidget {
  const EditorView({super.key, required this.chromeBridge});

  final ChromeBridge chromeBridge;

  @override
  State<EditorView> createState() => _EditorViewState();
}

class _EditorViewState extends State<EditorView> {
  final List<_Clip> _clips = <_Clip>[];
  bool _busy = false;
  String? _status;

  /// Web-friendly export target. `mp4` = no conversion (join output as-is);
  /// `webm`/`gif`/`webp` route the joined mp4 through `studio.video.convert`.
  String _format = 'mp4';

  static const List<String> _formats = <String>['mp4', 'webm', 'gif', 'webp'];

  Future<Map<String, dynamic>> _call(String tool, Map<String, dynamic> params) {
    final fn = widget.chromeBridge.callHostTool;
    if (fn == null) {
      return Future<Map<String, dynamic>>.value(<String, dynamic>{
        'ok': false,
        'error': 'chrome bridge not wired',
      });
    }
    return fn(tool, params);
  }

  Future<void> _import() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: true,
    );
    if (res == null) return;
    for (final f in res.files) {
      final path = f.path;
      if (path == null) continue;
      final clip = _Clip(path);
      _clips.add(clip);
      final probe = await _call('studio.video.probe', <String, dynamic>{
        'input': path,
      });
      if (probe['ok'] == true) {
        final d = (probe['durationSec'] as num?)?.toDouble();
        clip.durationSec = d;
        clip.endSec = d;
      }
    }
    if (mounted) setState(() {});
  }

  void _move(int i, int delta) {
    final j = i + delta;
    if (j < 0 || j >= _clips.length) return;
    setState(() {
      final c = _clips.removeAt(i);
      _clips.insert(j, c);
    });
  }

  Future<void> _export() async {
    if (_clips.isEmpty) {
      setState(() => _status = 'Import at least one clip first.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Exporting…';
    });
    try {
      // 1. Trim each clip that has a non-trivial range; pass others through.
      final parts = <String>[];
      for (final c in _clips) {
        if (!c.trimmed) {
          parts.add(c.path);
          continue;
        }
        final r = await _call('studio.video.trim', <String, dynamic>{
          'input': c.path,
          'startSec': c.startSec,
          if (c.endSec != null) 'endSec': c.endSec,
        });
        if (r['ok'] != true) {
          setState(() => _status = 'Trim failed (${c.name}): ${r['error']}');
          return;
        }
        parts.add(r['outputPath'] as String);
      }
      // 2. Single clip → use as-is. Multiple → concat into one mp4.
      final String mp4;
      if (parts.length == 1) {
        mp4 = parts.first;
      } else {
        final output = p.join(
          p.dirname(_clips.first.path),
          'edited_${DateTime.now().millisecondsSinceEpoch}.mp4',
        );
        final r = await _call('studio.video.concat', <String, dynamic>{
          'inputs': parts,
          'output': output,
        });
        if (r['ok'] != true) {
          setState(() => _status = 'Concat failed: ${r['error']}');
          return;
        }
        mp4 = output;
      }
      // 3. mp4 target → done. webm/gif/webp → convert for web/homepage use.
      if (_format == 'mp4') {
        setState(() => _status = 'Done — ${parts.length} clip(s) → $mp4');
        return;
      }
      final r = await _call('studio.video.convert', <String, dynamic>{
        'input': mp4,
        'format': _format,
      });
      setState(
        () =>
            _status =
                r['ok'] == true
                    ? 'Done — $_format → ${r['outputPath']}'
                    : 'Convert failed: ${r['error']}',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return inspectTag(
      type: 'scene.editor',
      id: 'scene-editor',
      label: 'video editor',
      child: Padding(
        padding: const EdgeInsets.all(VbuTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  'VIDEO EDITOR',
                  style: TextStyle(
                    fontFamily: VbuTokens.fontMono,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.0,
                    color: c.textTertiary,
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Import video'),
                ),
              ],
            ),
            const SizedBox(height: VbuTokens.space3),
            Expanded(
              child:
                  _clips.isEmpty
                      ? Center(
                        child: Text(
                          'Import video clips to trim and join.',
                          style: TextStyle(color: c.textTertiary),
                        ),
                      )
                      : ListView.separated(
                        itemCount: _clips.length,
                        separatorBuilder:
                            (_, __) => const SizedBox(height: VbuTokens.space2),
                        itemBuilder: (_, i) => _clipCard(i, c),
                      ),
            ),
            const SizedBox(height: VbuTokens.space3),
            Row(
              children: <Widget>[
                if (_status != null)
                  Expanded(
                    child: Text(
                      _status!,
                      style: TextStyle(color: c.textSecondary, fontSize: 12),
                    ),
                  )
                else
                  const Spacer(),
                Tooltip(
                  message: 'Export format — webm/gif/webp for homepage demos',
                  child: DropdownButton<String>(
                    value: _format,
                    underline: const SizedBox.shrink(),
                    items: <DropdownMenuItem<String>>[
                      for (final f in _formats)
                        DropdownMenuItem<String>(
                          value: f,
                          child: Text(
                            f,
                            style: const TextStyle(
                              fontFamily: VbuTokens.fontMono,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                    onChanged:
                        _busy
                            ? null
                            : (v) => setState(() => _format = v ?? 'mp4'),
                  ),
                ),
                const SizedBox(width: VbuTokens.space2),
                FilledButton.icon(
                  onPressed: _busy || _clips.isEmpty ? null : _export,
                  icon:
                      _busy
                          ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Icon(Icons.movie_outlined, size: 16),
                  label: Text(_clips.length > 1 ? 'Export (join)' : 'Export'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _clipCard(int i, dynamic c) {
    final clip = _clips[i];
    final dur = clip.durationSec;
    return Container(
      padding: const EdgeInsets.all(VbuTokens.space3),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        border: Border.all(color: c.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '${i + 1}',
                style: TextStyle(
                  color: c.textTertiary,
                  fontFamily: VbuTokens.fontMono,
                ),
              ),
              const SizedBox(width: VbuTokens.space2),
              Expanded(
                child: Text(
                  clip.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textPrimary),
                ),
              ),
              Text(
                dur == null
                    ? '—'
                    : '${clip.startSec.toStringAsFixed(1)}–'
                        '${(clip.endSec ?? dur).toStringAsFixed(1)}s / '
                        '${dur.toStringAsFixed(1)}s',
                style: TextStyle(color: c.textSecondary, fontSize: 12),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                tooltip: 'Move up',
                onPressed: i == 0 ? null : () => _move(i, -1),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                tooltip: 'Move down',
                onPressed: i == _clips.length - 1 ? null : () => _move(i, 1),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Remove',
                onPressed: () => setState(() => _clips.removeAt(i)),
              ),
            ],
          ),
          if (dur != null && dur > 0)
            RangeSlider(
              min: 0,
              max: dur,
              values: RangeValues(
                clip.startSec.clamp(0, dur),
                (clip.endSec ?? dur).clamp(0, dur),
              ),
              labels: RangeLabels(
                '${clip.startSec.toStringAsFixed(1)}s',
                '${(clip.endSec ?? dur).toStringAsFixed(1)}s',
              ),
              onChanged:
                  (v) => setState(() {
                    clip.startSec = v.start;
                    clip.endSec = v.end;
                  }),
            ),
        ],
      ),
    );
  }
}
