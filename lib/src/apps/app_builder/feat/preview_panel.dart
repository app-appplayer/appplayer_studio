// App Builder uses the platform's preview panel. The generic device
// surface — toolbar, device frame, tracks, size/orient/brightness, the
// renderer seam ([PreviewVariant]) — now lives in `base`. App Builder
// keeps only its own *policy*: the Studio-package preview mounts a
// `DslWorkspaceView` (vbu_* atoms + dsl via the namespaced runtime).
//
// The previous fork copied the whole ~1k-line surface to inject that one
// body. That duplication is gone: this re-exports the host panel and
// declares the single variant. AppPlayer-app projects pass no variant and
// get the default `PreviewMcpUi` body — exactly like any other consumer
// (a future bundle can declare the same variant with no host change).
export '../../../base/widgets/preview_panel.dart';

import 'package:flutter/material.dart';

import '../../../base/widgets/preview_panel.dart'
    show PreviewVariant, PreviewBodyContext;
import 'package:appplayer_studio/base.dart' show ChromeBridge;
import 'package:appplayer_studio/workspace.dart' show DslWorkspaceView;

/// App Builder's Studio-package preview policy as a [PreviewVariant] the
/// host panel renders. The body mounts the namespaced studio runtime
/// ([DslWorkspaceView]) so vbu_* atoms and domain widgets show, hard-sized
/// to the canonical canvas and centred in an InteractiveViewer (zoom / pan;
/// Reset view re-mounts + recentres via the panel's transform). The chrome
/// is tuned: unframed (the bezel is drawn here), custom-size only (desktop
/// authoring), minimal toolbar (single applicable track, self-remounting).
///
/// Callers pass this variant only for `studioPackage` projects with a
/// bundle on disk; everything else passes null and gets `PreviewMcpUi`.
PreviewVariant studioPackagePreviewVariant({
  required String bundlePath,
  ChromeBridge? chromeBridge,
  String? hostTabKey,
}) {
  return PreviewVariant(
    framed: false,
    customSizeOnly: true,
    minimalToolbar: true,
    buildBody: (PreviewBodyContext ctx) {
      final logical = ctx.frame.logicalSize;
      final bezel = ctx.frame.bezel;
      // The runtime ignores DeviceFrame, so we hard-fit the canonical
      // canvas size and let the embedded view expand into it — visually
      // matching the UiView fit the AppPlayer path gets for free.
      Widget canvas = SizedBox(
        width: logical.width,
        height: logical.height,
        child: DslWorkspaceView(
          // bundlePath + combined reset epoch in the key so manual refresh
          // and reactive canonical updates both tear down + re-mount.
          key: ValueKey<String>('dsl:$bundlePath:${ctx.resetEpoch}'),
          bundlePath: bundlePath,
          chromeBridge: chromeBridge,
          previewMode: ctx.previewMode,
          gateTabKey: hostTabKey,
          // Inspect wiring — same selection path the AppPlayer preview
          // uses, so clicking in the embedded workspace lights up the
          // shell's properties pane.
          selectedWidgetPath: ctx.selectedWidgetPath,
          onSelectWidget: ctx.onSelectWidget,
          inspectRoot: ctx.inspectRoot,
        ),
      );
      // Draw the frame's bezel chrome manually (the drawn fallback when
      // `image` is null) so the workspace canvas matches the AppPlayer
      // preview's screen-edge cue.
      if (bezel != null) {
        canvas = Container(
          padding: EdgeInsets.all(bezel.thickness),
          decoration: BoxDecoration(
            color: bezel.color,
            borderRadius: BorderRadius.circular(bezel.cornerRadius),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(
              (bezel.cornerRadius - bezel.thickness).clamp(
                0.0,
                double.infinity,
              ),
            ),
            child: canvas,
          ),
        );
      }
      return InteractiveViewer(
        transformationController: ctx.transform,
        minScale: 0.1,
        maxScale: 4.0,
        boundaryMargin: const EdgeInsets.all(double.infinity),
        child: Center(child: canvas),
      );
    },
  );
}
