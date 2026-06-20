/// `registerUiControlTools` — register the studio.* MCP verbs that
/// drive UI control + advanced introspection (region picker, layout
/// diff, polling, programmatic tap). Lifted into a separate file so
/// the surface is easy to audit + extend; every host calls this once
/// during boot to expose the verbs uniformly.
///
/// The verbs cover ground the legacy `studio.debug.*` / `renderer.*`
/// catalogue left to manual cliclick / external scripting:
///   * `studio.debug.wait_for` — generic polling helper.
///   * `studio.debug.snapshot_diff` — diff two layout snapshots.
///   * `studio.renderer.screenshot_region` — screenshot crop by
///     `elementId` (uses `ChromeBridge.resolveElementRect`).
///   * `studio.ui.tap` — programmatic tap via Flutter's
///     `GestureBinding` pointer pipeline; same path a user click takes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show PopupMenuEntry, PopupMenuItem;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart'
    show ServicesBinding, StandardMessageCodec;
import 'package:flutter/widgets.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/chrome_bridge.dart';

void registerUiControlTools(
  mk.KernelServerHost boot, {
  required ChromeBridge bridge,
  required Future<mk.KernelToolResult> Function(
    String tool,
    Map<String, dynamic> args,
  )
  callTool,
}) {
  // ── studio.debug.wait_for ───────────────────────────────────────
  // Poll a host tool until a JSON-path predicate matches or the
  // timeout elapses. The predicate compares the dot-path value on the
  // tool's decoded response against `equals` (string-coerced). Use
  // for "wait until the active tab restored project / wait until the
  // dispatch log shows X / wait until runtime state has key=value"
  // workflows that previously needed external retry loops.
  boot.addTool(
    name: 'studio.debug.wait_for',
    description:
        'Poll `tool` with `args` every `intervalMs` until the value at '
        '`path` in the decoded JSON response equals `equals`, or '
        '`timeoutMs` elapses. `path` uses dot syntax (e.g. '
        '`state.currentProject`, `entries.0.tool`). Returns the matching '
        'response on success, `{ok:false, reason:"timeout", '
        'lastResponse}` on timeout. Default `intervalMs`=300, '
        '`timeoutMs`=10000.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'tool': <String, dynamic>{'type': 'string'},
        'args': <String, dynamic>{'type': 'object'},
        'path': <String, dynamic>{'type': 'string'},
        'equals': <String, dynamic>{
          'description': 'Expected value (string-coerced for compare).',
        },
        'intervalMs': <String, dynamic>{'type': 'integer'},
        'timeoutMs': <String, dynamic>{'type': 'integer'},
      },
      'required': <String>['tool', 'path', 'equals'],
    },
    handler: (args) async {
      final tool = args['tool'] as String?;
      final path = args['path'] as String?;
      final equals = args['equals'];
      if (tool == null || tool.isEmpty || path == null || path.isEmpty) {
        return _text(
          '{"ok":false,"error":"tool + path required"}',
          isError: true,
        );
      }
      final params =
          (args['args'] is Map)
              ? Map<String, dynamic>.from(args['args'] as Map)
              : <String, dynamic>{};
      final interval = Duration(
        milliseconds: (args['intervalMs'] as int?) ?? 300,
      );
      final deadline = DateTime.now().add(
        Duration(milliseconds: (args['timeoutMs'] as int?) ?? 10000),
      );
      Map<String, dynamic>? lastDecoded;
      while (DateTime.now().isBefore(deadline)) {
        try {
          final result = await callTool(tool, params);
          final decoded = _decode(result);
          lastDecoded = decoded;
          final actual = _jsonPathGet(decoded, path);
          if (actual?.toString() == equals?.toString()) {
            return _text(
              jsonEncode(<String, dynamic>{
                'ok': true,
                'matched': true,
                'response': decoded,
              }),
            );
          }
        } catch (e) {
          lastDecoded = <String, dynamic>{'error': e.toString()};
        }
        await Future<void>.delayed(interval);
      }
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'reason': 'timeout',
          'lastResponse': lastDecoded,
        }),
      );
    },
  );

  // ── studio.debug.snapshot_diff ──────────────────────────────────
  // Diff two layout snapshots by elementId. Snapshots are typically
  // produced by `studio.renderer.layout_snapshot` or
  // `studio.debug.layout_snapshot`; the diff yields `added`,
  // `removed`, `moved` (rect changed), and `resized` (size changed)
  // lists keyed by elementId.
  boot.addTool(
    name: 'studio.debug.snapshot_diff',
    description:
        'Diff two layout snapshots — pass full `before` / `after` '
        'objects (`{nodes: [{elementId, rect, ...}, ...]}` shape). '
        'Returns `{added: [...], removed: [...], moved: [...], '
        'resized: [...]}` lists of elementId strings. Use after a '
        'mutation to confirm exactly which widgets changed without '
        'eyeballing two PNGs.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'before': <String, dynamic>{'type': 'object'},
        'after': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['before', 'after'],
    },
    handler: (args) async {
      final before = args['before'];
      final after = args['after'];
      if (before is! Map || after is! Map) {
        return _text(
          '{"ok":false,"error":"before + after objects required"}',
          isError: true,
        );
      }
      final beforeNodes = _indexNodes(before);
      final afterNodes = _indexNodes(after);
      final added = <String>[];
      final removed = <String>[];
      final moved = <String>[];
      final resized = <String>[];
      for (final id in afterNodes.keys) {
        if (!beforeNodes.containsKey(id)) {
          added.add(id);
        } else {
          final b = beforeNodes[id]!;
          final a = afterNodes[id]!;
          final br = _rect(b);
          final ar = _rect(a);
          if (br != null && ar != null) {
            final movedXY = br[0] != ar[0] || br[1] != ar[1];
            final resizedWH = br[2] != ar[2] || br[3] != ar[3];
            if (movedXY) moved.add(id);
            if (resizedWH) resized.add(id);
          }
        }
      }
      for (final id in beforeNodes.keys) {
        if (!afterNodes.containsKey(id)) removed.add(id);
      }
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'added': added,
          'removed': removed,
          'moved': moved,
          'resized': resized,
        }),
      );
    },
  );

  // ── studio.renderer.screenshot_region ───────────────────────────
  // Screenshot the host's RepaintBoundary cropped to a region resolved
  // by elementId via `ChromeBridge.resolveElementRect`. The elementId
  // format is `<type>:<key>` (matches the existing layout-snapshot
  // annotation contract — e.g. `header_action:project.save`).
  boot.addTool(
    name: 'studio.renderer.screenshot_region',
    description:
        'Capture a PNG of the rectangle owned by `elementId` (resolved '
        'through `ChromeBridge.resolveElementRect`). `elementId` is '
        '`<type>:<key>` — same vocabulary the layout-snapshot tool uses '
        '(e.g. `header_action:project.save`, `tab:home`). Returns a '
        'base64 PNG mh.ImageContent. `pixelRatio` (default 1.0) drives '
        'render density. Returns `{ok:false, error}` when the '
        'elementId is not currently rendered.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'elementId': <String, dynamic>{'type': 'string'},
        'pixelRatio': <String, dynamic>{'type': 'number'},
      },
      'required': <String>['elementId'],
    },
    handler: (args) async {
      final elementId = args['elementId'] as String?;
      if (elementId == null || elementId.isEmpty) {
        return _text(
          '{"ok":false,"error":"elementId required"}',
          isError: true,
        );
      }
      final rect = bridge.resolveElementRect?.call(elementId);
      if (rect == null) {
        return _text(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'elementId not found',
            'elementId': elementId,
          }),
          isError: true,
        );
      }
      final pixelRatio = (args['pixelRatio'] as num?)?.toDouble() ?? 1.0;
      final png = await _captureRegion(bridge, rect, pixelRatio);
      if (png == null) {
        return _text(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'capture failed',
            'elementId': elementId,
          }),
          isError: true,
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelImageContent(data: base64Encode(png), mimeType: 'image/png'),
        ],
      );
    },
  );

  // ── studio.ui.set_center_mode ──────────────────────────────────
  // The active built-in (e.g. app_builder) hosts a 3-way mode toggle.
  // Synthetic taps on the chip do not survive Flutter desktop's
  // pointer-route filter in production, so this verb routes through
  // ChromeBridge.setCenterMode — the same setState path the chip's
  // own onTap takes when a user clicks.
  boot.addTool(
    name: 'studio.ui.set_center_mode',
    description:
        'Switch the active built-in app\'s 3-way center mode. '
        '`mode` ∈ {`ui`, `bundle`, `debug`}. Routes through the host '
        'chrome bridge (no synthetic pointer event) so the swap is '
        'reliable in release builds. Returns `{ok}` when the mode was '
        'applied, `{ok:false, reason}` when the active tab does not '
        'own a center-mode toggle (e.g. home tab / pure manifest '
        'bundle).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mode': <String, dynamic>{
          'type': 'string',
          'enum': <String>['ui', 'bundle', 'debug'],
        },
      },
      'required': <String>['mode'],
    },
    handler: (args) async {
      final mode = args['mode'] as String?;
      if (mode == null) {
        return _text('{"ok":false,"error":"mode required"}', isError: true);
      }
      final fn = bridge.setCenterMode;
      if (fn == null) {
        return _text(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'reason': 'no-builtin-toggle',
            'mode': mode,
          }),
        );
      }
      final ok = fn(mode);
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': ok,
          if (!ok) 'reason': 'unsupported-mode-or-no-active-builtin',
          'mode': mode,
        }),
      );
    },
  );

  // ── studio.ui.tap ───────────────────────────────────────────────
  // Dispatch a synthetic tap at the centre of the rectangle resolved
  // by elementId (or at explicit x/y). Uses Flutter's
  // `GestureBinding.handlePointerEvent` so the event travels the same
  // hit-test pipeline as a user click — `onTap` / `InkWell` /
  // `GestureDetector` all fire normally. macOS accessibility is not
  // involved — works in release builds without any granted permission.
  boot.addTool(
    name: 'studio.ui.tap',
    description:
        'Dispatch a programmatic tap. Either pass `elementId` (resolved '
        'via the layout-snapshot rect resolver — `header_action:'
        'project.save` etc.) or explicit `x` + `y` in logical pixels '
        '(window-relative). Travels through Flutter\'s pointer pipeline '
        'so onTap / GestureDetector fire just like a real click. macOS '
        'accessibility is not required. Returns `{ok, x, y}` on '
        'success.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'elementId': <String, dynamic>{'type': 'string'},
        'x': <String, dynamic>{'type': 'number'},
        'y': <String, dynamic>{'type': 'number'},
        'mode': <String, dynamic>{
          'type': 'string',
          'enum': <String>['tap', 'long', 'double'],
          'default': 'tap',
          'description':
              '`tap` (default) = single press. `long` = hold for '
              '600ms before release (LongPress recognisers fire). '
              '`double` = two quick taps in succession '
              '(GestureDetector.onDoubleTap fires).',
        },
      },
    },
    handler: (args) async {
      double? x;
      double? y;
      final elementId = args['elementId'] as String?;
      if (elementId != null && elementId.isNotEmpty) {
        final rect = bridge.resolveElementRect?.call(elementId);
        if (rect == null) {
          return _text(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'error': 'elementId not found',
              'elementId': elementId,
            }),
            isError: true,
          );
        }
        x = rect.center.dx;
        y = rect.center.dy;
      } else {
        x = (args['x'] as num?)?.toDouble();
        y = (args['y'] as num?)?.toDouble();
      }
      if (x == null || y == null) {
        return _text(
          '{"ok":false,"error":"need elementId OR x+y"}',
          isError: true,
        );
      }
      final mode = (args['mode'] as String?)?.toLowerCase() ?? 'tap';
      switch (mode) {
        case 'long':
          await _dispatchTap(x, y, holdMs: 600);
          break;
        case 'double':
          await _dispatchTap(x, y);
          await Future<void>.delayed(const Duration(milliseconds: 90));
          await _dispatchTap(x, y);
          break;
        default:
          await _dispatchTap(x, y);
      }
      return _text(
        jsonEncode(<String, dynamic>{'ok': true, 'x': x, 'y': y, 'mode': mode}),
      );
    },
  );

  // ── studio.ui.type ──────────────────────────────────────────────
  // Set a TextField's content programmatically. Works around the IME
  // problem osascript / cliclick text injection hits (Hangul / CJK
  // composition garbles characters). Instead of synthesizing
  // keystrokes, walks the widget tree to find the focused
  // EditableText and writes directly into its TextEditingController.
  // The controller's setter fires listeners — `onChanged` / autosave
  // path runs identically to a human keystroke sequence.
  //
  // Usage:
  //   - Tap the field first via `studio.ui.tap` to focus it (this
  //     tool finds the currently-focused EditableText).
  //   - Then call `studio.ui.type({text})` to overwrite.
  //   - Or pass `elementId` to chain the tap + type in one call.
  //   - `clear: true` (default) replaces the content; `clear: false`
  //     appends to the existing text.
  boot.addTool(
    name: 'studio.ui.type',
    description:
        'Set the focused `TextField` content programmatically — '
        'walks the widget tree to find the focused `EditableText` '
        'and writes directly into its `TextEditingController`. '
        'Bypasses macOS IME (no Korean/CJK composition garbling) '
        'and accessibility permissions entirely. Pass `elementId` '
        'to focus first (chains tap + type), or focus manually '
        'with `studio.ui.tap` then call without elementId. Default '
        '`clear: true` replaces content; `false` appends. Returns '
        '`{ok, text, before?, after}` so callers can verify the '
        'write took.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'text': <String, dynamic>{
          'type': 'string',
          'description': 'New content to write.',
        },
        'elementId': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional. Tap this element first (via the layout-'
              'snapshot rect resolver) to focus its TextField.',
        },
        'clear': <String, dynamic>{
          'type': 'boolean',
          'description':
              'When true (default) overwrites existing text. When '
              'false appends to the cursor position.',
        },
        'submit': <String, dynamic>{
          'type': 'boolean',
          'description':
              'When true, invoke the field\'s `onSubmitted` after '
              'writing (e.g. fire the Enter handler of a search '
              'box). Default false.',
        },
      },
      'required': <String>['text'],
    },
    handler: (args) async {
      final text = args['text'];
      if (text is! String) {
        return _text(
          '{"ok":false,"error":"text (string) required"}',
          isError: true,
        );
      }
      final clear = args['clear'] as bool? ?? true;
      final submit = args['submit'] as bool? ?? false;
      // Optional: tap to focus first.
      final elementId = args['elementId'] as String?;
      if (elementId != null && elementId.isNotEmpty) {
        final rect = bridge.resolveElementRect?.call(elementId);
        if (rect == null) {
          return _text(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'error': 'elementId not found',
              'elementId': elementId,
            }),
            isError: true,
          );
        }
        await _dispatchTap(rect.center.dx, rect.center.dy);
        // Give the focus change a frame to settle.
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) {
        return _text('{"ok":false,"error":"no root element"}', isError: true);
      }
      // Walk the tree for the focused EditableText. EditableText is
      // the leaf Flutter exposes the TextEditingController on; both
      // Material `TextField` and Cupertino variants wrap one.
      EditableTextState? focused;
      void visit(Element el) {
        if (focused != null) return;
        final w = el.widget;
        if (w is EditableText) {
          final state = (el as StatefulElement).state as EditableTextState;
          if (state.widget.focusNode.hasFocus) {
            focused = state;
            return;
          }
        }
        el.visitChildren(visit);
      }

      root.visitChildren(visit);
      if (focused == null) {
        return _text(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error':
                'no focused EditableText found — tap the field first '
                '(or pass elementId to chain)',
          }),
          isError: true,
        );
      }
      final controller = focused!.widget.controller;
      final before = controller.text;
      final after = clear ? text : before + text;
      // Setting controller.text fires listeners → `onChanged` +
      // ManifestFieldList autosave run the same path a real
      // keystroke takes.
      controller.value = TextEditingValue(
        text: after,
        selection: TextSelection.collapsed(offset: after.length),
      );
      var submitted = false;
      if (submit) {
        // Fire the field's onSubmitted (Enter handler). Falls back to
        // synthesising a macOS `enter` keyevent so Shortcuts /
        // Focus-bound bindings also respond when the EditableText
        // has no onSubmitted callback.
        final onSubmitted = focused!.widget.onSubmitted;
        if (onSubmitted != null) {
          try {
            onSubmitted(after);
            submitted = true;
          } catch (_) {}
        }
        if (!submitted) {
          final spec = _resolveKey('enter', null);
          if (spec != null) {
            submitted = await _dispatchMacKey(spec, const <String>{});
          }
        }
      }
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'text': text,
          'before': before,
          'after': after,
          'cleared': clear,
          'submitted': submitted,
        }),
      );
    },
  );

  // ── studio.ui.dismiss_dialog ────────────────────────────────────
  // Pop the topmost route from the root navigator — matches what
  // pressing Esc / clicking Cancel does on a modal dialog. Used by
  // external test drivers to close `open_settings` / `open_history`
  // etc. after asserting their content without relying on macOS
  // accessibility (which the synthetic-tap pipeline avoids by design).
  boot.addTool(
    name: 'studio.ui.dismiss_dialog',
    description:
        'Pop the topmost route on the root navigator — closes the '
        'active dialog (Settings, History, etc.) without relying on '
        'osascript / cliclick / accessibility permissions. Returns '
        '`{ok, dismissed}`. `dismissed:false` when there was no '
        'route to pop (no dialog open).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) {
        return _text('{"ok":false,"error":"no root element"}', isError: true);
      }
      NavigatorState? nav;
      void visit(Element el) {
        if (nav != null) return;
        final w = el.widget;
        if (w is Navigator) {
          final s = (el as StatefulElement).state;
          if (s is NavigatorState) nav = s;
        }
        el.visitChildren(visit);
      }

      root.visitChildren(visit);
      if (nav == null) {
        return _text(
          '{"ok":false,"error":"navigator not found"}',
          isError: true,
        );
      }
      final canPop = nav!.canPop();
      if (!canPop) {
        return _text(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'dismissed': false,
            'reason': 'nothing to pop',
          }),
        );
      }
      nav!.pop();
      return _text(
        jsonEncode(<String, dynamic>{'ok': true, 'dismissed': true}),
      );
    },
  );

  // ── studio.ui.scroll ────────────────────────────────────────────
  // Synthesise a wheel scroll at (`elementId` center OR x/y). `dx` /
  // `dy` are logical-pixel scroll deltas (positive y = scroll down).
  // Dispatches through `GestureBinding.dispatchEvent` so any
  // Scrollable / ListView / SingleChildScrollView under the cursor
  // receives the wheel like a real trackpad / mouse wheel.
  boot.addTool(
    name: 'studio.ui.scroll',
    description:
        'Dispatch a synthetic scroll-wheel event at the resolved '
        'position. `elementId` resolves a rect (centre is used) OR '
        'pass explicit `x` + `y`. `dy` > 0 scrolls down; `dx` > 0 '
        'scrolls right. Returns `{ok, x, y, dx, dy}`. Use to drive '
        'long lists / preview canvases that scroll outside the '
        'visible area without dragging the scrollbar.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'elementId': <String, dynamic>{'type': 'string'},
        'x': <String, dynamic>{'type': 'number'},
        'y': <String, dynamic>{'type': 'number'},
        'dx': <String, dynamic>{'type': 'number', 'default': 0},
        'dy': <String, dynamic>{'type': 'number', 'default': 0},
      },
    },
    handler: (args) async {
      final pos = _resolvePosition(bridge, args);
      if (pos == null) {
        return _text(
          '{"ok":false,"error":"need elementId OR x+y"}',
          isError: true,
        );
      }
      final dx = (args['dx'] as num?)?.toDouble() ?? 0.0;
      final dy = (args['dy'] as num?)?.toDouble() ?? 0.0;
      await _dispatchScroll(pos.dx, pos.dy, dx, dy);
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'x': pos.dx,
          'y': pos.dy,
          'dx': dx,
          'dy': dy,
        }),
      );
    },
  );

  // ── studio.ui.hover ─────────────────────────────────────────────
  // Move the synthetic pointer to a position without pressing —
  // surfaces hover effects (Tooltip, hover decorations) so callers
  // can capture them via `studio.renderer.screenshot` afterwards.
  boot.addTool(
    name: 'studio.ui.hover',
    description:
        'Move the synthetic mouse pointer to a position without '
        'clicking. `elementId` OR `x`+`y`. Use before a screenshot '
        'to capture hover decorations / tooltips. Returns `{ok, x, y}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'elementId': <String, dynamic>{'type': 'string'},
        'x': <String, dynamic>{'type': 'number'},
        'y': <String, dynamic>{'type': 'number'},
      },
    },
    handler: (args) async {
      final pos = _resolvePosition(bridge, args);
      if (pos == null) {
        return _text(
          '{"ok":false,"error":"need elementId OR x+y"}',
          isError: true,
        );
      }
      await _dispatchHover(pos.dx, pos.dy);
      return _text(
        jsonEncode(<String, dynamic>{'ok': true, 'x': pos.dx, 'y': pos.dy}),
      );
    },
  );

  // ── studio.ui.right_click ───────────────────────────────────────
  // Synthesise a secondary-button tap. Same pipeline as
  // `studio.ui.tap` but with `buttons: kSecondaryMouseButton` so
  // context-menu handlers (Listener.onPointerDown filtering by
  // button, GestureDetector.onSecondaryTap*) fire.
  boot.addTool(
    name: 'studio.ui.right_click',
    description:
        'Synthesise a secondary-button (right) click. Same args as '
        '`studio.ui.tap`. Use to open context menus (InstanceCard `⋮`, '
        'overflow popups). Returns `{ok, x, y}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'elementId': <String, dynamic>{'type': 'string'},
        'x': <String, dynamic>{'type': 'number'},
        'y': <String, dynamic>{'type': 'number'},
      },
    },
    handler: (args) async {
      final pos = _resolvePosition(bridge, args);
      if (pos == null) {
        return _text(
          '{"ok":false,"error":"need elementId OR x+y"}',
          isError: true,
        );
      }
      await _dispatchSecondaryTap(pos.dx, pos.dy);
      return _text(
        jsonEncode(<String, dynamic>{'ok': true, 'x': pos.dx, 'y': pos.dy}),
      );
    },
  );

  // ── studio.ui.drag ──────────────────────────────────────────────
  // Synthesise a drag gesture from a start position to an end
  // position with `steps` intermediate moves. Use for splitter
  // resize, reorderable lists, canvas pan, etc.
  boot.addTool(
    name: 'studio.ui.drag',
    description:
        'Synthesise a drag: pointer down at `from`, N intermediate '
        '`move` events, pointer up at `to`. `from`/`to` accept '
        '`{elementId}` OR `{x,y}`. `steps` (default 12) controls '
        'how many intermediate moves are emitted; higher = smoother '
        '(helpful for inertia-based drag-and-drop). Returns '
        '`{ok, from:{x,y}, to:{x,y}, steps}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'from': <String, dynamic>{'type': 'object'},
        'to': <String, dynamic>{'type': 'object'},
        'steps': <String, dynamic>{'type': 'integer', 'default': 12},
      },
      'required': <String>['from', 'to'],
    },
    handler: (args) async {
      final fromArg = args['from'];
      final toArg = args['to'];
      if (fromArg is! Map || toArg is! Map) {
        return _text(
          '{"ok":false,"error":"from + to required"}',
          isError: true,
        );
      }
      final from = _resolvePosition(bridge, Map<String, dynamic>.from(fromArg));
      final to = _resolvePosition(bridge, Map<String, dynamic>.from(toArg));
      if (from == null || to == null) {
        return _text(
          '{"ok":false,"error":"from/to must resolve to a position"}',
          isError: true,
        );
      }
      final steps = (args['steps'] as num?)?.toInt() ?? 12;
      await _dispatchDrag(from, to, steps.clamp(1, 200));
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'from': <String, double>{'x': from.dx, 'y': from.dy},
          'to': <String, double>{'x': to.dx, 'y': to.dy},
          'steps': steps,
        }),
      );
    },
  );

  // ── studio.ui.focus ─────────────────────────────────────────────
  // Find the first FocusableActionDetector / EditableText / Focus
  // node under the resolved rect and `requestFocus()` it without
  // dispatching a tap event. Useful when callers want to focus a
  // text field before `studio.ui.type` without triggering an
  // associated onTap handler.
  boot.addTool(
    name: 'studio.ui.focus',
    description:
        'Move keyboard focus to the first focusable widget under '
        '`elementId` (or x/y) without dispatching a tap. Pair with '
        '`studio.ui.type` when the surrounding onTap would do '
        'something unwanted (e.g. open a popover). Returns '
        '`{ok, focused}` where `focused` is true when a FocusNode '
        'accepted the request.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'elementId': <String, dynamic>{'type': 'string'},
        'x': <String, dynamic>{'type': 'number'},
        'y': <String, dynamic>{'type': 'number'},
      },
    },
    handler: (args) async {
      final pos = _resolvePosition(bridge, args);
      if (pos == null) {
        return _text(
          '{"ok":false,"error":"need elementId OR x+y"}',
          isError: true,
        );
      }
      final focused = _focusAt(pos);
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'focused': focused,
          'x': pos.dx,
          'y': pos.dy,
        }),
      );
    },
  );

  // ── studio.ui.element_value ─────────────────────────────────────
  // Read the current text of a focused / target EditableText. When
  // `elementId` is supplied, finds the first EditableText under that
  // element's rect; otherwise reads from the currently-focused
  // EditableText. Inverse of `studio.ui.type` — caller writes a
  // value, then asks back to confirm the write took.
  boot.addTool(
    name: 'studio.ui.element_value',
    description:
        'Read the current value of a TextField — either the one at '
        '`elementId` (rect-resolved), the one at x/y, or the '
        'currently focused EditableText when no target is given. '
        'Returns `{ok, value, hasFocus, selection:{start,end}}` so '
        'callers can verify `studio.ui.type` writes and inspect the '
        'selection range.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'elementId': <String, dynamic>{'type': 'string'},
        'x': <String, dynamic>{'type': 'number'},
        'y': <String, dynamic>{'type': 'number'},
      },
    },
    handler: (args) async {
      final pos = _resolvePosition(bridge, args, optional: true);
      final result = _readEditableValue(pos);
      if (result == null) {
        return _text(
          '{"ok":false,"error":"no EditableText found at target / no focus"}',
          isError: true,
        );
      }
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'value': result.text,
          'hasFocus': result.hasFocus,
          'selection': <String, int>{
            'start': result.selStart,
            'end': result.selEnd,
          },
        }),
      );
    },
  );

  // ── studio.ui.popover_entries ───────────────────────────────────
  // Walk the widget tree for active `PopupMenuItem`s — covers
  // `showMenu`, `PopupMenuButton`, `DropdownButton`, and any custom
  // widget built on PopupMenuRoute. Returns each item's `value`,
  // visible text (best-effort: first RenderParagraph below the item)
  // and rect so callers can chain `studio.ui.tap` on a specific
  // entry by label without computing coordinates manually.
  boot.addTool(
    name: 'studio.ui.popover_entries',
    description:
        'Enumerate active PopupMenu / Dropdown items. Returns '
        '`{ok, count, entries:[{value, label, enabled, rect:[x,y,w,h]}]}`. '
        'Pair with `studio.ui.tap({x:rect[0]+rect[2]/2, y:rect[1]+rect[3]/2})` '
        'to pick a specific entry, or filter by `label` /`value` '
        'first. Empty when no popover is open.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final entries = <Map<String, dynamic>>[];
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) {
        return _text('{"ok":false,"error":"no root element"}', isError: true);
      }
      String? firstText(RenderObject root) {
        String? found;
        void walk(RenderObject ro) {
          if (found != null) return;
          if (ro is RenderParagraph) {
            final text = ro.text.toPlainText();
            if (text.isNotEmpty) {
              found = text;
              return;
            }
          }
          ro.visitChildren(walk);
        }

        walk(root);
        return found;
      }

      void visit(Element el) {
        final w = el.widget;
        if (w is PopupMenuEntry) {
          final ro = el.findRenderObject();
          double? x;
          double? y;
          double? width;
          double? height;
          if (ro is RenderBox && ro.attached && ro.hasSize) {
            final origin = ro.localToGlobal(Offset.zero);
            x = origin.dx;
            y = origin.dy;
            width = ro.size.width;
            height = ro.size.height;
          }
          String? label;
          if (ro is RenderBox) label = firstText(ro);
          String? value;
          bool enabled = true;
          if (w is PopupMenuItem) {
            value = w.value?.toString();
            enabled = w.enabled;
          }
          entries.add(<String, dynamic>{
            if (value != null) 'value': value,
            if (label != null) 'label': label,
            'enabled': enabled,
            if (x != null) 'rect': <double>[x, y!, width!, height!],
          });
        }
        el.visitChildren(visit);
      }

      root.visitChildren(visit);
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'count': entries.length,
          'entries': entries,
        }),
      );
    },
  );

  // ── studio.ui.key ───────────────────────────────────────────────
  // Synthesise a key press through the macOS / Flutter keyevent
  // platform channel. Supports a small set of named keys (`enter`,
  // `escape`, `tab`, `arrowUp/Down/Left/Right`, `backspace`) plus
  // a single printable character via `char`. Modifiers are a list
  // of `shift` / `ctrl` / `alt` / `meta` (Cmd). Use for keyboard
  // shortcuts (Cmd+S / Esc / Tab) that mouse automation can't
  // express.
  boot.addTool(
    name: 'studio.ui.key',
    description:
        'Synthesise a keyboard key press. `key` is a named key '
        '(`enter`, `escape`, `tab`, `arrowUp`, `arrowDown`, '
        '`arrowLeft`, `arrowRight`, `backspace`, `space`) OR `char` '
        'is a single printable character. `modifiers` is a list of '
        '`shift`/`ctrl`/`alt`/`meta`. Dispatched through Flutter\'s '
        'macOS keyevent platform channel so Focus / Shortcuts / '
        'CallbackShortcuts handlers fire. Returns `{ok, dispatched}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'key': <String, dynamic>{'type': 'string'},
        'char': <String, dynamic>{'type': 'string'},
        'modifiers': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
        },
      },
    },
    handler: (args) async {
      final keyName = (args['key'] as String?)?.toLowerCase();
      final charArg = (args['char'] as String?);
      final mods =
          (args['modifiers'] as List?)
              ?.whereType<String>()
              .map((s) => s.toLowerCase())
              .toSet() ??
          const <String>{};
      final spec = _resolveKey(keyName, charArg);
      if (spec == null) {
        return _text(
          '{"ok":false,"error":"need `key` (named) OR single-char `char`"}',
          isError: true,
        );
      }
      final dispatched = await _dispatchMacKey(spec, mods);
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': dispatched,
          'dispatched': dispatched,
        }),
      );
    },
  );

  // ── studio.ui.find ─────────────────────────────────────────────────
  //
  // Search the live layout snapshot by `query` against widget
  // `id` / `text` / `label` / `title` MetaData fields. Returns matching
  // elementIds + rects + matched field. Use to locate widgets without
  // knowing their exact id — e.g. find by visible "Inherit from Studio"
  // checkbox label.
  boot.addTool(
    name: 'studio.ui.find',
    description:
        'Search the live layout snapshot for widgets matching `query` '
        '(substring case-insensitive · use `exact:true` for exact '
        'case-sensitive match). Search field default = `any` (id / '
        'text / label / title all checked) · pass `field` to narrow. '
        'Returns `{count, matches:[{elementId, type, matchedField, '
        'matchedValue, rect, label?, text?, title?}, ...]}`. Use to '
        'find widgets when the exact elementId is unknown — e.g. '
        'locate the "Inherit from Studio" toggle by its visible label '
        'or find every dialog action button by `type:"dialog_action"`. '
        'Only widgets tagged with MetaData (see inspectTag) appear in '
        'results — see `studio.debug.layout_snapshot` for the canonical '
        'node enumeration.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'query': <String, dynamic>{
          'type': 'string',
          'description': 'Search string. Substring match by default.',
        },
        'exact': <String, dynamic>{
          'type': 'boolean',
          'description':
              'When true, exact case-sensitive equality match instead '
              'of substring. Default false.',
        },
        'field': <String, dynamic>{
          'type': 'string',
          'enum': <String>['any', 'id', 'text', 'label', 'title', 'type'],
          'description':
              'Which MetaData field to search. Default "any" = id / '
              'text / label / title all checked. Pass "type" to '
              'filter by widget type (e.g. "dialog_action").',
        },
        'limit': <String, dynamic>{
          'type': 'integer',
          'description': 'Cap on matches returned (default 50).',
        },
      },
      'required': <String>['query'],
    },
    handler: (args) async {
      final query = args['query'];
      if (query is! String || query.isEmpty) {
        return _text('{"error":"query (string) required"}', isError: true);
      }
      final exact = args['exact'] == true;
      final field = (args['field'] as String?) ?? 'any';
      final limit = (args['limit'] as int?) ?? 50;
      final fields =
          field == 'any'
              ? const <String>['id', 'text', 'label', 'title']
              : <String>[field];
      final fn = bridge.captureLayoutSnapshot;
      if (fn == null) {
        return _text(
          jsonEncode(<String, dynamic>{
            'count': 0,
            'matches': <Map<String, dynamic>>[],
            'reason': 'shell not mounted',
          }),
        );
      }
      final snap = await fn();
      if (snap == null) {
        return _text(
          jsonEncode(<String, dynamic>{
            'count': 0,
            'matches': <Map<String, dynamic>>[],
            'reason': 'capture root not attached',
          }),
        );
      }
      final q = exact ? query : query.toLowerCase();
      final matches = <Map<String, dynamic>>[];
      for (final n in snap) {
        for (final f in fields) {
          final v = n[f];
          if (v is String && v.isNotEmpty) {
            final hit = exact ? (v == q) : v.toLowerCase().contains(q);
            if (hit) {
              matches.add(<String, dynamic>{
                'elementId': n['id'] ?? v,
                'type': n['type'],
                'matchedField': f,
                'matchedValue': v,
                'rect': n['rect'],
                if (n['label'] != null) 'label': n['label'],
                if (n['text'] != null) 'text': n['text'],
                if (n['title'] != null) 'title': n['title'],
              });
              break;
            }
          }
        }
        if (matches.length >= limit) break;
      }
      return _text(
        jsonEncode(<String, dynamic>{
          'count': matches.length,
          'matches': matches,
        }),
      );
    },
  );

  // ── studio.ui.select ───────────────────────────────────────────────
  //
  // Macro for dropdown / popover-menu value change: open the dropdown
  // via `studio.ui.tap(elementId)`, list its entries via
  // `studio.ui.popover_entries`, find the entry matching `value`
  // (label substring or `entryId` exact), tap it. Single round-trip
  // instead of 3 manual calls.
  boot.addTool(
    name: 'studio.ui.select',
    description:
        'Macro: change a dropdown / popover-menu value. Opens the '
        'dropdown by tapping `elementId`, enumerates popover entries, '
        'finds the entry matching `value` (label substring · '
        'case-insensitive · or `entryId` exact match when present), '
        'taps it. Returns `{ok, tapped:{entryId, label, rect}, '
        'entries}`. Use to change Material `DropdownButton` / '
        '`PopupMenuButton` values without 3-step manual flow. The '
        'dropdown widget must be tagged with MetaData id matching '
        '`elementId`; entries must be tagged through '
        '`studio.ui.popover_entries` (PopupMenuItem auto-tags).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'elementId': <String, dynamic>{
          'type': 'string',
          'description': 'Dropdown widget elementId (from layout snapshot).',
        },
        'value': <String, dynamic>{
          'type': 'string',
          'description':
              'Entry label substring (case-insensitive) or `entryId` '
              'exact match.',
        },
        'exact': <String, dynamic>{
          'type': 'boolean',
          'description':
              'When true, exact case-sensitive label match instead of '
              'substring. Default false.',
        },
      },
      'required': <String>['elementId', 'value'],
    },
    handler: (args) async {
      final dropdownId = args['elementId'];
      final value = args['value'];
      if (dropdownId is! String || dropdownId.isEmpty) {
        return _text(
          '{"ok":false,"error":"elementId (string) required"}',
          isError: true,
        );
      }
      if (value is! String || value.isEmpty) {
        return _text(
          '{"ok":false,"error":"value (string) required"}',
          isError: true,
        );
      }
      final exact = args['exact'] == true;
      // 1. Open the dropdown via the existing tap path so any
      //    `PopupMenuButton` / `DropdownButton` `onTap` handler fires
      //    through Flutter's gesture pipeline.
      final tapRect = bridge.resolveElementRect?.call(dropdownId);
      if (tapRect == null) {
        return _text(
          '{"ok":false,"error":"dropdown elementId not found",'
          '"elementId":"$dropdownId"}',
          isError: true,
        );
      }
      final centerX = tapRect.left + tapRect.width / 2;
      final centerY = tapRect.top + tapRect.height / 2;
      await _dispatchTap(centerX, centerY);
      // Wait for popover to mount + paint. Material PopupMenu animates
      // for ~300ms; 400ms is generous.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      // 2. Enumerate popover entries via the layout snapshot.
      final fn = bridge.captureLayoutSnapshot;
      if (fn == null) {
        return _text('{"ok":false,"error":"shell not mounted"}', isError: true);
      }
      final snap = await fn();
      if (snap == null) {
        return _text(
          '{"ok":false,"error":"capture root not attached"}',
          isError: true,
        );
      }
      // Popover entries are tagged with `type: 'popover_entry'` by
      // the studio.ui.popover_entries instrumentation (see inspectTag).
      final entries = <Map<String, dynamic>>[
        for (final n in snap)
          if (n['type'] == 'popover_entry')
            <String, dynamic>{
              if (n['id'] != null) 'entryId': n['id'],
              if (n['label'] != null) 'label': n['label'],
              if (n['text'] != null) 'text': n['text'],
              if (n['rect'] != null) 'rect': n['rect'],
            },
      ];
      // 3. Find the matching entry.
      Map<String, dynamic>? hit;
      final q = exact ? value : value.toLowerCase();
      for (final e in entries) {
        final eid = e['entryId'];
        if (eid is String && eid == value) {
          hit = e;
          break;
        }
        for (final f in const <String>['label', 'text']) {
          final v = e[f];
          if (v is String && v.isNotEmpty) {
            final matched = exact ? (v == q) : v.toLowerCase().contains(q);
            if (matched) {
              hit = e;
              break;
            }
          }
        }
        if (hit != null) break;
      }
      if (hit == null) {
        return _text(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'no entry matched value',
            'value': value,
            'entries': entries,
          }),
        );
      }
      // 4. Tap the matched entry.
      final entryRect = hit['rect'];
      if (entryRect is! List || entryRect.length < 4) {
        return _text(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'matched entry has no rect',
            'hit': hit,
          }),
        );
      }
      final ex = (entryRect[0] as num).toDouble();
      final ey = (entryRect[1] as num).toDouble();
      final ew = (entryRect[2] as num).toDouble();
      final eh = (entryRect[3] as num).toDouble();
      await _dispatchTap(ex + ew / 2, ey + eh / 2);
      return _text(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'tapped': hit,
          'entries': entries,
        }),
      );
    },
  );
}

