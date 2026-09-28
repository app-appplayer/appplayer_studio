/// Renders a UI DSL definition to PNG without touching what the user sees.
///
/// The definition mounts through the same runtime port the editor preview
/// uses ([McpUiRuntimePort]), inside an overlay entry placed outside the
/// visible window, and is captured from its own [RepaintBoundary]. The entry
/// is removed whether the capture succeeds or not.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:appplayer_ui_view/appplayer_ui_view.dart' show UiTargetSnapshot;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../widgets/preview_mcp_ui.dart' show McpUiRuntimePort;

/// Frames to let the runtime lay out and paint before capturing. The
/// runtime builds synchronously once initialized; the extra frames cover
/// image and font resolution that lands one frame late.
const int _settleFrames = 3;

Future<Uint8List> renderDslOffscreen({
  required OverlayState overlay,
  required Map<String, dynamic> definition,
  required Size size,
  double pixelRatio = 1.0,
}) async {
  final widget = await McpUiRuntimePort().render(
    UiTargetSnapshot(
      target: 'mcp-ui:offscreen',
      data: definition,
      sourceHash: '${definition.hashCode}',
    ),
  );
  final key = GlobalKey();
  final entry = OverlayEntry(
    builder:
        (_) => Positioned(
          // Outside the window: laid out and painted, never visible or hit.
          left: -(size.width + 10000),
          top: 0,
          width: size.width,
          height: size.height,
          child: IgnorePointer(
            child: RepaintBoundary(key: key, child: Material(child: widget)),
          ),
        ),
  );
  overlay.insert(entry);
  try {
    final binding = WidgetsBinding.instance;
    for (var i = 0; i < _settleFrames; i++) {
      binding.scheduleFrame();
      await binding.endOfFrame;
    }
    final ro = key.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize) {
      throw StateError('offscreen surface did not mount');
    }
    final image = await ro.toImage(pixelRatio: pixelRatio);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('PNG encoding returned no data');
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    entry.remove();
  }
}
