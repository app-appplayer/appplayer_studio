/// `registerBundleInstallTools` — register the five `studio.bundle.*`
/// install / list / activate / uninstall / dispatch_tool MCP tools onto
/// a kernel `ServerBootstrap`. Every handler routes through the host's
/// [ChromeBridge] (for activate / dispatch) or the
/// [BundleInstallSurface] (for install / list / uninstall) so driving
/// these tools over MCP hits the same code path a user click does.
///
/// Spec-compliant resource readers (`studio.bundle.list_assets` /
/// `studio.bundle.read_asset`) live separately in
/// [bundle_resource_tools.dart]; this surface is purely the install /
/// lifecycle verbs.
///
/// Every studio host (universal vibe_studio, future variants) calls
/// this once during `registerMcpTools` so the install surface stays
/// identical across studios. Moved out of vibe_studio's host file into
/// base so the body of the registration is shared verbatim.
library;

import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/bundle_install_surface.dart';
import '../main/chrome_bridge.dart';
import 'bundle_loading.dart';
import 'bundle_manifest_validator.dart';
import 'internal_call_guard.dart';

/// Enrich a registry entry with activation-schema fields from the
/// bundle's manifest — `name`, `agents`/`tools`/`ui` counts, manifest
/// validation issue counts. Used by `studio.bundle.list` so callers can
/// preview activation surface area without re-reading the manifest.
Map<String, dynamic> _enrichBundleEntry(Map<String, dynamic> e) {
  final mbd = (e['mbdPath'] ?? e['path'] ?? '').toString();
  final b = mbd.isEmpty ? null : readBundleAt(mbd);
  if (b == null) return Map<String, dynamic>.from(e);
  final issues = BundleManifestValidator.validate(b);
  final errors =
      issues.where((i) => i.severity == ManifestIssueSeverity.error).length;
  final warnings =
      issues.where((i) => i.severity == ManifestIssueSeverity.warning).length;
  final uiEntry = b.uiEntry;
  return <String, dynamic>{
    ...e,
    'name': b.displayLabel,
    'shortId': b.shortId,
    'agents': b.agents?.agents.length ?? 0,
    'tools': b.tools?.tools.length ?? 0,
    if (uiEntry != null) 'ui': uiEntry.kind,
    if (errors > 0 || warnings > 0)
      'manifestIssues': <String, int>{'errors': errors, 'warnings': warnings},
  };
}