// ── helpers ────────────────────────────────────────────────────────

mk.KernelToolResult _text(String s, {bool isError = false}) =>
    mk.KernelToolResult(
      content: <mk.KernelContent>[mk.KernelTextContent(text: s)],
      isError: isError,
    );

Map<String, dynamic> _decode(mk.KernelToolResult r) {
  if (r.content.isEmpty || r.content.first is! mk.KernelTextContent) {
    return <String, dynamic>{};
  }
  final text = (r.content.first as mk.KernelTextContent).text;
  try {
    final d = jsonDecode(text);
    if (d is Map<String, dynamic>) return d;
    return <String, dynamic>{'value': d};
  } catch (_) {
    return <String, dynamic>{'text': text};
  }
}

Object? _jsonPathGet(Map<String, dynamic> json, String path) {
  Object? cur = json;
  for (final part in path.split('.')) {
    if (cur is Map && cur.containsKey(part)) {
      cur = cur[part];
    } else if (cur is List) {
      final idx = int.tryParse(part);
      if (idx == null || idx < 0 || idx >= cur.length) return null;
      cur = cur[idx];
    } else {
      return null;
    }
  }
  return cur;
}

Map<String, Map<String, dynamic>> _indexNodes(Map node) {
  final out = <String, Map<String, dynamic>>{};
  void walk(Object? n) {
    if (n is Map) {
      final id = n['elementId']?.toString();
      if (id != null && id.isNotEmpty) {
        out[id] = Map<String, dynamic>.from(n);
      }
      for (final v in n.values) {
        walk(v);
      }
    } else if (n is List) {
      for (final v in n) {
        walk(v);
      }
    }
  }

  walk(node);
  return out;
}

