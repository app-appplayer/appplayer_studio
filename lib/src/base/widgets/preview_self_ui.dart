import 'package:appplayer_studio/base.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// self-UI live track. Spawns the converter's host simulator (a shell script
/// emitted alongside generated framework sources) and surfaces its stdout
/// so the user can confirm the chip-side UI compiles before flashing.
///
/// Embedding the simulator's framebuffer (LVGL SDL window, Qt host build)
/// requires platform-specific glue and is left to a follow-up. The current
/// pane shows simulator log output as a textual stand-in.
class PreviewSelfUi extends StatefulWidget {
  const PreviewSelfUi({
    super.key,
    required this.framework,
    this.simBuildDir,
    this.spawnSimulator = false,
  });

  final SelfUiFramework framework;
  final String? simBuildDir;

  /// Toggle that lets tests skip the actual `Process.start` call. Tests
  /// pass [spawnSimulator] = false; the host UI sets it true.
  final bool spawnSimulator;

  @override
  State<PreviewSelfUi> createState() => _PreviewSelfUiState();
}

class _PreviewSelfUiState extends State<PreviewSelfUi> {
  Process? _proc;
  final List<String> _log = <String>[];
  StreamSubscription<List<int>>? _outSub;
  StreamSubscription<List<int>>? _errSub;

  @override
  void initState() {
    super.initState();
    if (widget.spawnSimulator && widget.simBuildDir != null) {
      _spawn();
    }
  }

  @override
  void dispose() {
    _outSub?.cancel();
    _errSub?.cancel();
    _proc?.kill();
    super.dispose();
  }

  Future<void> _spawn() async {
    final dir = widget.simBuildDir!;
    final script = p.join(dir, 'sim_build.sh');
    if (!await File(script).exists()) {
      _append('sim_build.sh missing under $dir');
      return;
    }
    try {
      final proc = await Process.start('sh', <String>[
        script,
      ], workingDirectory: dir);
      _proc = proc;
      _outSub = proc.stdout.listen((bytes) {
        _append(utf8.decode(bytes, allowMalformed: true));
      });
      _errSub = proc.stderr.listen((bytes) {
        _append(utf8.decode(bytes, allowMalformed: true));
      });
    } catch (e) {
      _append('failed to spawn simulator: $e');
    }
  }

  void _append(String chunk) {
    if (!mounted) return;
    setState(() {
      _log.add(chunk);
      if (_log.length > 200) {
        _log.removeRange(0, _log.length - 200);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('vibe.preview.self_ui'),
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'self-UI preview',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          Text('framework: ${widget.framework.name}'),
          Text(
            widget.simBuildDir == null
                ? 'no simulator build yet'
                : 'sim: ${widget.simBuildDir}',
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              key: const Key('vibe.preview.self_ui.log'),
              itemCount: _log.length,
              itemBuilder:
                  (context, i) => Text(
                    _log[i],
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
