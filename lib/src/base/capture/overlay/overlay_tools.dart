/// Register `studio.overlay.*` MCP tools backed by [OverlayController].
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'overlay_controller.dart';
import 'overlay_models.dart';

void registerOverlayTools(
  mk.KernelServerHost boot, {
  required OverlayController controller,
}) {
  boot.addTool(
    name: 'studio.overlay.push',
    description:
        'Add an in-frame overlay (subtitle, arrow, check mark, pulse, '
        'etc.). The overlay renders ABOVE the body but INSIDE the shell '
        'RepaintBoundary so it lands in `studio.renderer.screenshot` '
        'and every recorder frame. Common props per kind: \n'
        ' - title_card: `{title, subtitle, background}`\n'
        ' - subtitle: `{text, position: top|bottom|center, fontSize}`\n'
        ' - step_indicator: `{current, total, color}`\n'
        ' - watermark: `{text|asset, corner, opacity}`\n'
        ' - arrow_pointer / circle_highlight / check_mark / cross_mark '
        '/ pulse_dot: `{target: PositionRef, color, text?}`\n'
        ' - cursor: synthetic mouse pointer (the recorder cannot capture '
        'the OS cursor). `{target}` parks it; `{targets:[from,to]}` travels '
        'A→B over `appearMs` (eased). `{click:true, clickMs, clickColor}` '
        'adds a click ripple when travel ends.\n'
        'Lifecycle: `appearMs` (fade-in) → `stayMs` (hold, 0 = persist '
        'until removed) → `fadeMs` (fade-out). Returns `{overlayId}`. '
        'Use `remove` to clear early.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'kind': <String, dynamic>{
          'type': 'string',
          'enum': <String>[
            'title_card',
            'subtitle',
            'step_indicator',
            'watermark',
            'transition',
            'arrow_pointer',
            'speech_bubble',
            'pulse_dot',
            'connector_line',
            'circle_highlight',
            'check_mark',
            'cross_mark',
            'highlighter',
            'box_outline',
            'underline',
            'strikethrough',
            'bracket',
            'numbered_label',
            'floating_icon',
            'floating_image',
            'slide',
            'cursor',
          ],
          'description':
              'Overlay kind (snake_case). 22 supported — structural: '
              'title_card · subtitle · step_indicator · watermark · '
              'transition. Pointing: arrow_pointer · speech_bubble · '
              'pulse_dot · connector_line. Emphasis: circle_highlight · '
              'check_mark · cross_mark · highlighter · box_outline. '
              'Lecture: underline · strikethrough · bracket · '
              'numbered_label. Media: floating_icon · floating_image · '
              'slide. Motion: cursor.',
        },
        'target': <String, dynamic>{
          'description':
              'PositionRef: `{abs:{x,y,w?,h?}}` / `{element:"id"}` / '
              '`{metadata:"key"}` / `{screen:"window|body|left_panel"}`. '
              'Some kinds take `targets: [...]` for multi-anchor.',
        },
        'targets': <String, dynamic>{'type': 'array'},
        'appearMs': <String, dynamic>{'type': 'integer'},
        'stayMs': <String, dynamic>{'type': 'integer'},
        'fadeMs': <String, dynamic>{'type': 'integer'},
      },
      'required': <String>['kind'],
    },
    handler: (args) async {
      final raw = Map<String, dynamic>.from(args);
      try {
        final id = controller.push((id) => OverlaySpec.fromJson(id, raw));
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{'ok': true, 'overlayId': id}),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': e.toString(),
              }),
            ),
          ],
        );
      }
    },
  );
  boot.addTool(
    name: 'studio.overlay.remove',
    description: 'Remove a previously-pushed overlay by id.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'overlayId': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['overlayId'],
    },
    handler: (args) async {
      final id = args['overlayId'] as String?;
      if (id == null || id.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"overlayId required"}',
            ),
          ],
        );
      }
      final removed = controller.remove(id);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{'ok': true, 'removed': removed}),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.overlay.clear',
    description: 'Remove every active overlay.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      controller.clear();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[mk.KernelTextContent(text: '{"ok":true}')],
      );
    },
  );
  boot.addTool(
    name: 'studio.overlay.list',
    description: 'Snapshot of every active overlay — `{count, entries}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final entries = controller.snapshotJson();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'count': entries.length,
              'entries': entries,
            }),
          ),
        ],
      );
    },
  );
}