List<double>? _rect(Map node) {
  final r = node['rect'];
  if (r is Map &&
      r['x'] is num &&
      r['y'] is num &&
      r['w'] is num &&
      r['h'] is num) {
    return <double>[
      (r['x'] as num).toDouble(),
      (r['y'] as num).toDouble(),
      (r['w'] as num).toDouble(),
      (r['h'] as num).toDouble(),
    ];
  }
  if (r is List && r.length == 4 && r.every((e) => e is num)) {
    return r.cast<num>().map((e) => e.toDouble()).toList();
  }
  return null;
}

Future<Uint8List?> _captureRegion(
  ChromeBridge bridge,
  Rect rect,
  double pixelRatio,
) async {
  final rootKey = bridge.captureRootKey;
  if (rootKey == null) return null;
  final ro = rootKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) return null;
  if (!ro.attached || !ro.hasSize) return null;
  try {
    final fullImage = await ro.toImage(pixelRatio: pixelRatio);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final src = Rect.fromLTWH(
      rect.left * pixelRatio,
      rect.top * pixelRatio,
      rect.width * pixelRatio,
      rect.height * pixelRatio,
    );
    final dst = Rect.fromLTWH(0, 0, rect.width, rect.height);
    canvas.drawImageRect(fullImage, src, dst, ui.Paint());
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(
      rect.width.toInt(),
      rect.height.toInt(),
    );
    final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

Future<void> _dispatchTap(double x, double y, {int holdMs = 40}) async {
  final binding = GestureBinding.instance;
  final position = Offset(x, y);
  final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
  final pointer = _nextPointer++;
  final kind = _pointerKind();
  // Explicit hit-test → dispatchEvent so the event traverses the
  // same widget chain a real pointer would. Calling
  // `handlePointerEvent` alone does NOT add the pointer to the
  // binding's `_hitTests` map, so the matching `up` lands without a
  // target and `onTap` never fires. Two-step (hitTest + dispatchEvent)
  // matches Flutter's PointerEventConverter pipeline.
  final downEvent = PointerDownEvent(
    timeStamp: now,
    pointer: pointer,
    position: position,
    kind: kind,
  );
  final hitResult = HitTestResult();
  binding.hitTest(hitResult, position);
  binding.dispatchEvent(downEvent, hitResult);
  await Future<void>.delayed(Duration(milliseconds: holdMs));
  binding.dispatchEvent(
    PointerUpEvent(
      timeStamp: now + Duration(milliseconds: holdMs),
      pointer: pointer,
      position: position,
      kind: kind,
    ),
    hitResult,
  );
}

int _nextPointer = 1_000_000;

PointerDeviceKind _pointerKind() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.android:
      return PointerDeviceKind.touch;
    default:
      return PointerDeviceKind.mouse;
  }
}

