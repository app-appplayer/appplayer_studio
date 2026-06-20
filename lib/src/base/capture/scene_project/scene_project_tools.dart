/// Scene-project lifecycle — same shape as Studio Builder's project
/// lifecycle, but the on-disk schema is scene-shaped (scenarios /
/// recordings / branding / assets) rather than `.mbd`. The active
/// scene_builder tab's `currentProject` points at this folder; the
/// recorder + scenario engine read its `recordings/` and `scenarios/`
/// subdirs when set, falling back to `<configRoot>/...` when not.
///
/// Three tools registered:
/// - `studio.scene.project.new` — scaffold + open
/// - `studio.scene.project.open` — validate + adopt as active
/// - `studio.scene.project.info` — current scene project snapshot
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../../agent/agent_host.dart';
import '../../main/chrome_bridge.dart';

/// Per-scene-project chat-context isolation — ensure a scene-project-scoped
/// manager (`<sceneManager>.<projectId>`) exists and route the chat to it via
/// `chatManagerOverride`, so the Scene Builder chat conversation doesn't carry
/// across scene projects (FlowBrain keys conversations by agentId). Mirrors
/// App Builder's per-project manager. Best-effort — silent on any failure.
Future<void> _applySceneScopedManager(
  ChromeBridge bridge,
  String projectPath,
) async {
  final base = bridge.activeChatAgentId.value;
  if (base.isEmpty) return;
  try {
    // Scope by the scene project's FULL path, not its basename — two scene
    // projects sharing a folder name under different parents are distinct
    // units and must not share a conversation. Sanitised into the agent id by
    // `ensureScopedManager`.
    final qualified = await AgentHost.shared?.ensureScopedManager(
      base,
      projectPath,
    );
    if (qualified != null) bridge.chatManagerOverride.value = qualified;
  } catch (_) {
    /* best-effort */
  }
}

/// Process-global active scene project — the source of truth for project
/// scoping. The chrome `openProjectInActive` / `activeProjectInfo` bridge slots
/// are only wired while the scene tab's shell is the active dependency (which
/// is fragile under MCP-driven `select_tab`), so the scene project tools, the
/// recorder, and scenario dir-scoping read THIS static. Set by
/// `studio.scene.project.open` / `.new`; cleared by nothing (the last opened
/// project stays active until another is opened).
class SceneProjectScope {
  SceneProjectScope._();

  static String? activePath;

  /// `{projectPath, projectName}` for the active scene project, or null.
  static Map<String, dynamic>? info() {
    final ap = activePath;
    if (ap == null || ap.isEmpty) return null;
    return <String, dynamic>{'projectPath': ap, 'projectName': p.basename(ap)};
  }
}

