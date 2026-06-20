/// `registerRendererTools` — register the three `studio.renderer.*`
/// MCP tools (activate · layout_snapshot · current_view) onto a
/// kernel `ServerBootstrap`. The handlers route through a
/// [ChromeBridge] so the host that mounts the shell wires the
/// implementations from its `setState` and an external LLM exercises
/// the same code path a user click would.
///
/// Every studio host (universal vibe_studio, future variants) calls
/// this once during `registerMcpTools` so the renderer surface stays
/// identical across studios. Moved out of vibe_studio's host file
/// into base so the body of the registration is shared verbatim.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui show Image, ImageByteFormat, instantiateImageCodec;
import 'dart:ui' show Rect;

import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'chrome_bridge.dart';

/// Register the three `studio.renderer.*` tools onto [boot]. Each
/// handler reads from [bridge]; the host wires the bridge setters
/// when its shell mounts.
void registerRendererTools(mk.KernelServerHost boot, ChromeBridge bridge) {
  boot.addTool(
    name: 'studio.renderer.activate',
    description:
        'Universal view activator. Surface any chrome / sub-tab '
        'view by its path-like target so the LLM driving the studio '
        'can land the user on the right screen (debugging path) and '
        'so tool handlers can auto-jump to the screen showing their '
        'result (tool → view path). Recognised targets:'
        '\n  - `ui` / `tools` / `knowledge` / `manifest` — switch '
        'the active bundle tab\'s editor mode.'
        '\n  - `tools/<kind>` — Tools-mode sub-tab '
        '(tool / domain / slash / section).'
        '\n  - `home` — Home tab.'
        '\n  - `bundle/<mbdPath>` — switch to (or open) a bundle.'
        '\n  - `tab/<index>` — select tab by index.'
        '\n  - `tab/close/<index>` — close tab by index.'
        '\n  - `reload` — reload the active tab.'
        '\n  - `project/{new|open|close}` — project lifecycle on the '
        'active tab.'
        '\n  - `project/info` — read-only query: active tab\'s '
        'project info.'
        '\n  - `package/{new|open}` — Home-tab package lifecycle '
        '(create new package · install from picker).'
        '\n  - `chrome/settings` — open the Settings dialog.'
        '\n  - `chrome/history` — open the chat history dialog.'
        '\n  - `chrome/onboarding` — open the external-LLM onboarding panel.'
        '\n  - `chrome/agents` — open the agents surface dialog.'
        '\n  - `chrome/left_panel/{toggle|show|hide}` — chat panel state.'
        '\nDomain DSL paths (`<mbdNs>/<screen>`) land in Phase 2. '
        'Returns `{ok, target, ...}`; unknown targets return '
        '`{ok: false, reason: ...}` instead of erroring so the LLM '
        'can recover by trying a different path.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'target': <String, dynamic>{
          'type': 'string',
          'description':
              'Path-like view selector. Examples: '
              '"tools/domain", "tools/section", "home", '
              '"bundle/path/to/foo.mbd".',
        },
        'args': <String, dynamic>{
          'type': 'object',
          'description':
              'Optional structured arguments for targets that need '
              'them. Examples: `project/new` accepts `{name, '
              'parent}` (programmatic path; omit to open the '
              'dialog); `project/open` accepts `{path}` (programmatic '
              'open; omit for dialog); `package/new` accepts `{name, '
              'parent, id}` (programmatic scaffold; omit to open the '
              'dialog). Targets that don\'t need args ignore this field.',
        },
      },
      'required': <String>['target'],
    },
    handler: (args) async {
      final fn = bridge.activateView;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"shell not mounted yet"}',
            ),
          ],
          isError: true,
        );
      }
      final target = args['target'];
      if (target is! String || target.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"target (string) required"}',
            ),
          ],
          isError: true,
        );
      }
      final extraArgs = args['args'];
      final result = fn(
        target,
        extraArgs is Map<String, dynamic>
            ? extraArgs
            : (extraArgs is Map ? Map<String, dynamic>.from(extraArgs) : null),
      );
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(result)),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.renderer.layout_snapshot',
    description:
        'Walk the currently visible view\'s render tree and return '
        'one entry per `MetaData(metaData: {...})` widget: `{type, '
        'depth, rect [x,y,w,h], font?, box?, padding?}`. Pure render-'
        'tree introspection — numbers reflect what the user actually '
        'sees, NOT spec JSON. Use to verify layout (rect, font size, '
        'corner radius) without paying for a vision model. Pattern '
        'borrowed from vibe_app_builder\'s `vibe_layout_snapshot`. '
        'Only widgets the host wrapped in `MetaData` appear — chrome '
        'surfaces are tagged incrementally; mbd UI DSL coverage lands '
        'in Phase 2.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.captureLayoutSnapshot;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"nodes":[],"reason":"shell not mounted yet"}',
            ),
          ],
        );
      }
      final snap = await fn();
      final viewFn = bridge.currentViewTarget;
      final view = viewFn?.call();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'view': view?['target'],
              'nodes': snap ?? const <Map<String, dynamic>>[],
              if (snap == null) 'reason': 'capture root not attached',
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.renderer.current_view',
    description:
        'Inverse of `studio.renderer.activate` — return the '
        'activator target of the currently visible view so the LLM '
        'knows where the user is before deciding what to do next. '
        'Composes naturally with `activate` (read → decide → switch '
        '→ read) and with the future `layout_snapshot` tool '
        '(activate → snapshot → analyse). Returns `{target}` using '
        'the same path scheme as `activate`: `home`, '
        '`tools/<kind>`, `bundle/<path>`, etc.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.currentViewTarget;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"target":"unknown","reason":"shell not mounted yet"}',
            ),
          ],
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(fn())),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.renderer.screenshot',
    description:
        "Capture a PNG of the studio shell's RepaintBoundary root and "
        'return it as a base64-encoded mh.ImageContent. Pure Flutter '
        '`RepaintBoundary.toImage` (+ `PictureRecorder` for region crop) '
        '— no OS shell commands, no external binaries. `pixelRatio` '
        'controls render density (1.0 logical pixels, 2.0 retina). '
        '`area` crops the result; accepted forms: omit (full window), '
        '`{x, y, w, h}` (absolute rect in logical px), or one of the '
        'string tokens `"window"|"body"|"left_panel"` (Phase 1b will '
        "wire the region resolver for the named tokens — for now they "
        'fall back to full window).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'pixelRatio': <String, dynamic>{
          'type': 'number',
          'description': 'Render density (default 1.0).',
        },
        'area': <String, dynamic>{
          'description':
              'Crop area: `{x, y, w, h}` in logical pixels, or one of '
              '`window|body|left_panel`. Omit for full window.',
        },
      },
    },
    handler: (args) async {
      final pr = (args['pixelRatio'] as num?)?.toDouble() ?? 1.0;
      Rect? area;
      final rawArea = args['area'];
      if (rawArea is Map) {
        final x = (rawArea['x'] as num?)?.toDouble();
        final y = (rawArea['y'] as num?)?.toDouble();
        final w = (rawArea['w'] as num?)?.toDouble();
        final h = (rawArea['h'] as num?)?.toDouble();
        if (x != null && y != null && w != null && h != null) {
          area = Rect.fromLTWH(x, y, w, h);
        }
      }
      // String tokens (`window`, `body`, `left_panel`) — Phase 1b will
      // resolve via a region map exposed by the shell. For now we ignore
      // unrecognised tokens and capture full window.
      final fn = bridge.captureScreenshot;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"captureScreenshot-not-wired"}',
            ),
          ],
        );
      }
      final bytes = await fn(pixelRatio: pr, area: area);
      if (bytes == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"capture root not attached"}',
            ),
          ],
        );
      }
      final b64 = base64Encode(bytes);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelImageContent(data: b64, mimeType: 'image/png'),
        ],
      );
    },
  );

  // ── studio.renderer.image_diff ──────────────────────────────────
  // Pixel-wise diff between two PNG images (base64). Returns a
  // `score` in [0, 1] (0 = identical, 1 = totally different) plus
  // pixel counts for callers running visual regression. Both
  // images must decode to the same dimensions; otherwise returns
  // `ok:false` with the mismatched sizes so the caller can either
  // crop or re-capture at the same `pixelRatio`.
  boot.addTool(
    name: 'studio.renderer.image_diff',
    description:
        'Pixel-wise diff between two base64 PNGs. Returns `{ok, '
        'score, diffPixels, totalPixels, width, height}`. `score` = '
        'diffPixels / totalPixels in [0, 1]; 0 = identical. Both '
        'inputs must share the same dimensions. Use to assert '
        'visual regressions between two `studio.renderer.screenshot` '
        'captures of the same view.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'a': <String, dynamic>{
          'type': 'string',
          'description': 'Base64 PNG (no `data:` prefix).',
        },
        'b': <String, dynamic>{'type': 'string', 'description': 'Base64 PNG.'},
        'threshold': <String, dynamic>{
          'type': 'integer',
          'default': 8,
          'description':
              'Per-channel delta below which a pixel is "same". 0-255.',
        },
      },
      'required': <String>['a', 'b'],
    },
    handler: (args) async {
      final aRaw = args['a'] as String?;
      final bRaw = args['b'] as String?;
      if (aRaw == null || bRaw == null) {
        return mk.KernelToolResult(
          isError: true,
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"a + b required"}'),
          ],
        );
      }
      final threshold = (args['threshold'] as num?)?.toInt() ?? 8;
      try {
        final aBytes = base64Decode(aRaw);
        final bBytes = base64Decode(bRaw);
        final aImage = await _decodePng(aBytes);
        final bImage = await _decodePng(bBytes);
        if (aImage.width != bImage.width || aImage.height != bImage.height) {
          return mk.KernelToolResult(
            isError: true,
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text: jsonEncode(<String, Object?>{
                  'ok': false,
                  'error': 'dimensions mismatch',
                  'a': <String, int>{
                    'width': aImage.width,
                    'height': aImage.height,
                  },
                  'b': <String, int>{
                    'width': bImage.width,
                    'height': bImage.height,
                  },
                }),
              ),
            ],
          );
        }
        final aData =
            (await aImage.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final bData =
            (await bImage.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final aBuf = aData.buffer.asUint8List();
        final bBuf = bData.buffer.asUint8List();
        var diff = 0;
        for (var i = 0; i < aBuf.length; i += 4) {
          final dr = (aBuf[i] - bBuf[i]).abs();
          final dg = (aBuf[i + 1] - bBuf[i + 1]).abs();
          final db = (aBuf[i + 2] - bBuf[i + 2]).abs();
          final da = (aBuf[i + 3] - bBuf[i + 3]).abs();
          if (dr > threshold ||
              dg > threshold ||
              db > threshold ||
              da > threshold) {
            diff++;
          }
        }
        final total = aImage.width * aImage.height;
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': true,
                'score': total == 0 ? 0 : diff / total,
                'diffPixels': diff,
                'totalPixels': total,
                'width': aImage.width,
                'height': aImage.height,
                'threshold': threshold,
              }),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          isError: true,
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"decode failed: $e"}',
            ),
          ],
        );
      }
    },
  );
}

Future<ui.Image> _decodePng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}