/// Resolve a position from either `elementId` (rect centre) or
/// explicit `x`+`y`. Returns null when neither resolves. When
/// `optional` is true, returns null silently instead of erroring so
/// callers (e.g. `studio.ui.element_value`) can fall back to "current
/// focus" semantics.
Offset? _resolvePosition(
  ChromeBridge bridge,
  Map<String, dynamic> args, {
  bool optional = false,
}) {
  final elementId = args['elementId'] as String?;
  if (elementId != null && elementId.isNotEmpty) {
    final rect = bridge.resolveElementRect?.call(elementId);
    if (rect != null) return rect.center;
    if (optional) return null;
    return null;
  }
  final x = (args['x'] as num?)?.toDouble();
  final y = (args['y'] as num?)?.toDouble();
  if (x == null || y == null) return null;
  return Offset(x, y);
}

Future<void> _dispatchScroll(double x, double y, double dx, double dy) async {
  final binding = GestureBinding.instance;
  final pos = Offset(x, y);
  final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
  final hitResult = HitTestResult();
  binding.hitTest(hitResult, pos);
  binding.dispatchEvent(
    PointerScrollEvent(
      timeStamp: now,
      position: pos,
      scrollDelta: Offset(dx, dy),
      kind: PointerDeviceKind.mouse,
    ),
    hitResult,
  );
}

