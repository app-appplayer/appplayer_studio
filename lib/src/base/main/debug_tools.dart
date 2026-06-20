/// `registerDebugTools` — register the 5 `studio.debug.*` MCP tools
/// (host introspection: config dump, tab snapshot, chrome bridge
/// wiring, bundle registry dump) onto a kernel `ServerBootstrap`.
///
/// Lifted verbatim from `vibe_studio_host_app.dart` so every studio
/// host shares the same debugging surface. Handlers route through
/// [ChromeBridge] callbacks for tab / config snapshots (mounted by the
/// host's centre widget) and [BundleInstallSurface] for the bundle
/// registry dump. The static identity fields (`toolId`, `displayName`,
/// `defaultPort`) are injected so the body stays domain-free.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../agent/agent_host.dart';
import '../settings/vibe_settings.dart';
import 'bundle_install_surface.dart';
import 'chrome_bridge.dart';

/// Register the 4 `studio.debug.*` tools onto [boot]:
///
/// - `studio.debug.config` — `{toolId, displayName, defaultPort,
///   settingsFile, ...debugConfig()}` dump.
/// - `studio.debug.tabs` — detailed tab snapshot (index / active /
///   key / name / isHome / currentProject).
/// - `studio.debug.chrome` — ChromeBridge slot wiring snapshot.
/// - `studio.debug.bundles` — bundle registry dump including resolved
///   manifest.
void registerDebugTools(
  mk.KernelServerHost boot, {
  required ChromeBridge bridge,
  required BundleInstallSurface bundles,
  required String toolId,
  required String displayName,
  required int defaultPort,
}) {
  boot.addTool(
    name: 'studio.debug.config',
    description:
        'Host-level configuration dump — `{toolId, displayName, '
        'defaultPort, configRoot, tabsFile, settingsFile}`. Useful '
        'for verifying where the host writes state and which '
        'identity it advertises to MCP clients.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final cfg = bridge.debugConfig?.call() ?? const <String, dynamic>{};
      final out = <String, dynamic>{
        'toolId': toolId,
        'displayName': displayName,
        'defaultPort': defaultPort,
        'settingsFile': VibeSettings.defaultPath(toolId),
        ...cfg,
      };
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(out)),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.tabs',
    description:
        'Detailed tab snapshot — every tab with `index`, `active`, '
        '`key`, `name`, `isHome`, `currentProject`. Heavier than '
        '`studio.chrome.list_tabs` (which is meant for end-user '
        'surfaces); use this to debug tab persistence + active-tab '
        'mismatches.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.debugTabs;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{'tabs': <dynamic>[]}),
            ),
          ],
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{'tabs': fn()}),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.chrome',
    description:
        'ChromeBridge slot wiring snapshot — which UI actions are '
        'currently bound to live widgets. `{slot: bool}` map. Slots '
        'reading false mean the corresponding shell widget is not '
        'mounted yet (or has been disposed).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final b = bridge;
      final wired = <String, bool>{
        'toggleLeftPanel': b.toggleLeftPanel != null,
        'setLeftPanelVisible': b.setLeftPanelVisible != null,
        'openSettings': b.openSettings != null,
        'openHistory': b.openHistory != null,
        'selectTab': b.selectTab != null,
        'closeTab': b.closeTab != null,
        'listTabs': b.listTabs != null,
        'newProjectInActive': b.newProjectInActive != null,
        'openProjectInActive': b.openProjectInActive != null,
        'closeProjectInActive': b.closeProjectInActive != null,
        'activatePackage': b.activatePackage != null,
        'activeProjectInfo': b.activeProjectInfo != null,
        'debugConfig': b.debugConfig != null,
        'debugTabs': b.debugTabs != null,
      };
      final notifiers = <String, dynamic>{
        'tabBarVisible': b.tabBarVisible.value,
        'hasTabStrip': b.hasTabStrip.value,
        'tabBarPeek': b.tabBarPeek.value,
      };
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'wired': wired,
              'notifiers': notifiers,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.bundles',
    description:
        'Full bundle registry dump including manifest meta — for '
        'each entry: registry fields (mbdPath, namespace, '
        'installedAt) plus the resolved manifest (if readable). '
        'Companion to `studio.bundle.list` which is the lean public '
        'view; this one is for debugging install / activation '
        'issues.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final raw = await bundles.list();
      final dump = <Map<String, dynamic>>[];
      for (final e in raw) {
        final mbd = (e['mbdPath'] ?? e['path'] ?? '').toString();
        Map<String, dynamic>? manifest;
        try {
          final f = File(p.join(mbd, 'manifest.json'));
          if (f.existsSync()) {
            final json = jsonDecode(f.readAsStringSync());
            if (json is Map<String, dynamic>) manifest = json;
          }
        } catch (_) {
          /* ignore — entry still listed */
        }
        dump.add(<String, dynamic>{
          ...e,
          if (manifest != null) 'manifest': manifest,
        });
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{'bundles': dump}),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.runtime_state',
    description:
        'Snapshot of the active tab\'s bundle runtime state — every '
        'top-level key the bundle\'s `state.initial` declared plus '
        'anything written since. Bundle-agnostic, mirrors whatever '
        '`stateManager.state` currently holds. Use to verify '
        'emphasisedWhen matching, route propagation, or any '
        'state-driven UI without a screenshot round-trip.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.readActiveRuntimeState;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'state': <String, dynamic>{},
                'reason': 'readActiveRuntimeState-not-wired',
              }),
            ),
          ],
        );
      }
      final state = fn();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'state': state,
              'keys': state.keys.toList(),
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.set_state',
    description:
        'Write a partial state map into the active tab\'s runtime — '
        'simulates the `{type: "state", action: "set", binding, '
        'value}` DSL action a chrome button click would dispatch. '
        'External LLMs / test harnesses use this to drive UI state '
        'without owning a click simulator. Pass `state` as a flat '
        'map: each key is a top-level state binding name; values '
        'are forwarded verbatim (string / number / bool / list / '
        'map). The chrome bridge resolves the active tab and '
        'routes the write to its `DslWorkspaceView` — exactly the '
        'same path the `runtime.*` listeners observe. '
        'Side-effect: `studio.debug.runtime_state` returns the '
        'new value on the very next call.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'state': <String, dynamic>{
          'type': 'object',
          'description':
              'Flat map of state bindings to set. Each entry merged '
              'into the active tab\'s runtime state.',
        },
      },
      'required': <String>['state'],
    },
    handler: (args) async {
      final raw = args['state'];
      Map<String, dynamic>? state;
      if (raw is Map<String, dynamic>) {
        state = raw;
      } else if (raw is Map) {
        state = Map<String, dynamic>.from(raw);
      }
      if (state == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"state (object) required"}',
            ),
          ],
          isError: true,
        );
      }
      final fn = bridge.updateRuntimeState;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"updateRuntimeState-not-wired"}',
            ),
          ],
          isError: true,
        );
      }
      fn(state);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'keysWritten': state.keys.toList(),
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.dispatch_tool',
    description:
        'Dispatch a tool through the active tab\'s default executor — '
        'the same code path a button click follows in mcp_ui_runtime. '
        'Returns the raw response map. Side-effect: spec §3.10 '
        'auto-merge writes the response\'s top-level keys into '
        'runtime state (mirrored on `studio.debug.runtime_state`). '
        'Use this from an external LLM or test harness to drive the '
        'studio as a click would — list-item clicks, nav button '
        'transitions, dialog confirms — without owning a GUI click '
        'simulator. Pair with `studio.debug.set_state` for actions '
        'a click would dispatch alongside the tool call (multi-action '
        'click).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'tool': <String, dynamic>{
          'type': 'string',
          'description': 'Full tool name (e.g. `studio.scenario.read`).',
        },
        'params': <String, dynamic>{
          'type': 'object',
          'description':
              'Forwarded to the tool as-is. Defaults to an empty map.',
        },
      },
      'required': <String>['tool'],
    },
    handler: (args) async {
      final tool = args['tool'];
      if (tool is! String || tool.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"tool (string) required"}',
            ),
          ],
          isError: true,
        );
      }
      final rawParams = args['params'];
      final params =
          rawParams is Map<String, dynamic>
              ? rawParams
              : (rawParams is Map
                  ? Map<String, dynamic>.from(rawParams)
                  : <String, dynamic>{});
      final fn = bridge.dispatchActiveRuntimeTool;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text:
                  '{"ok":false,"reason":"dispatchActiveRuntimeTool-not-wired"}',
            ),
          ],
          isError: true,
        );
      }
      final result = await fn(tool, params);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'tool': tool,
              'response': result,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.dispatch_log',
    description:
        'Ring buffer of the most recent (up to 200) `tools/call` '
        'dispatches handled by this server — `{ts, tool, durationMs, '
        'isError, args, resultPreview}` per entry. The wrapper '
        'installed in `ServerBootstrap._addTool` captures every '
        'handler invocation, so an external LLM agent can verify its '
        'own calls landed (and read back the truncated result without '
        'a separate probe). Most recent last.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'limit': <String, dynamic>{
          'type': 'integer',
          'description': 'Cap on entries returned (default 50).',
        },
        'tool': <String, dynamic>{
          'type': 'string',
          'description':
              'Substring filter on tool name (e.g. "builder", "fs").',
        },
        'errorsOnly': <String, dynamic>{
          'type': 'boolean',
          'description': 'When true, only entries with isError=true.',
        },
      },
    },
    handler: (args) async {
      final limit = (args['limit'] as int?) ?? 50;
      final toolFilter = (args['tool'] as String?)?.toLowerCase();
      final errorsOnly = args['errorsOnly'] == true;
      var entries = boot.dispatchLog;
      if (toolFilter != null && toolFilter.isNotEmpty) {
        entries = <Map<String, Object?>>[
          for (final e in entries)
            if ((e['tool']?.toString().toLowerCase() ?? '').contains(
              toolFilter,
            ))
              e,
        ];
      }
      if (errorsOnly) {
        entries = <Map<String, Object?>>[
          for (final e in entries)
            if (e['isError'] == true) e,
        ];
      }
      if (entries.length > limit) {
        entries = entries.sublist(entries.length - limit);
      }
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
  boot.addTool(
    name: 'studio.debug.screenshot',
    description:
        'Alias of `studio.renderer.screenshot` exposed under the '
        'debug namespace so an LLM running an audit cycle finds it '
        'alongside the rest of the introspection surface. Returns a '
        'base64 PNG of the shell `RepaintBoundary`. See '
        '`studio.renderer.screenshot` for the canonical entry.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'pixelRatio': <String, dynamic>{
          'type': 'number',
          'description': 'Render density (default 1.0).',
        },
      },
    },
    handler: (args) async {
      final pr = (args['pixelRatio'] as num?)?.toDouble() ?? 1.0;
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
      final bytes = await fn(pixelRatio: pr);
      if (bytes == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"capture root not attached"}',
            ),
          ],
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelImageContent(
            data: base64Encode(bytes),
            mimeType: 'image/png',
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.layout_snapshot',
    description:
        'Alias of `studio.renderer.layout_snapshot` exposed under '
        'the debug namespace. Numeric render-tree dump — one entry '
        'per MetaData-tagged widget with `{type, depth, rect, font, '
        'box, padding}`. Use to verify layout without paying for a '
        'vision model. See `studio.renderer.layout_snapshot` for the '
        'canonical entry.',
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
    name: 'studio.debug.notify_log',
    description:
        'Recent (up to 100) chrome.notify() calls — `{ts, message, '
        'severity}` per entry. Toast / snackbar messages fade after a '
        'few seconds; this surfaces them so an external LLM can spot '
        'errors that the user may have missed. Most recent last.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'limit': <String, dynamic>{
          'type': 'integer',
          'description': 'Cap on entries returned (default 100).',
        },
        'severity': <String, dynamic>{
          'type': 'string',
          'description': 'Filter by severity (info/success/warning/error).',
        },
      },
    },
    handler: (args) async {
      final limit = (args['limit'] as int?) ?? 100;
      final sev = (args['severity'] as String?)?.toLowerCase();
      var entries = bridge.notifyLog;
      if (sev != null && sev.isNotEmpty) {
        entries = <Map<String, Object?>>[
          for (final e in entries)
            if ((e['severity']?.toString().toLowerCase() ?? 'info') == sev) e,
        ];
      }
      if (entries.length > limit) {
        entries = entries.sublist(entries.length - limit);
      }
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
  boot.addTool(
    name: 'studio.debug.activation',
    description:
        "Active tab's bundle activation surface — `{bundleShortId, "
        'exposedNs, bundlePath, tools, agents}`. Tools are the MCP '
        'names actually reachable against this tab (filtered to the '
        "exposedNs prefix); agents are the bundle's contribution to "
        'AgentHost. Use to confirm what an LLM can call after an '
        'activation / reload.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.debugActivation;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'reason': 'debugActivation-not-wired',
              }),
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
    name: 'studio.debug.runtimes',
    description:
        "Per-tab runtime state for EVERY non-home tab — `[{index, "
        'active, tabKey, name, hooksAttached, state, currentProject}]`. '
        "Reads each tab's DslWorkspaceView hooks directly so multi-"
        'tab inspection sees fresh state without flipping the active '
        'tab.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.debugRuntimes;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'tabs': <dynamic>[],
                'reason': 'debugRuntimes-not-wired',
              }),
            ),
          ],
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{'tabs': fn()}),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.chat',
    description:
        "Active tab's chat surface — `{agentId, turnCount, turns: "
        "[{role, content}]}`. Content is truncated to ~600 chars. "
        'Use to reconstruct the conversation context for an external '
        'LLM agent without exporting the full chat log.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'limit': <String, dynamic>{
          'type': 'integer',
          'description': 'Cap on most-recent turns returned (default 20).',
        },
      },
    },
    handler: (args) async {
      final limit = (args['limit'] as int?) ?? 20;
      final fn = bridge.debugChat;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'reason': 'debugChat-not-wired',
              }),
            ),
          ],
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(fn(limit))),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.agents',
    description:
        'Every agent profile registered with AgentHost — `[{id, '
        'displayName, role, modelId, toolCount}]`. Use to see what '
        '`studio.agent.dispatch` can target and what model / tool '
        'surface each agent carries.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final host = AgentHost.shared;
      if (host == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'count': 0,
                'agents': const <dynamic>[],
                'reason': 'AgentHost.shared not initialised',
              }),
            ),
          ],
        );
      }
      final agents = <Map<String, dynamic>>[
        for (final p in host.profiles)
          <String, dynamic>{
            'id': p.id,
            'displayName': p.displayName,
            'role': p.role.name,
            'modelId': p.modelId,
            'toolCount': p.toolNames.length,
          },
      ];
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'count': agents.length,
              'agents': agents,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.settings',
    description:
        "Host settings snapshot — contents of `<configRoot>/settings.json` "
        '(workspaceDir, llm model selections, etc.). Returns the raw '
        'JSON so external LLM debugging can verify config without a '
        'screenshot.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final cfg = bridge.debugConfig?.call() ?? <String, dynamic>{};
      final root = cfg['configRoot']?.toString() ?? '';
      final settingsFile =
          root.isNotEmpty ? File(p.join(root, 'settings.json')) : null;
      Map<String, dynamic>? content;
      if (settingsFile != null && settingsFile.existsSync()) {
        try {
          final raw = jsonDecode(settingsFile.readAsStringSync());
          if (raw is Map<String, dynamic>) content = raw;
        } catch (_) {
          /* corrupt — return null */
        }
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'path': settingsFile?.path,
              'exists': content != null,
              if (content != null) 'settings': content,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.overrides',
    description:
        'Per-package settings overrides snapshot — content of '
        '`<configRoot>/package_settings/<safe(path)>.json` for one or '
        'all domains. Pass `path` to read one domain (e.g. `'
        '/Users/.../workspaces/app_builder`); omit to dump every '
        'override file. Returns `{configRoot, files:[{path, safe, '
        'exists, content?, error?}]}`. The override file holds the '
        'per-domain `inheritFromSystem` + `mcpServerUrl` (host-level '
        'MCP server pool) plus any domain-declared settings sections '
        'the user overrode via ManifestFieldList autosave. Use this '
        'instead of reading the file from disk directly — covers the '
        'naming + existence check + safe-character mangle in one '
        'response.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional. Domain mbdPath / built-in workspace path. When '
              'omitted, every file under `<configRoot>/package_settings/` '
              'is returned.',
        },
      },
    },
    handler: (args) async {
      final cfg = bridge.debugConfig?.call() ?? <String, dynamic>{};
      final root = cfg['configRoot']?.toString() ?? '';
      if (root.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'configRoot': null,
                'files': <Map<String, dynamic>>[],
                'error': 'configRoot not configured',
              }),
            ),
          ],
        );
      }
      final dir = Directory(p.join(root, 'package_settings'));
      String safeOf(String path) =>
          path.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
      Map<String, dynamic> entryFor(String filePath, {String? domainPath}) {
        final f = File(filePath);
        final exists = f.existsSync();
        final entry = <String, dynamic>{
          'path': filePath,
          if (domainPath != null) 'domain': domainPath,
          'exists': exists,
        };
        if (exists) {
          try {
            final raw = jsonDecode(f.readAsStringSync());
            if (raw is Map<String, dynamic>)
              entry['content'] = raw;
            else
              entry['error'] = 'not a JSON object';
          } catch (e) {
            entry['error'] = e.toString();
          }
        }
        return entry;
      }

      final files = <Map<String, dynamic>>[];
      final pathArg = args['path']?.toString();
      if (pathArg != null && pathArg.isNotEmpty) {
        final safe = safeOf(pathArg);
        files.add(
          entryFor(p.join(dir.path, '$safe.json'), domainPath: pathArg),
        );
      } else if (dir.existsSync()) {
        for (final f in dir.listSync()) {
          if (f is File && f.path.endsWith('.json')) {
            files.add(entryFor(f.path));
          }
        }
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'configRoot': root,
              'dir': dir.path,
              'files': files,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.workspace_snapshot',
    description:
        'Workspace folder summary — lists every `.mbd` bundle (folder '
        'with a `manifest.json`) and every project (folder with '
        '`project.apbproj`) under the configured workspaceDir. Use '
        'this instead of walking the filesystem from outside — the '
        'response also flags non-mbd top-level entries so a stray '
        '/tmp dump under the workspace surfaces immediately. Pass '
        '`root` to inspect a different directory.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'root': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to studio settings.workspaceDir.',
        },
      },
    },
    handler: (args) async {
      String? rootArg = args['root']?.toString();
      if (rootArg == null || rootArg.isEmpty) {
        final cfg = bridge.debugConfig?.call() ?? <String, dynamic>{};
        final root = cfg['configRoot']?.toString() ?? '';
        if (root.isNotEmpty) {
          final settingsFile = File(p.join(root, 'settings.json'));
          if (settingsFile.existsSync()) {
            try {
              final raw = jsonDecode(settingsFile.readAsStringSync());
              if (raw is Map<String, dynamic>) {
                rootArg = raw['workspaceDir']?.toString();
              }
            } catch (_) {
              /* ignore */
            }
          }
        }
      }
      if (rootArg == null || rootArg.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'root': null,
                'error': 'workspaceDir not configured',
              }),
            ),
          ],
        );
      }
      final dir = Directory(rootArg);
      if (!dir.existsSync()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'root': rootArg,
                'exists': false,
              }),
            ),
          ],
        );
      }
      final mbds = <Map<String, dynamic>>[];
      final projects = <Map<String, dynamic>>[];
      final other = <String>[];
      for (final entry in dir.listSync()) {
        if (entry is! Directory) {
          if (entry is File) other.add(p.basename(entry.path));
          continue;
        }
        final name = p.basename(entry.path);
        final manifest = File(p.join(entry.path, 'manifest.json'));
        final apb = File(p.join(entry.path, 'project.apbproj'));
        if (manifest.existsSync()) {
          mbds.add(<String, dynamic>{
            'name': name,
            'path': entry.path,
            'hasManifest': true,
          });
        } else if (apb.existsSync()) {
          projects.add(<String, dynamic>{
            'name': name,
            'path': entry.path,
            'hasApbproj': true,
          });
        } else {
          other.add(name);
        }
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'root': rootArg,
              'exists': true,
              'mbds': mbds,
              'projects': projects,
              'other': other,
              'counts': <String, int>{
                'mbds': mbds.length,
                'projects': projects.length,
                'other': other.length,
              },
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.boot_log',
    description:
        'Boot event log — `[{ts, message}]` for tabs.json restore + '
        'every bundle activation in the current session. Use to '
        'diagnose post-mortem when a bundle failed to load or a tab '
        'restored without its workspace (e.g. seed bundle missing on '
        'disk).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'limit': <String, dynamic>{
          'type': 'integer',
          'description': 'Cap on entries returned (default 100).',
        },
      },
    },
    handler: (args) async {
      final limit = (args['limit'] as int?) ?? 100;
      var entries = bridge.bootEvents;
      if (entries.length > limit) {
        entries = entries.sublist(entries.length - limit);
      }
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
  boot.addTool(
    name: 'studio.debug.history.restore',
    description:
        "Restore a `<mbdPath>/.history/<id>/` snapshot onto live "
        'files. Captures a fresh "preRestore" snapshot of the current '
        'state first (so the restore itself is undoable), then copies '
        'every file from the snapshot directory back into the bundle. '
        'Mark the active tab modified afterwards.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'id': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['mbdPath', 'id'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final id = args['id'];
      if (mbd is! String || mbd.isEmpty || id is! String || id.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': 'mbdPath and id required',
              }),
            ),
          ],
        );
      }
      final snapDir = Directory(p.join(mbd, '.history', id));
      if (!await snapDir.exists()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': 'snapshot not found',
              }),
            ),
          ],
        );
      }
      // Capture pre-restore so the user can undo this restore.
      final ts =
          DateTime.now()
              .toUtc()
              .toIso8601String()
              .replaceAll(':', '-')
              .split('.')
              .first;
      final preDir = Directory(p.join(mbd, '.history', '$ts-preRestore'));
      await preDir.create(recursive: true);
      final restoredFiles = <String>[];
      await for (final f in snapDir.list(recursive: true)) {
        if (f is! File) continue;
        final rel = p.relative(f.path, from: snapDir.path);
        final liveFile = File(p.join(mbd, rel));
        if (await liveFile.exists()) {
          final preFile = File(p.join(preDir.path, rel));
          await preFile.parent.create(recursive: true);
          await liveFile.copy(preFile.path);
        }
        await liveFile.parent.create(recursive: true);
        await f.copy(liveFile.path);
        restoredFiles.add(rel);
      }
      try {
        bridge.markActiveTabModified?.call();
      } catch (_) {
        /* swallow */
      }
      // Reload the active tab so editor surfaces re-read the
      // restored manifest / UI.
      try {
        bridge.reloadTab?.call(null);
      } catch (_) {
        /* swallow */
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'restored': restoredFiles,
              'preRestoreSnapshot': '$ts-preRestore',
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.history.list',
    description:
        "List the `<mbdPath>/.history/` snapshots accumulated by the "
        '`studio.builder.*` mutators. Returns one entry per snapshot: '
        '`{id, ts, label, files}`. The `id` is the directory name and '
        'is what `studio.debug.history.diff` takes. Most recent last.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the bundle directory.',
        },
      },
      'required': <String>['mbdPath'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      if (mbd is! String || mbd.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': 'mbdPath required',
              }),
            ),
          ],
        );
      }
      final dir = Directory(p.join(mbd, '.history'));
      if (!await dir.exists()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'count': 0,
                'entries': const <Map<String, dynamic>>[],
              }),
            ),
          ],
        );
      }
      final entries = <Map<String, dynamic>>[];
      await for (final entity in dir.list()) {
        if (entity is! Directory) continue;
        final id = p.basename(entity.path);
        // Snapshot id format: `<UTC-ISO no millis>-<label>`. Split on
        // the LAST '-' so labels containing dashes still parse.
        final dashIdx = id.lastIndexOf('-');
        final ts = dashIdx > 0 ? id.substring(0, dashIdx) : id;
        final label = dashIdx > 0 ? id.substring(dashIdx + 1) : '';
        final files = <String>[];
        await for (final f in entity.list(recursive: true)) {
          if (f is File) {
            files.add(p.relative(f.path, from: entity.path));
          }
        }
        entries.add(<String, dynamic>{
          'id': id,
          'ts': ts,
          'label': label,
          'files': files,
        });
      }
      entries.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
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
  boot.addTool(
    name: 'studio.debug.history.diff',
    description:
        'Show the diff between a snapshot in `<mbdPath>/.history/<id>/` '
        'and the current bundle files. Returns per-file `{path, '
        'before, after, identical}` — `before` is the snapshot content, '
        '`after` is what is on disk now. Use to verify that a mutator '
        'produced the change the LLM intended, or to plan a rollback.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the bundle directory.',
        },
        'id': <String, dynamic>{
          'type': 'string',
          'description': 'Snapshot id from `studio.debug.history.list`.',
        },
      },
      'required': <String>['mbdPath', 'id'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final id = args['id'];
      if (mbd is! String || mbd.isEmpty || id is! String || id.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': 'mbdPath and id required',
              }),
            ),
          ],
        );
      }
      final snapDir = Directory(p.join(mbd, '.history', id));
      if (!await snapDir.exists()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': 'snapshot not found',
              }),
            ),
          ],
        );
      }
      final diffs = <Map<String, dynamic>>[];
      await for (final f in snapDir.list(recursive: true)) {
        if (f is! File) continue;
        final rel = p.relative(f.path, from: snapDir.path);
        final before = await f.readAsString();
        final liveFile = File(p.join(mbd, rel));
        final after =
            await liveFile.exists() ? await liveFile.readAsString() : '';
        diffs.add(<String, dynamic>{
          'path': rel,
          'before': before,
          'after': after,
          'identical': before == after,
        });
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'id': id,
              'files': diffs,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.debug.header_actions',
    description:
        "Active tab's `headerActions` snapshot — every domain icon "
        'with its `tooltip`, `emphasised` flag, and `divider` hint. '
        'Use to verify selectGroup / emphasisedWhen matching: pull '
        '`studio.debug.runtime_state` first, then this; the icon '
        'whose `value` matches the runtime state value should have '
        '`emphasised: true`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final list = bridge.headerActions.value;
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'count': list.length,
              'actions': <Map<String, dynamic>>[
                for (final a in list)
                  <String, dynamic>{
                    'tooltip': a.tooltip,
                    'emphasised': a.emphasised,
                    'divider': a.divider,
                  },
              ],
            }),
          ),
        ],
      );
    },
  );
  // ── studio.debug.knowledge_index ───────────────────────────────────
  //
  // Per-bundle / per-source / per-doc knowledge index introspection.
  // Companion to `studio.debug.bundles` (full manifest dump) and to
  // the host's `resources/list` (URI surface). This tool flattens the
  // installed bundles' knowledge.sources[] into a single doc-level
  // table with namespace + sourceId + estimated chunk count so an
  // external LLM can see what the BM25 retriever (KnowledgeQueryEngine)
  // will actually look at.
  boot.addTool(
    name: 'studio.debug.knowledge_index',
    description:
        'Per-doc flattened index of installed-bundle knowledge — one '
        'entry per `<namespace>.<sourceId>.<docId>` triple with '
        '`{namespace, mbdPath, sourceId, docId, path, sizeBytes, '
        'mimeType?, title?, chunks?}`. Richer than `resources/list` '
        '(which only emits URIs) — this tool surfaces the indexer '
        'view used by `bk.knowledge.query` / `studio.knowledge.query`. '
        'Optional `namespace` arg filters to one bundle (matches '
        '`manifest.id`); `summary:true` returns aggregate counts '
        '(`docs`, `sources`, `namespaces`, `totalBytes`, '
        '`chunksEstimated`) only. Best effort — manifest read failures '
        'silent-skip the source/doc.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'namespace': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional. Filter to bundles whose `manifest.id` equals '
              'this value.',
        },
        'summary': <String, dynamic>{
          'type': 'boolean',
          'description':
              'When true, only aggregate counts (docs / sources / '
              'namespaces / totalBytes / chunksEstimated) are returned.',
        },
      },
    },
    handler: (args) async {
      final nsFilter = args['namespace'] as String?;
      final summaryOnly = args['summary'] == true;
      final raw = await bundles.list();
      final docs = <Map<String, dynamic>>[];
      final sourcesSeen = <String>{};
      final namespacesSeen = <String>{};
      var totalBytes = 0;
      var chunksEstimated = 0;
      for (final e in raw) {
        final mbd = (e['mbdPath'] ?? e['path'] ?? '').toString();
        if (mbd.isEmpty) continue;
        Map<String, dynamic>? manifest;
        try {
          final f = File(p.join(mbd, 'manifest.json'));
          if (!f.existsSync()) continue;
          final json = jsonDecode(f.readAsStringSync());
          if (json is Map<String, dynamic>) manifest = json;
        } catch (_) {
          continue;
        }
        if (manifest == null) continue;
        // manifest.id is the entry's namespace by convention.
        final ns =
            (manifest['manifest'] is Map &&
                    (manifest['manifest'] as Map)['id'] is String)
                ? (manifest['manifest'] as Map)['id'] as String
                : (manifest['id'] as String? ??
                    e['namespace']?.toString() ??
                    '');
        if (nsFilter != null && nsFilter.isNotEmpty && ns != nsFilter) {
          continue;
        }
        namespacesSeen.add(ns);
        final knowledge = manifest['knowledge'];
        if (knowledge is! Map) continue;
        final sources = knowledge['sources'];
        if (sources is! List) continue;
        for (final src in sources) {
          if (src is! Map) continue;
          final sourceId = (src['id'] as String?) ?? '';
          if (sourceId.isEmpty) continue;
          sourcesSeen.add('$ns.$sourceId');
          final docsList = src['docs'];
          if (docsList is! List) continue;
          for (final d in docsList) {
            if (d is! Map) continue;
            final docId = (d['id'] as String?) ?? '';
            final relPath = (d['path'] as String?) ?? '';
            final inlineContent =
                d['content'] is String ? (d['content'] as String) : null;
            int sizeBytes = 0;
            String? resolvedPath;
            if (relPath.isNotEmpty) {
              final f = File(p.join(mbd, relPath));
              if (f.existsSync()) {
                try {
                  sizeBytes = f.lengthSync();
                  resolvedPath = f.path;
                } catch (_) {
                  /* skip */
                }
              }
            } else if (inlineContent != null) {
              sizeBytes = inlineContent.length;
            }
            // Rough estimate — BM25 chunker splits on ~1k char boundaries.
            // Use a coarse divisor so callers get a realistic order of
            // magnitude without paying for full indexer materialisation.
            final chunkApprox =
                sizeBytes == 0
                    ? 0
                    : (sizeBytes / 1024).ceil().clamp(1, 1 << 20);
            chunksEstimated += chunkApprox;
            totalBytes += sizeBytes;
            if (!summaryOnly) {
              docs.add(<String, dynamic>{
                'namespace': ns,
                'mbdPath': mbd,
                'sourceId': sourceId,
                if (docId.isNotEmpty) 'docId': docId,
                if (relPath.isNotEmpty) 'path': relPath,
                if (resolvedPath != null) 'resolvedPath': resolvedPath,
                'sizeBytes': sizeBytes,
                if (d['mimeType'] is String) 'mimeType': d['mimeType'],
                if (d['title'] is String) 'title': d['title'],
                'chunksEstimated': chunkApprox,
              });
            }
          }
        }
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'summary': <String, dynamic>{
                'namespaces': namespacesSeen.length,
                'sources': sourcesSeen.length,
                'docs':
                    summaryOnly
                        ? (chunksEstimated > 0
                            ? chunksEstimated // best-effort when docs list not materialised
                            : 0)
                        : docs.length,
                'totalBytes': totalBytes,
                'chunksEstimated': chunksEstimated,
              },
              if (!summaryOnly) 'docs': docs,
            }),
          ),
        ],
      );
    },
  );

  boot.addTool(
    name: 'studio.debug.servers',
    description:
        'Domain server pool snapshot — one entry per pooled MCP '
        'server instance keyed by listen URL. Includes `kind` '
        '(`system` / `domainSpawned`), `state` (`active` / `failed` / '
        '`spawning` / `teardown`), `attachedDomains` (bundle ids '
        'sharing the instance), and optional `error` string when '
        'state is `failed`. Use this to verify which domains inherit '
        'the system server, which run their own, and which failed to '
        'bind.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final mgr = bridge.domainServerManager;
      final servers =
          mgr == null ? const <Map<String, dynamic>>[] : mgr.status();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'servers': servers,
              if (mgr != null) 'systemUrl': mgr.systemUrl,
            }),
          ),
        ],
      );
    },
  );
}
