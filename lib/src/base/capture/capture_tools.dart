/// Single entry point — `registerCaptureTools` wires the four
/// `studio.recorder.* / studio.overlay.* / studio.chat.send` families
/// onto a `ServerBootstrap`. The host calls this once during
/// `registerMcpTools`; the bundle layer never invokes it directly.
///
/// Module boundary: `capture/` depends only on `main/chrome_bridge.dart`
/// (capture / overlay rect resolution slots) and the kernel's
/// `ServerBootstrap`. No other base-internal module imports `capture/`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/chrome_bridge.dart';
import 'input/chat_tools.dart';
import 'overlay/overlay_controller.dart';
import 'overlay/overlay_tools.dart';
import 'recorder/encoder_service.dart';
import 'recorder/recorder_service.dart';
import 'recorder/recorder_tools.dart';
import 'recorder/video_edit_service.dart';
import 'recorder/video_edit_tools.dart';
import 'scenario/scenario_engine.dart';
import 'scenario/scenario_tools.dart';
import 'scene_project/scene_project_tools.dart';

class CaptureSurface {
  CaptureSurface({
    required this.recorder,
    required this.encoder,
    required this.overlayController,
    required this.scenarioEngine,
  });
  final RecorderService recorder;
  final EncoderService encoder;
  final OverlayController overlayController;
  final ScenarioEngine scenarioEngine;
}

/// Build the runtime surface and register every `studio.recorder.*`,
/// `studio.overlay.*`, `studio.chat.send`, and `studio.scenario.*`
/// MCP tool. Returns the [CaptureSurface] so the host can hand the
/// overlay controller to the shell (for `OverlayLayer` mounting) and
/// the recorder / scenario engine to anything that needs to poke at
/// state (rare).
///
/// `seedScenarioDirs` lets the host point the scenario tools at
/// additional scenario folders (typically the `scenarios/` directory
/// inside `scene_builder.mbd` so its bundled scenarios show up under
/// `studio.scenario.list` with `source:'seed'`).
CaptureSurface registerCaptureTools(
  mk.KernelServerHost boot, {
  required ChromeBridge bridge,
  required String configRoot,
  SeedScenarioDirsResolver? seedScenarioDirs,
}) {
  final recorder = RecorderService(bridge: bridge, configRoot: configRoot);
  final encoder = EncoderService();
  final overlayController = OverlayController();
  final scenarioEngine = ScenarioEngine(
    boot: boot,
    recorder: recorder,
    encoder: encoder,
    overlays: overlayController,
    chromeBridge: bridge,
  );
  registerRecorderTools(boot, recorder: recorder, encoder: encoder);
  // Video editing (trim / concat of existing clips) — `studio.video.*`.
  registerVideoEditTools(boot, service: VideoEditService());
  registerOverlayTools(boot, controller: overlayController);
  registerChatTools(boot, bridge: bridge);
  // Last-seen scene project memo. The resolver below latches onto the
  // most recent active tab whose `currentProject` carried a
  // `scene.json` marker; subsequent calls return the cached path even
  // when focus moves to a tab without one (e.g. r1 selects Home, then
  // r2~r6's `studio.scenario.run` calls still find the sample
  // project's `scenarios/`). The cache is process-local; reboots
  // start empty and the first active scene project re-latches.
  String? lastSeenSceneProjectScenariosDir;
  registerScenarioTools(
    boot,
    engine: scenarioEngine,
    configRoot: configRoot,
    seedScenarioDirs: seedScenarioDirs,
    activeProjectScenariosDir: () {
      // Resolve `<projectPath>/scenarios/` ONLY when the active tab's
      // currentProject carries a `scene.json` marker — keeps Studio
      // Builder's mbd projects from spilling scenarios into themselves
      // (their currentProject is the package being authored, not a
      // scene project). When no scene project is active right now,
      // fall back to the last one we saw so cross-step lookups don't
      // race the active-tab pointer.
      final info = SceneProjectScope.info() ?? bridge.activeProjectInfo?.call();
      final path = info?['projectPath']?.toString();
      if (path != null &&
          path.isNotEmpty &&
          File(p.join(path, 'scene.json')).existsSync()) {
        final dir = p.join(path, 'scenarios');
        lastSeenSceneProjectScenariosDir = dir;
        return dir;
      }
      return lastSeenSceneProjectScenariosDir;
    },
  );
  registerSceneProjectTools(boot, bridge: bridge, configRoot: configRoot);
  return CaptureSurface(
    recorder: recorder,
    encoder: encoder,
    overlayController: overlayController,
    scenarioEngine: scenarioEngine,
  );
}