Future<void> _dispatchHover(double x, double y) async {
  final binding = GestureBinding.instance;
  final pos = Offset(x, y);
  final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
  final hitResult = HitTestResult();
  binding.hitTest(hitResult, pos);
  binding.dispatchEvent(
    PointerHoverEvent(
      timeStamp: now,
      position: pos,
      kind: PointerDeviceKind.mouse,
    ),
    hitResult,
  );
}

Future<void> _dispatchSecondaryTap(double x, double y) async {
  final binding = GestureBinding.instance;
  final pos = Offset(x, y);
  final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
  final pointer = _nextPointer++;
  final hitResult = HitTestResult();
  binding.hitTest(hitResult, pos);
  binding.dispatchEvent(
    PointerDownEvent(
      timeStamp: now,
      pointer: pointer,
      position: pos,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    ),
    hitResult,
  );
  await Future<void>.delayed(const Duration(milliseconds: 40));
  binding.dispatchEvent(
    PointerUpEvent(
      timeStamp: now + const Duration(milliseconds: 40),
      pointer: pointer,
      position: pos,
      kind: PointerDeviceKind.mouse,
      buttons: 0,
    ),
    hitResult,
  );
}

Future<void> _dispatchDrag(Offset from, Offset to, int steps) async {
  final binding = GestureBinding.instance;
  final pointer = _nextPointer++;
  final kind = _pointerKind();
  final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
  final hitResult = HitTestResult();
  binding.hitTest(hitResult, from);
  binding.dispatchEvent(
    PointerDownEvent(
      timeStamp: now,
      pointer: pointer,
      position: from,
      kind: kind,
    ),
    hitResult,
  );
  // Drag must emit at least one PointerMoveEvent before up so
  // GestureRecognizers (HorizontalDrag / VerticalDrag / Pan) accept it.
  for (var i = 1; i <= steps; i++) {
    final t = i / steps;
    final p = Offset.lerp(from, to, t)!;
    final ts = now + Duration(milliseconds: 16 * i);
    binding.dispatchEvent(
      PointerMoveEvent(
        timeStamp: ts,
        pointer: pointer,
        position: p,
        delta: p - Offset.lerp(from, to, (i - 1) / steps)!,
        kind: kind,
      ),
      hitResult,
    );
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
  binding.dispatchEvent(
    PointerUpEvent(
      timeStamp: now + Duration(milliseconds: 16 * (steps + 1)),
      pointer: pointer,
      position: to,
      kind: kind,
    ),
    hitResult,
  );
}

bool _focusAt(Offset pos) {
  final binding = GestureBinding.instance;
  final hitResult = HitTestResult();
  binding.hitTest(hitResult, pos);
  // Walk the hit-test path looking for an enclosing Focus / FocusableActionDetector.
  for (final entry in hitResult.path) {
    final t = entry.target;
    if (t is RenderObject) {
      RenderObject? ro = t;
      while (ro != null) {
        final node = ro.debugCreator;
        if (node != null) {
          // Best-effort: use the surrounding Element to look up a Focus.
        }
        ro = ro.parent;
      }
    }
  }
  // Walk the widget tree looking for a Focus / EditableText at pos.
  FocusNode? target;
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return false;
  void visit(Element el) {
    if (target != null) return;
    final ro = el.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize) {
      final origin = ro.localToGlobal(Offset.zero);
      final rect = origin & ro.size;
      if (rect.contains(pos)) {
        final w = el.widget;
        if (w is EditableText) {
          target = w.focusNode;
        } else if (w is Focus) {
          target = w.focusNode ?? Focus.maybeOf(el);
        }
      }
    }
    el.visitChildren(visit);
  }

  root.visitChildren(visit);
  if (target != null) {
    target!.requestFocus();
    return true;
  }
  return false;
}