/// Register the five `studio.bundle.*` install / lifecycle tools onto
/// [boot]. Handlers read from [bundles] (install / list / uninstall)
/// and [bridge] (activate / dispatch_tool); the host wires the bridge
/// setters when its shell mounts.
void registerBundleInstallTools(
  mk.KernelServerHost boot, {
  required BundleInstallSurface bundles,
  required ChromeBridge bridge,
}) {
  boot.addTool(
    name: 'studio.bundle.dispatch_tool',
    description:
        'Invoke a bundle\'s exposed MCP tool via the host\'s bridge '
        '— the same code path chrome buttons (settings menu / domain '
        'icon row) use when dispatching a wired bundle action. Lets '
        'an external LLM trigger a bundle\'s verb without knowing the '
        'activated namespace prefix: pass the `mbdPath` (or omit to '
        'use the active bundle) and the bare `tool` short id, and '
        'the host resolves to `<exposedNamespace>.<tool>` and calls '
        'it. `arguments` is forwarded verbatim. Use this for '
        'bundle-side authoring (e.g. driving a bundle\'s own MCP '
        'server during a UI build) without juggling namespaces.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description':
              'Path of the bundle that owns the tool. When omitted, '
              'the host uses the active tab\'s bundle path.',
        },
        'tool': <String, dynamic>{
          'type': 'string',
          'description':
              'Bare tool short id (no namespace prefix). The host '
              'resolves to `<exposedNamespace>.<tool>`.',
        },
        'arguments': <String, dynamic>{
          'type': 'object',
          'description': 'Forwarded to the bundle tool as-is.',
        },
      },
      'required': <String>['tool'],
    },
    handler: (args) async {
      final fn = bridge.dispatchBundleTool;
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
      final toolShort = args['tool'];
      if (toolShort is! String || toolShort.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"reason":"tool (string) required"}',
            ),
          ],
          isError: true,
        );
      }
      String mbdPath = args['mbdPath']?.toString() ?? '';
      if (mbdPath.isEmpty) {
        final info = bridge.activeProjectInfo?.call();
        final activeBundle = info?['packagePath']?.toString();
        if (activeBundle == null || activeBundle.isEmpty) {
          return mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text:
                    '{"ok":false,"reason":"mbdPath omitted and no active bundle"}',
              ),
            ],
            isError: true,
          );
        }
        mbdPath = activeBundle;
      }
      final rawArgs = args['arguments'];
      final forwardArgs =
          rawArgs is Map<String, dynamic>
              ? rawArgs
              : (rawArgs is Map
                  ? Map<String, dynamic>.from(rawArgs)
                  : <String, dynamic>{});
      // ignore: unawaited_futures
      fn(mbdPath, toolShort, forwardArgs);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'mbdPath': mbdPath,
              'tool': toolShort,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.bundle.install',
    description:
        'Install a package into the universal host. The required '
        'argument is `path` — filesystem path to a `.mcpb` archive '
        'or a `.mbd/` directory. (Note: argument key is `path`, not '
        '`mbdPath` / `bundlePath` — those produce `path required`.) '
        'On success the active tab pointing at this bundle is asked '
        'to reload so newly-declared `manifest.tools[]` / `agents[]` '
        'surface immediately without a manual `studio.chrome.reload_tab`. '
        'Returns `{ok: true, namespace, mbdPath}` on success or '
        '`{ok: false, error}` on failure.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{
          'type': 'string',
          'description': 'Filesystem path to a .mcpb or .mbd source.',
        },
      },
      'required': <String>['path'],
    },
    handler: (args) async {
      final g = internalGuard(bridge, 'studio.bundle.install');
      if (g != null) return g;
      final path = args['path'];
      if (path is! String || path.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"path required"}'),
          ],
          isError: true,
        );
      }
      final result = await bundles.install(path);
      // Ask the active tab to reload — when the just-installed bundle
      // is the active one, this picks up any new manifest.tools[] /
      // agents[] / ui changes the install carried.
      try {
        bridge.reloadTab?.call(null);
      } catch (_) {
        /* best-effort */
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(result)),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.bundle.list',
    description:
        'List packages installed in the universal host. Each entry '
        'is enriched with `name` (manifest.name → fallback to last '
        'dotted segment of manifest.id) so callers can render '
        'human-friendly labels without re-reading the manifest. '
        'Returns `{bundles: [{namespace, mbdPath, installedAt, '
        'name}]}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final raw = await bundles.list();
      // Filter built-in app + host docs seeds. Those live in the
      // bundle registry for knowledge fan-out but the install surface
      // is the user-install view — seeds open through the home picker,
      // not through `studio.bundle.*`. Without this filter an external
      // caller would see seeds as installed packages and could pick
      // their `mbdPath` to call `studio.bundle.activate`.
      final seedPaths = bridge.builtInSeedMbdPaths;
      final enriched = <Map<String, dynamic>>[
        for (final e in raw)
          if (!seedPaths.contains(e['mbdPath'] as String? ?? ''))
            _enrichBundleEntry(e),
      ];
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{'bundles': enriched}),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.bundle.activate',
    description:
        'Open an installed package as a tab (or focus it if already '
        'open). Same code path as the user tapping a card in the '
        'home picker. Returns `{active, key, name}` reflecting the '
        'resulting tab.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['mbdPath'],
    },
    handler: (args) async {
      final g = internalGuard(bridge, 'studio.bundle.activate');
      if (g != null) return g;
      final path = args['mbdPath'];
      if (path is! String || path.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"mbdPath required"}'),
          ],
          isError: true,
        );
      }
      // Reject paths that do not point at a real bundle. Without this
      // guard, a typo silently creates a phantom tab (no manifest, no
      // tools, no agents) and the user has no signal it failed.
      final dir = Directory(path);
      if (!dir.existsSync()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'error': 'mbdPath does not exist',
                'mbdPath': path,
              }),
            ),
          ],
          isError: true,
        );
      }
      final manifestFile = File('$path/manifest.json');
      if (!manifestFile.existsSync()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'error':
                    'mbdPath has no manifest.json (not a valid bundle directory)',
                'mbdPath': path,
              }),
            ),
          ],
          isError: true,
        );
      }
      // Reject built-in app + host docs seed paths. Seeds ship with
      // the studio binary and are not user-installed packages — opening
      // them as tabs through this tool would bypass the install gate
      // entirely. The home picker (built-in app cards) is the single
      // entry point for built-in apps.
      if (bridge.builtInSeedMbdPaths.contains(path)) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error':
                    'built-in app seed — open via the home picker, '
                    'not studio.bundle.activate',
                'mbdPath': path,
              }),
            ),
          ],
          isError: true,
        );
      }
      // Reject paths that are not in the install registry. Without
      // this gate any directory carrying a `manifest.json` (a path the
      // caller crafted under /tmp, a sibling clone, anything reachable
      // by the studio process) would mount as a tab. Only packages the
      // user actually installed (`studio.bundle.install` or the
      // Library card) belong here.
      final installedRaw = await bundles.list();
      final installedPaths = <String>{
        for (final e in installedRaw) e['mbdPath'] as String? ?? '',
      };
      if (!installedPaths.contains(path)) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error':
                    'mbdPath is not in the install registry — install '
                    'the package first via studio.bundle.install',
                'mbdPath': path,
              }),
            ),
          ],
          isError: true,
        );
      }
      final fn = bridge.activatePackage;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"shell not mounted yet"}'),
          ],
          isError: true,
        );
      }
      final result = await fn(path);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(result)),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.bundle.uninstall',
    description:
        'Remove a package. Pass either `mbdPath` (absolute path) OR '
        '`namespace` (id from `studio.bundle.list`) — the handler '
        'resolves namespace to the matching mbdPath via the registry. '
        'Returns `{ok: true, removed: bool, mbdPath, namespace}` '
        '(`removed: false` when nothing matched). Does not delete '
        'extracted files on disk.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description':
              'Absolute path to the installed `.mbd/`. Either this or '
              '`namespace` is required.',
        },
        'namespace': <String, dynamic>{
          'type': 'string',
          'description':
              'Registered namespace (manifest.id). Looked up against '
              'the bundle registry to find the matching mbdPath.',
        },
      },
    },
    handler: (args) async {
      final g = internalGuard(bridge, 'studio.bundle.uninstall');
      if (g != null) return g;
      String? path =
          args['mbdPath'] is String && (args['mbdPath'] as String).isNotEmpty
              ? args['mbdPath'] as String
              : null;
      final namespace =
          args['namespace'] is String &&
                  (args['namespace'] as String).isNotEmpty
              ? args['namespace'] as String
              : null;
      if (path == null && namespace != null) {
        final entries = await bundles.list();
        for (final e in entries) {
          if (e['namespace'] == namespace) {
            final mp = e['mbdPath'];
            if (mp is String && mp.isNotEmpty) {
              path = mp;
              break;
            }
          }
        }
        if (path == null) {
          return mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text: jsonEncode(<String, dynamic>{
                  'ok': false,
                  'error': 'namespace not registered',
                  'namespace': namespace,
                }),
              ),
            ],
            isError: true,
          );
        }
      }
      if (path == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"mbdPath or namespace required"}',
            ),
          ],
          isError: true,
        );
      }
      final result = await bundles.uninstall(path);
      // Tab lifecycle invariant — uninstalled packages cannot remain
      // open as tabs. Cascade close every tab pointing at this mbdPath
      // so the chrome strip reflects the install registry truth.
      List<String> closedTabs = const <String>[];
      try {
        closedTabs = bridge.closeTabsByMbdPath?.call(path) ?? const <String>[];
      } catch (_) {
        /* best-effort — registry already updated */
      }
      try {
        bridge.reloadTab?.call(null);
      } catch (_) {
        /* best-effort */
      }
      // Drop this bundle from the domain server pool. Tear-down of
      // any now-empty `domainSpawned` instance lands in Phase 5+.
      bridge.domainServerManager?.detach(path);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              ...result,
              'mbdPath': path,
              if (namespace != null) 'namespace': namespace,
              'closedTabs': closedTabs,
            }),
          ),
        ],
      );
    },
  );
}