/// Scaffold + adopt a new scene project at `<parent>/<slug(name)>` — the
/// scene-shaped layout (`scene.json` + scenarios/recordings/branding/assets),
/// then set it active (process-global scope + host chat re-key + scoped
/// manager + bridge adopt). Shared by the `studio.scene.project.new` tool AND
/// the host chrome `newProjectInActive` slot (wired by the Scene shell) so the
/// generic `studio.project.new` on a Scene tab creates a real scene project
/// instead of the host's empty-dir `_doNewProject`. Returns
/// `{ok, projectPath, adopted}` or `{ok: false, error}`.
Future<Map<String, dynamic>> createSceneProjectAt({
  required ChromeBridge bridge,
  required String name,
  required String parent,
  String? title,
}) async {
  if (name.trim().isEmpty) {
    return <String, dynamic>{'ok': false, 'error': 'name required'};
  }
  if (parent.isEmpty) {
    return <String, dynamic>{
      'ok': false,
      'error': 'parent (workspaceDir) not configured',
    };
  }
  final root = p.join(parent, _safeSlug(name));
  if (await Directory(root).exists()) {
    return <String, dynamic>{
      'ok': false,
      'error': 'project already exists at $root',
    };
  }
  try {
    await Directory(root).create(recursive: true);
    for (final sub in const <String>[
      'scenarios',
      'recordings',
      'branding',
      'assets',
    ]) {
      await Directory(p.join(root, sub)).create(recursive: true);
    }
    final meta = <String, dynamic>{
      'kind': 'scene_project',
      'name': name,
      'title': title ?? name,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    await File(
      p.join(root, 'scene.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
  } catch (e) {
    return <String, dynamic>{'ok': false, 'error': 'scaffold failed: $e'};
  }
  // Adopt as active — process-global scope is source of truth; chat re-key +
  // scoped manager + bridge adopt layer on top.
  SceneProjectScope.activePath = root;
  bridge.setActiveTabProject?.call(root);
  await _applySceneScopedManager(bridge, root);
  final adopt = bridge.openProjectInActive;
  if (adopt != null) {
    try {
      await adopt(root);
    } catch (_) {
      /* best-effort — bridge adoption */
    }
  }
  return <String, dynamic>{'ok': true, 'projectPath': root, 'adopted': true};
}

void registerSceneProjectTools(
  mk.KernelServerHost boot, {
  required ChromeBridge bridge,
  required String configRoot,
}) {
  Future<String?> readWorkspaceDir() async {
    final f = File(p.join(configRoot, 'settings.json'));
    if (!await f.exists()) return null;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map<String, dynamic>) {
        final v = raw['workspaceDir'];
        if (v is String && v.isNotEmpty) return v;
      }
    } catch (_) {
      /* swallow */
    }
    return null;
  }

  boot.addTool(
    name: 'studio.scene.project.new',
    description:
        'Create a new Scene Builder project — a directory with '
        '`scene.json` (project meta) + `scenarios/` + `recordings/` + '
        '`branding/` + `assets/`. Adopts the new folder as the active '
        "Scene Builder tab's `currentProject` so subsequent "
        'recorder + scenario calls land inside the project (instead of '
        '`<configRoot>/recordings/...`). Parent dir defaults to the '
        "studio's `workspaceDir` setting (see "
        '[[feedback_use_workspace_dir]]). Returns `{ok, projectPath}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'name': <String, dynamic>{
          'type': 'string',
          'description':
              'Project directory name (kebab / snake / '
              'plain — any path-safe string).',
        },
        'parent': <String, dynamic>{
          'type': 'string',
          'description': 'Parent directory. Default: workspaceDir.',
        },
        'title': <String, dynamic>{
          'type': 'string',
          'description': 'Human-friendly title stored in scene.json.',
        },
      },
      'required': <String>['name'],
    },
    handler: (args) async {
      final name = args['name'] as String?;
      if (name == null || name.trim().isEmpty) {
        return _err('name required');
      }
      final parent = args['parent'] as String? ?? await readWorkspaceDir();
      if (parent == null || parent.isEmpty) {
        return _err(
          'workspaceDir not configured — pass `parent` or '
          'set workspaceDir in Settings',
        );
      }
      final r = await createSceneProjectAt(
        bridge: bridge,
        name: name,
        parent: parent,
        title: args['title']?.toString(),
      );
      if (r['ok'] != true) return _err(r['error']?.toString() ?? 'failed');
      return mk.KernelToolResult(
        content: <mk.KernelContent>[mk.KernelTextContent(text: jsonEncode(r))],
      );
    },
  );

  boot.addTool(
    name: 'studio.scene.project.open',
    description:
        'Open an existing Scene Builder project — verifies a '
        '`scene.json` is present, then adopts the folder as the active '
        "tab's `currentProject`. Returns `{ok, projectPath}`. Use this "
        "to switch between scene projects without leaving the tab.",
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the scene project folder.',
        },
      },
      'required': <String>['path'],
    },
    handler: (args) async {
      final path = args['path'] as String?;
      if (path == null || path.isEmpty) return _err('path required');
      final meta = File(p.join(path, 'scene.json'));
      if (!await meta.exists()) {
        return _err('not a scene project (missing scene.json): $path');
      }
      // Source of truth = the process-global scope; bridge adopt is best-effort.
      SceneProjectScope.activePath = path;
      // Re-key the host chat panel to this project so the previous project's
      // chat doesn't linger when switching scene projects.
      bridge.setActiveTabProject?.call(path);
      await _applySceneScopedManager(bridge, path);
      final adopt = bridge.openProjectInActive;
      if (adopt != null) {
        try {
          await adopt(path);
        } catch (_) {
          /* best-effort */
        }
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'projectPath': path,
            }),
          ),
        ],
      );
    },
  );

  boot.addTool(
    name: 'studio.scene.project.info',
    description:
        "Snapshot of the active tab's Scene Builder project — "
        '`{projectPath, projectName, meta}`. `meta` is the parsed '
        '`scene.json` content. Returns `{active: false}` when no '
        'scene project is currently set on the active tab.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      // Prefer the process-global scope (always set by open/new); fall back to
      // the bridge slot if some other surface wired it.
      final info = SceneProjectScope.info() ?? bridge.activeProjectInfo?.call();
      final projectPath = info?['projectPath']?.toString();
      if (projectPath == null || projectPath.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"active":false}'),
          ],
        );
      }
      final metaFile = File(p.join(projectPath, 'scene.json'));
      Map<String, dynamic>? meta;
      if (await metaFile.exists()) {
        try {
          final raw = jsonDecode(await metaFile.readAsString());
          if (raw is Map<String, dynamic>) meta = raw;
        } catch (_) {
          /* corrupt — meta null */
        }
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'active': meta != null,
              'projectPath': projectPath,
              if (info?['projectName'] != null)
                'projectName': info!['projectName'],
              if (meta != null) 'meta': meta,
            }),
          ),
        ],
      );
    },
  );
}

mk.KernelToolResult _err(String msg) => mk.KernelToolResult(
  content: <mk.KernelContent>[
    mk.KernelTextContent(
      text: jsonEncode(<String, dynamic>{'ok': false, 'error': msg}),
    ),
  ],
);

String _safeSlug(String s) {
  final cleaned = StringBuffer();
  for (final code in s.codeUnits) {
    if ((code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5a) ||
        (code >= 0x61 && code <= 0x7a) ||
        code == 0x5f ||
        code == 0x2d) {
      cleaned.writeCharCode(code);
    } else if (code == 0x20) {
      cleaned.writeCharCode(0x5f);
    }
  }
  final out = cleaned.toString();
  return out.isEmpty ? 'scene_${DateTime.now().millisecondsSinceEpoch}' : out;
}