class _EditableSnapshot {
  _EditableSnapshot({
    required this.text,
    required this.hasFocus,
    required this.selStart,
    required this.selEnd,
  });
  final String text;
  final bool hasFocus;
  final int selStart;
  final int selEnd;
}

_EditableSnapshot? _readEditableValue(Offset? pos) {
  EditableTextState? found;
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return null;
  void visit(Element el) {
    if (found != null) return;
    final w = el.widget;
    if (w is EditableText) {
      // Position-based filter: when pos is supplied, only accept the
      // EditableText whose render box contains the target. Otherwise
      // accept the first focused one.
      final state = (el as StatefulElement).state;
      if (state is EditableTextState) {
        if (pos == null) {
          if (state.widget.focusNode.hasFocus) {
            found = state;
            return;
          }
        } else {
          final ro = el.findRenderObject();
          if (ro is RenderBox && ro.attached && ro.hasSize) {
            final origin = ro.localToGlobal(Offset.zero);
            final rect = origin & ro.size;
            if (rect.contains(pos)) {
              found = state;
              return;
            }
          }
        }
      }
    }
    el.visitChildren(visit);
  }

  root.visitChildren(visit);
  // No exact match — when caller didn't specify a position, fall
  // back to the first EditableText in the tree (handy for dialogs
  // that only contain one field).
  if (found == null && pos == null) {
    void firstVisit(Element el) {
      if (found != null) return;
      final w = el.widget;
      if (w is EditableText) {
        final state = (el as StatefulElement).state;
        if (state is EditableTextState) found = state;
      }
      el.visitChildren(firstVisit);
    }

    root.visitChildren(firstVisit);
  }
  if (found == null) return null;
  final ctrl = found!.textEditingValue;
  return _EditableSnapshot(
    text: ctrl.text,
    hasFocus: found!.widget.focusNode.hasFocus,
    selStart: ctrl.selection.start,
    selEnd: ctrl.selection.end,
  );
}

