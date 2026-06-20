/// Register `studio.video.*` MCP tools — trim / concat / probe of
/// existing video files. The editing logic lives in [VideoEditService]
/// (host primitive); these tools are the dispatch surface the Scene
/// Builder builtin (and any MCP client) calls.
library;

import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'video_edit_service.dart';

mk.KernelToolResult _json(Map<String, dynamic> body) => mk.KernelToolResult(
  content: <mk.KernelContent>[mk.KernelTextContent(text: jsonEncode(body))],
);

void registerVideoEditTools(
  mk.KernelServerHost boot, {
  required VideoEditService service,
}) {
  boot.addTool(
    name: 'studio.video.probe',
    description:
        'Probe an existing video file — returns its duration (seconds). '
        'Used by the editor to size trim handles.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'input': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the video file.',
        },
      },
      'required': <String>['input'],
    },
    handler: (args) async {
      final input = (args['input'] as String?) ?? '';
      if (input.isEmpty || !File(input).existsSync()) {
        return _json(<String, dynamic>{
          'ok': false,
          'error': 'input not found',
        });
      }
      final dur = await service.probeDuration(input);
      return _json(<String, dynamic>{'ok': true, 'durationSec': dur});
    },
  );

  boot.addTool(
    name: 'studio.video.trim',
    description:
        'Trim an existing video to [startSec, endSec] (frame-accurate, '
        're-encoded). `endSec` omitted = to clip end. Output defaults to '
        '`<input>_trim.mp4` beside the source.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'input': <String, dynamic>{'type': 'string'},
        'startSec': <String, dynamic>{'type': 'number'},
        'endSec': <String, dynamic>{'type': 'number'},
        'output': <String, dynamic>{'type': 'string'},
        'crf': <String, dynamic>{'type': 'integer'},
      },
      'required': <String>['input', 'startSec'],
    },
    handler: (args) async {
      final input = (args['input'] as String?) ?? '';
      if (input.isEmpty || !File(input).existsSync()) {
        return _json(<String, dynamic>{
          'ok': false,
          'error': 'input not found',
        });
      }
      final start = (args['startSec'] as num?)?.toDouble() ?? 0;
      final end = (args['endSec'] as num?)?.toDouble();
      final r = await service.trim(
        input: input,
        startSec: start,
        endSec: end,
        output: args['output'] as String?,
        crf: args['crf'] as int?,
      );
      return _json(r.toJson());
    },
  );

  boot.addTool(
    name: 'studio.video.concat',
    description:
        'Concatenate existing video clips (in order) into one MP4 — the '
        '"join". Clips should share codec/resolution/fps (studio '
        'recordings + clips trimmed here do). Stream-copy, no re-encode.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'inputs': <String, dynamic>{
          'type': 'array',
          'description': 'Absolute clip paths, in playback order.',
          'items': <String, dynamic>{'type': 'string'},
        },
        'output': <String, dynamic>{
          'type': 'string',
          'description': 'Target MP4 path.',
        },
      },
      'required': <String>['inputs', 'output'],
    },
    handler: (args) async {
      final inputs = <String>[
        for (final v in (args['inputs'] as List? ?? const <dynamic>[]))
          if (v is String && v.isNotEmpty) v,
      ];
      final output = (args['output'] as String?) ?? '';
      if (output.isEmpty) {
        return _json(<String, dynamic>{
          'ok': false,
          'error': 'output required',
        });
      }
      final missing = inputs.where((c) => !File(c).existsSync()).toList();
      if (missing.isNotEmpty) {
        return _json(<String, dynamic>{
          'ok': false,
          'error': 'clip(s) not found: ${missing.join(', ')}',
        });
      }
      final work = Directory.systemTemp.createTempSync('video_concat_');
      final r = await service.concat(
        inputs: inputs,
        output: output,
        workDir: work.path,
      );
      return _json(r.toJson());
    },
  );

  boot.addTool(
    name: 'studio.video.convert',
    description:
        'Convert a video to a web-friendly format for homepage demos — '
        '`webm`(VP9, autoplay-loop), animated `webp`, `gif`, or `mp4`. '
        '`fps`/`width` trim weight; gif/webp drop audio.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'input': <String, dynamic>{'type': 'string'},
        'format': <String, dynamic>{
          'type': 'string',
          'enum': <String>['webm', 'gif', 'webp', 'mp4'],
        },
        'output': <String, dynamic>{
          'type': 'string',
          'description': 'Target path. Default: `<input>.<format>`.',
        },
        'fps': <String, dynamic>{'type': 'integer'},
        'width': <String, dynamic>{'type': 'integer'},
        'crf': <String, dynamic>{'type': 'integer'},
      },
      'required': <String>['input', 'format'],
    },
    handler: (args) async {
      final input = (args['input'] as String?) ?? '';
      if (input.isEmpty || !File(input).existsSync()) {
        return _json(<String, dynamic>{
          'ok': false,
          'error': 'input not found',
        });
      }
      final format = (args['format'] as String?) ?? 'mp4';
      final output =
          (args['output'] as String?) ??
          '${input.substring(0, input.lastIndexOf('.') == -1 ? input.length : input.lastIndexOf('.'))}.$format';
      final r = await service.convert(
        input: input,
        output: output,
        format: format,
        fps: args['fps'] as int?,
        width: args['width'] as int?,
        crf: args['crf'] as int?,
      );
      return _json(r.toJson());
    },
  );

  boot.addTool(
    name: 'studio.video.zoom',
    description:
        'Click zoom (Screen-Studio style) — smoothly zoom the frame toward '
        'a normalized focus point `(focusX, focusY)` in 0..1 between '
        '`startSec` and `endSec`, then back out. Pairs with the synthetic '
        '`cursor` overlay to emphasize a click. Source size is probed when '
        '`width`/`height` are omitted.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'input': <String, dynamic>{'type': 'string'},
        'output': <String, dynamic>{
          'type': 'string',
          'description': 'Target path. Default: `<input>_zoom.mp4`.',
        },
        'startSec': <String, dynamic>{'type': 'number'},
        'endSec': <String, dynamic>{'type': 'number'},
        'zoom': <String, dynamic>{
          'type': 'number',
          'description': 'Peak zoom factor (default 1.6).',
        },
        'focusX': <String, dynamic>{'type': 'number'},
        'focusY': <String, dynamic>{'type': 'number'},
        'rampSec': <String, dynamic>{'type': 'number'},
        'width': <String, dynamic>{'type': 'integer'},
        'height': <String, dynamic>{'type': 'integer'},
      },
      'required': <String>['input', 'startSec', 'endSec'],
    },
    handler: (args) async {
      final input = (args['input'] as String?) ?? '';
      if (input.isEmpty || !File(input).existsSync()) {
        return _json(<String, dynamic>{
          'ok': false,
          'error': 'input not found',
        });
      }
      var width = args['width'] as int?;
      var height = args['height'] as int?;
      if (width == null || height == null) {
        final size = await service.probeSize(input);
        if (size == null) {
          return _json(<String, dynamic>{
            'ok': false,
            'error': 'could not probe video size; pass width/height',
          });
        }
        width = size.$1;
        height = size.$2;
      }
      final dot = input.lastIndexOf('.');
      final output =
          (args['output'] as String?) ??
          '${dot == -1 ? input : input.substring(0, dot)}_zoom.mp4';
      final r = await service.zoom(
        input: input,
        output: output,
        width: width,
        height: height,
        startSec: (args['startSec'] as num?)?.toDouble() ?? 0,
        endSec: (args['endSec'] as num?)?.toDouble() ?? 0,
        zoom: (args['zoom'] as num?)?.toDouble() ?? 1.6,
        focusX: (args['focusX'] as num?)?.toDouble() ?? 0.5,
        focusY: (args['focusY'] as num?)?.toDouble() ?? 0.5,
        rampSec: (args['rampSec'] as num?)?.toDouble() ?? 0.4,
      );
      return _json(r.toJson());
    },
  );
}
