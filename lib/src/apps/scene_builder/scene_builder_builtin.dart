import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show
        BuiltInApp,
        BuiltInLauncher,
        BuiltinToolRegistry,
        ChromeBridge,
        StudioBackbone,
        VibeChatController;
// Builtin = OS-level app · uses host wrapper API only.
// Zero direct `package:brain_kernel` / `mcp_host` / `mcp_server` imports
// (aligned with builtin-os-cleanup Phase 1+4).

import 'feat/scene_shell.dart';

/// Scene Builder as a vibe_studio built-in app.
///
/// Authoring surface for scenario-driven recordings — the user composes
/// a SCENARIO (sequence of MCP tool calls + overlay annotations), runs
/// it with the recorder on, and exports the result. The shell exposes
/// four modes — Scenarios (library) / Edit / Recordings / Branding —
/// all driven through host built-in tools (`studio.recorder.*`,
/// `studio.overlay.*`, `studio.scenario.*`).
class SceneBuilderBuiltInApp extends BuiltInApp {
  const SceneBuilderBuiltInApp();

  @override
  String get id => 'scene_builder';

  @override
  String get label => 'Scene Builder';

  /// Marker file written by [launcher.onLaunch] so [canHandle]
  /// recognises the launch path before any user project exists.
  static const String _builtInMarker = '.builtin_scene_builder';

  @override
  bool canHandle(String bundlePath) {
    final dir = Directory(bundlePath);
    if (!dir.existsSync()) return false;
    return File(p.join(bundlePath, _builtInMarker)).existsSync();
  }

  @override
  BuiltInLauncher launcher(ChromeBridge chromeBridge, String workspaceDir) {
    final defaultDir = p.join(workspaceDir, 'scene_builder');
    final dir = Directory(defaultDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final marker = File(p.join(defaultDir, _builtInMarker));
    if (!marker.existsSync()) {
      marker.writeAsStringSync('');
    }
    return BuiltInLauncher(
      id: id,
      label: label,
      iconName: 'movie_creation',
      launchPath: defaultDir,
      onLaunch: () async {
        /* marker already exists from `launcher()` */
      },
    );
  }

  @override
  Widget mount({
    required BuildContext context,
    required String bundlePath,
    required ChromeBridge chromeBridge,
    required dynamic Function(String tabKey) chatLookup,
    required String tabKey,
    required BuiltinToolRegistry
    server, // unused — Scene Builder doesn't register tools yet
    required StudioBackbone backbone,
    Map<String, Object?> inheritedSettings = const <String, Object?>{},
    String overridesFile = '',
  }) {
    final chat = chatLookup(tabKey) as VibeChatController;
    return SceneShell(
      key: ValueKey('scene_builder::$bundlePath'),
      bundlePath: bundlePath,
      chromeBridge: chromeBridge,
      chat: chat,
    );
  }
}