class _KeySpec {
  _KeySpec({
    required this.keyCode,
    required this.logical,
    required this.characters,
  });
  final int keyCode;
  final int logical;
  final String characters;
}

_KeySpec? _resolveKey(String? named, String? char) {
  if (named != null) {
    switch (named) {
      // macOS keyCode / logical key id from
      // `flutter/lib/src/services/keyboard_maps.g.dart`.
      case 'enter':
        return _KeySpec(keyCode: 36, logical: 0x10000000d, characters: '\n');
      case 'escape':
        return _KeySpec(keyCode: 53, logical: 0x100000001b, characters: '');
      case 'tab':
        return _KeySpec(keyCode: 48, logical: 0x100000009, characters: '\t');
      case 'arrowup':
        return _KeySpec(keyCode: 126, logical: 0x100000301, characters: '');
      case 'arrowdown':
        return _KeySpec(keyCode: 125, logical: 0x100000303, characters: '');
      case 'arrowleft':
        return _KeySpec(keyCode: 123, logical: 0x100000302, characters: '');
      case 'arrowright':
        return _KeySpec(keyCode: 124, logical: 0x100000304, characters: '');
      case 'backspace':
        return _KeySpec(keyCode: 51, logical: 0x100000008, characters: '');
      case 'space':
        return _KeySpec(keyCode: 49, logical: 0x20, characters: ' ');
    }
  }
  if (char != null && char.isNotEmpty) {
    final ch = char.substring(0, 1);
    // Crude: rely on Flutter's RawKeyboard event path tolerating an
    // unknown keyCode (0) when `characters` carries the printable.
    return _KeySpec(keyCode: 0, logical: ch.codeUnitAt(0), characters: ch);
  }
  return null;
}

