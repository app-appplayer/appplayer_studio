/// `registerChromeTools` — register the 13 `studio.chrome.*` MCP
/// tools (panel toggles, tab strip, tab management, dialogs,
/// programmatic package creation, reload) onto a kernel
/// `ServerBootstrap`. Every handler routes through a [ChromeBridge]
/// callback so the host that mounts the shell wires the
/// implementations from inside its `setState` — driving the tool
/// over MCP hits the same code path a user click does.
///
/// Every studio host (universal vibe_studio, future variants) calls
/// this once during `registerMcpTools` so the chrome surface stays
/// identical across studios. Moved out of vibe_studio's host file
/// into base so the body of the registration is shared verbatim.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'chrome_bridge.dart';
import '../install/builtin_app.dart' show BuiltInAppRegistry;
import '../install/internal_call_guard.dart';

/// Register the 13 `studio.chrome.*` tools onto [boot]. Each handler
/// reads from [bridge]; the host wires the bridge setters when its
/// shell mounts.
void registerChromeTools(mk.KernelServerHost boot, ChromeBridge bridge) {
  boot.addTool(
    name: 'studio.chrome.toggle_left_panel',
    description:
        'Toggle the chat / project-header column on the left edge '
        'of the AppPlayer Studio shell. Same code path as the user '
        'clicking the panel-toggle icon in the titlebar. Returns '
        '`{visible: true|false}` reflecting the new state.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.toggleLeftPanel;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"shell not mounted yet"}'),
          ],
          isError: true,
        );
      }
      final visible = fn();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: '{"visible":$visible}'),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.set_left_panel',
    description:
        'Set the left-panel visibility explicitly. Pass '
        '`{visible: true}` to show or `{visible: false}` to hide. '
        'Returns the resulting `{visible: ...}` state.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'visible': <String, dynamic>{
          'type': 'boolean',
          'description':
              'Target visibility. `true` = chat column visible, '
              '`false` = hidden.',
        },
      },
      'required': <String>['visible'],
    },
    handler: (args) async {
      final fn = bridge.setLeftPanelVisible;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"shell not mounted yet"}'),
          ],
          isError: true,
        );
      }
      final v = args['visible'];
      if (v is! bool) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"visible must be boolean"}'),
          ],
          isError: true,
        );
      }
      final visible = fn(v);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: '{"visible":$visible}'),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.set_tab_bar',
    description:
        'Set the universal-host tab strip visibility. `{visible:true}` '
        'pins the strip; `{visible:false}` hides it (titlebar hover '
        'reveals it transiently). Returns the resulting state.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'visible': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['visible'],
    },
    handler: (args) async {
      final v = args['visible'];
      if (v is! bool) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"visible must be boolean"}'),
          ],
          isError: true,
        );
      }
      bridge.tabBarVisible.value = v;
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: '{"visible":$v}'),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.peek_tab_bar',
    description:
        'Trigger the transient hover-reveal of the tab strip while it '
        'is hidden. `{on:true}` peeks in; `{on:false}` schedules peek '
        'out (200ms delay, matching titlebar mouse-exit). Used for '
        'driving the same code path as the user hovering the '
        'titlebar.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'on': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['on'],
    },
    handler: (args) async {
      final on = args['on'];
      if (on is! bool) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"on must be boolean"}'),
          ],
          isError: true,
        );
      }
      if (on) {
        bridge.peekIn();
      } else {
        bridge.peekOut();
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[mk.KernelTextContent(text: '{"peek":$on}')],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.create_package',
    description:
        'Same code path as the Home "Create package" button — '
        'INSTALLS and ACTIVATES the new .mbd into the host registry '
        'immediately. Use this when the user explicitly wants the '
        'package live on Home right away.\n'
        '**For draft-only authoring (external LLM dogfood) use '
        '`studio.project.new` instead** — that scaffolds a new '
        'directory under the active package tab\'s `currentProject` '
        'slot without touching the host registry, so the bundle is '
        'editable but NOT installed until the user explicitly runs '
        '`studio.bundle.install` (or imports the exported .mcpb).\n'
        'Without args: opens the name+parent dialog. With name '
        '(and optionally parent / id): programmatic create — no '
        'dialog — scaffold + install + activate, return mbdPath.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'name': <String, dynamic>{
          'type': 'string',
          'description':
              'Human-friendly package name. Omit to open the dialog.',
        },
        'parent': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional parent directory. Defaults to the studio '
              '`workspaceDir` setting when set, else the configRoot '
              'drafts/ folder.',
        },
        'id': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional reverse-DNS manifest.id. Defaults to '
              'com.example.<slug>.',
        },
      },
    },
    handler: (args) async {
      final g = internalGuard(bridge, 'studio.chrome.create_package');
      if (g != null) return g;
      final fn = bridge.createNewPackage;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"shell not mounted"}',
            ),
          ],
          isError: true,
        );
      }
      final name = args['name'] as String?;
      final parent = args['parent'] as String?;
      final id = args['id'] as String?;
      final result = await fn(name: name, parent: parent, id: id);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(result)),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.open_agents',
    description:
        'Open the Agents surface view — a scrollable card list of '
        'every registered agent (studio defaults + activated bundle '
        'agents) with id / role / model / toolNames / systemPrompt '
        'preview. Same data as studio.agent.list + describe, '
        'rendered as a dialog for the user.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.openAgents;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"shell not mounted"}',
            ),
          ],
          isError: true,
        );
      }
      await fn();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[mk.KernelTextContent(text: '{"ok":true}')],
      );
    },
  );

  boot.addTool(
    name: 'studio.app.open',
    description:
        'Cross-app deep link (docs/03_DDD/app-open-deeplink.md): open or '
        'focus a built-in app tab, optionally bind a project directory, '
        'and land on an in-app route focused on one entity. Steps run in '
        'order and the response reports each — {ok, opened, projectBound?, '
        'landed?}. Route vocabulary and entity resolution belong to the '
        'target app (e.g. form_builder: dashboard | templates | compose | '
        'approvals | issues, entity = issueId / documentId / templateId). '
        'Example: {app:"form_builder", project:"/path/to/proj", '
        'route:"approvals", entity:"doc-…"}.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'app': <String, dynamic>{
          'type': 'string',
          'description': 'Built-in app id (form_builder, makemind_ops, …).',
        },
        'project': <String, dynamic>{
          'type': 'string',
          'description': 'Project directory to bind on the tab (optional).',
        },
        'route': <String, dynamic>{'type': 'string'},
        'entity': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['app'],
    },
    handler: (args) async {
      Map<String, dynamic> fail(String step, String error) =>
          <String, dynamic>{'ok': false, 'step': step, 'error': error};
      mk.KernelToolResult reply(Map<String, dynamic> body,
              {bool isError = false}) =>
          mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(text: jsonEncode(body)),
            ],
            isError: isError,
          );

      final app = (args['app'] as String?) ?? '';
      if (app.isEmpty) {
        return reply(fail('open', 'app (built-in id) required'),
            isError: true);
      }
      final open = bridge.openSeed;
      if (open == null) {
        return reply(fail('open', 'shell not mounted'), isError: true);
      }
      if (!await open(app)) {
        return reply(fail('open', 'app "$app" not declared'), isError: true);
      }
      final out = <String, dynamic>{'ok': true, 'opened': app};

      // The tab mounts / claims its slots on a frame build — wait for the
      // app's context (and its navigate hook) to come up instead of
      // racing it.
      Future<Future<bool> Function(String, {String? entityId})?>
          awaitNavigate() async {
        for (var i = 0; i < 40; i++) {
          final ctx = BuiltInAppRegistry.instance.activeContext;
          if (ctx != null &&
              BuiltInAppRegistry.instance.activeApp?.id == app &&
              ctx.navigateProvider != null) {
            return ctx.navigateProvider;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        return null;
      }

      final project = args['project'] as String?;
      if (project != null && project.isNotEmpty) {
        // The active built-in claims openProjectInActive; give it frames
        // to claim, then bind through its own validated handler.
        var bound = false;
        for (var i = 0; i < 40 && !bound; i++) {
          final bind = bridge.openProjectInActive;
          if (bind != null &&
              BuiltInAppRegistry.instance.activeApp?.id == app) {
            await bind(project);
            bound = true;
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        if (!bound) {
          return reply(
            {...out, ...fail('project', 'project slot never came up')},
            isError: true,
          );
        }
        out['projectBound'] = project;
      }

      final route = args['route'] as String?;
      if (route != null && route.isNotEmpty) {
        final navigate = await awaitNavigate();
        if (navigate == null) {
          return reply(
            {
              ...out,
              ...fail('route',
                  'app "$app" exposes no navigateProvider (not navigable)'),
            },
            isError: true,
          );
        }
        final landed =
            await navigate(route, entityId: args['entity'] as String?);
        if (!landed) {
          return reply(
            {
              ...out,
              ...fail('route', 'unknown route/entity: $route/'
                  '${args['entity'] ?? ''}'),
            },
            isError: true,
          );
        }
        out['landed'] = route;
        if (args['entity'] != null) out['entity'] = args['entity'];
      }
      return reply(out);
    },
  );
  boot.addTool(
    name: 'studio.chrome.open_onboarding',
    description:
        'Show the External LLM onboarding panel — MCP endpoint URL '
        'plus copy-ready config snippets for Claude Desktop '
        '(streamable_http JSON), Claude Code (`claude mcp add`), '
        'and a generic curl initialize probe. Use this when a user '
        'asks how to connect their own LLM client to the studio.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.openOnboarding;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"shell not mounted"}',
            ),
          ],
          isError: true,
        );
      }
      await fn();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[mk.KernelTextContent(text: '{"ok":true}')],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.open_seed',
    description:
        'Focus the seed identified by `namespace` (e.g. app_builder, '
        'scene_builder, makemind_ops), or mount it as a new tab when none '
        'is up. Per '
        'SDD §1.4 the namespace is the single seed identifier — host '
        'resolves the current path. Use this instead of '
        'studio.bundle.activate when targeting a seed: seeds are host '
        'assets and persist as namespace references, not paths. '
        'Returns `{ok}` on success, `{ok:false, error}` when the '
        'namespace is not declared by the host.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'namespace': <String, dynamic>{
          'type': 'string',
          'description': 'Seed namespace (declared in StudioApp.seedBundles).',
        },
      },
      'required': <String>['namespace'],
    },
    handler: (args) async {
      final ns = (args['namespace'] as String?) ?? '';
      if (ns.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"namespace required"}',
            ),
          ],
          isError: true,
        );
      }
      final fn = bridge.openSeed;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"shell not mounted"}',
            ),
          ],
          isError: true,
        );
      }
      final ok = await fn(ns);
      if (!ok) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"seed \\"$ns\\" not declared"}',
            ),
          ],
          isError: true,
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[mk.KernelTextContent(text: '{"ok":true}')],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.reload_tab',
    description:
        'Force a re-mount of the active bundle\'s DslWorkspaceView so '
        'it re-reads ui/app.json + manifest.json. Use AFTER a '
        'builder write tool (writeUI / patchManifest / addTool) so '
        'the user sees the change without closing and re-opening '
        'the tab. Returns `{ok}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'index': <String, dynamic>{
          'type': 'integer',
          'description': 'Tab index to reload. Omit for the active tab.',
        },
      },
    },
    handler: (args) async {
      final fn = bridge.reloadTab;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"shell not mounted"}',
            ),
          ],
          isError: true,
        );
      }
      final idx = args['index'];
      fn(idx is int ? idx : null);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[mk.KernelTextContent(text: '{"ok":true}')],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.select_tab',
    description:
        'Activate a tab — addressable either positionally (`index`, '
        '0-based; index 0 is always Home) or by stable identity '
        '(`key`, the `.mbd` path / `home`, as returned by '
        'studio.debug.tabs). Pass exactly one. Returns the '
        'resulting `{active, tabs}` snapshot.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'index': <String, dynamic>{
          'type': 'integer',
          'description': 'Tab index (0-based). Index 0 = Home.',
        },
        'key': <String, dynamic>{
          'type': 'string',
          'description':
              'Tab key (mbdPath or "home"). Resolved against the '
              'current tab list at call time.',
        },
      },
    },
    handler: (args) async {
      final fn = bridge.selectTab;
      final list = bridge.listTabs;
      if (fn == null || list == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"shell not mounted yet"}'),
          ],
          isError: true,
        );
      }
      int? idx;
      final rawIdx = args['index'];
      final rawKey = args['key'];
      if (rawIdx is int) {
        idx = rawIdx;
      } else if (rawKey is String && rawKey.isNotEmpty) {
        // Resolve key → index against the current tab list.
        final tabs = list();
        final found = tabs.indexWhere((e) => e['key'] == rawKey);
        if (found >= 0) {
          idx = found;
        }
        if (idx == null) {
          return mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text: '{"error":"key not found","key":"$rawKey"}',
              ),
            ],
            isError: true,
          );
        }
      } else {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"error":"index (int) or key (string) required"}',
            ),
          ],
          isError: true,
        );
      }
      final active = fn(idx);
      if (active < 0) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"error":"index out of range","active":-1}',
            ),
          ],
          isError: true,
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'active': active,
              'tabs': list(),
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.close_tab',
    description:
        'Close a tab by index (0 = home is rejected). Runs the '
        'activation teardown — every tool / agent / UI mount the '
        'bundle registered via its `BundleActivationContext` is '
        'unregistered, and the tab is removed from the strip. '
        'Returns `{active, closed: bool}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'index': <String, dynamic>{'type': 'integer', 'minimum': 0},
      },
      'required': <String>['index'],
    },
    handler: (args) async {
      final i = args['index'];
      if (i is! int) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'error': 'index required (integer)',
              }),
            ),
          ],
          isError: true,
        );
      }
      final fn = bridge.closeTab;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'error': 'shell not mounted yet',
              }),
            ),
          ],
          isError: true,
        );
      }
      final active = fn(i);
      final closed = active != -1;
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'active': active,
              'closed': closed,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.list_tabs',
    description:
        'Snapshot the universal-host tab strip. Returns '
        '`{active, tabs:[{key,name}]}`. Key `home` is the home tab; '
        'others are package paths.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final list = bridge.listTabs;
      if (list == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"shell not mounted yet"}'),
          ],
          isError: true,
        );
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{'tabs': list()}),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.open_history',
    description:
        'Open the chat-history dialog (Studio · Package · Project '
        'tabs). Same code path as clicking the history icon. Returns '
        'after the dialog is dismissed.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.openHistory;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"shell not mounted"}'),
          ],
          isError: true,
        );
      }
      await fn();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: '{"opened":true}'),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.chrome.open_settings',
    description:
        'Open the standard Settings dialog. Same code path as the '
        'user clicking the gear icon in the project header / activity '
        'bar. Returns once the dialog is dismissed.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.openSettings;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"shell not mounted yet"}'),
          ],
          isError: true,
        );
      }
      await fn();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: '{"opened":true}'),
        ],
      );
    },
  );
  // NOTE: `studio.workspace.adopt` retired in the studio_builder
  // cleanup round. The old tool hard-stamped a draft as the Studio
  // Builder seed tab's `currentProject` (legacy adopt-in-builder
  // pattern); unified-builder (2026-05-19) collapsed that surface
  // into the App Builder BuiltInApp, and `_createNewPackage` now
  // drops a `.builtin_app_builder` marker so the registry's
  // `canHandle` matches the draft naturally — no namespace literal
  // lookup, no host-side adopt slot.
}