Future<bool> _dispatchMacKey(_KeySpec spec, Set<String> mods) async {
  // macOS modifier bitfield matches Flutter's `modifierShift / Control /
  // Option / Command` in keyboard_maps.g.dart.
  const modifierShift = 0x20002;
  const modifierControl = 0x40001;
  const modifierOption = 0x80004;
  const modifierCommand = 0x100008;
  var modifiers = 0;
  if (mods.contains('shift')) modifiers |= modifierShift;
  if (mods.contains('ctrl') || mods.contains('control'))
    modifiers |= modifierControl;
  if (mods.contains('alt') || mods.contains('option'))
    modifiers |= modifierOption;
  if (mods.contains('meta') ||
      mods.contains('cmd') ||
      mods.contains('command')) {
    modifiers |= modifierCommand;
  }
  final binding = ServicesBinding.instance;
  Future<void> send(String type) async {
    final payload = <String, dynamic>{
      'type': type,
      'keymap': 'macos',
      'keyCode': spec.keyCode,
      'modifiers': modifiers,
      'characters': spec.characters,
      'charactersIgnoringModifiers': spec.characters,
      if (spec.logical != 0) 'specifiedLogicalKey': spec.logical,
    };
    final bytes = const StandardMessageCodec().encodeMessage(payload);
    final completer = Completer<void>();
    binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/keyevent',
      bytes,
      (_) => completer.complete(),
    );
    await completer.future;
  }

  try {
    await send('keydown');
    await Future<void>.delayed(const Duration(milliseconds: 24));
    await send('keyup');
    return true;
  } catch (_) {
    return false;
  }
}
