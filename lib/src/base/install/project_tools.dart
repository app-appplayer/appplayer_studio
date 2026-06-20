/// `registerProjectTools` — register the 6 `studio.project.*` MCP
/// tools (new · open · close · info · recents · create) onto a kernel
/// `ServerBootstrap`. Five route through a [ChromeBridge] callback
/// (the same code path a chrome button click exercises); the sixth
/// (`recents`) reads directly from disk via `VibeSettings.load` so MRU
/// reflects concurrent settings-dialog edits without a process reload.
///
/// `studio.project.create` is the generic disk-layout primitive — it
/// invokes [createProjectFolder] in `project_layout.dart`. Domain-level
/// wrappers (e.g. `studio_builder.newProject`) live in their host
/// because they know the bundle template + adoption flow; they call
/// `createProjectFolder` directly to share the same on-disk shape.
///
/// Lives in `vibe_studio_base` so every studio host gets the project
/// surface for free.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/chrome_bridge.dart';
import '../settings/vibe_settings.dart';
import 'project_layout.dart';

/// Register all 6 `studio.project.*` tools onto [boot]. Handlers read
/// from [bridge] for the lifecycle-routed verbs; [toolId] feeds
/// `VibeSettings.defaultPath` for the `recents` reader.
void registerProjectTools(
  mk.KernelServerHost boot,
  ChromeBridge bridge, {
  required String toolId,
}) {
  boot.addTool(
    name: 'studio.project.new',
    description:
        'Create a new project directory at `<parent>/<name>` and set '
        'it active in the current package tab. `parent` defaults to '
        '`VibeSettings.workspaceDir` when omitted — bundle tools that '
        'wrap project.new (e.g. `app_builder.newAppProject`) usually '
        'omit it so the host honours the user\'s configured workspace. '
        'Returns `{ok: true, projectPath}` or `{ok: false, error}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'name': <String, dynamic>{'type': 'string'},
        'parent': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional. Defaults to settings.workspaceDir. Pass an '
              'absolute path to override.',
        },
      },
      'required': <String>['name'],
    },
    handler: (args) async {
      final fn = bridge.newProjectInActive;
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
      final name = args['name'];
      if (name is! String || name.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"name required (string)"}',
            ),
          ],
          isError: true,
        );
      }
      // parent fallback — settings.workspaceDir. Bundle tools (e.g.
      // app_builder.newAppProject) call this without parent so the
      // host can honour the user's configured workspace.
      var parent = args['parent'];
      if (parent is! String || parent.isEmpty) {
        try {
          final settings = await VibeSettings.load(
            VibeSettings.defaultPath(toolId),
          );
          parent = settings.workspaceDir;
        } catch (_) {
          parent = null;
        }
      }
      if (parent is! String || parent.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text:
                  '{"ok":false,"error":"parent missing and no '
                  'workspaceDir set in settings — pass parent or '
                  'configure Studio settings → Workspace dir"}',
            ),
          ],
          isError: true,
        );
      }
      final result = await fn(name: name, parent: parent);
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(result)),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.project.open',
    description:
        'Open an existing project directory in the current package '
        'tab. With `path` set: programmatic open (no dialog). Without '
        '`path`: opens the OS folder picker rooted at the studio '
        'workspaceDir setting. Returns `{ok, projectPath}` on success, '
        '`{ok: false, cancelled: true}` when the user dismisses the '
        'dialog.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{'type': 'string'},
      },
    },
    handler: (args) async {
      final path = args['path'];
      if (path is String && path.isNotEmpty) {
        final fn = bridge.openProjectInActive;
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
        final result = await fn(path);
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: jsonEncode(result)),
          ],
        );
      }
      final dialog = bridge.openProjectDialog;
      if (dialog == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"shell not mounted"}',
            ),
          ],
          isError: true,
        );
      }
      await dialog();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: '{"ok":true,"opened":"via-dialog"}'),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.project.close',
    description:
        'Close the project in the current package tab (return to '
        'State B welcome). Returns `{ok, closed}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.closeProjectInActive;
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
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(fn())),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.project.info',
    description:
        'Snapshot of the active tab\'s project context — '
        '`{packageName, packagePath, projectPath, projectName}`. '
        'Fields are omitted when no project / no package is active. '
        'Returns `{}` on the home tab.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      final fn = bridge.activeProjectInfo;
      if (fn == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"shell not mounted yet"}'),
          ],
          isError: true,
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
    name: 'studio.project.recents',
    description:
        'Most-recently-opened project paths in MRU order (newest '
        'first). Capped at the host\'s `recentProjectsLimit`. '
        'Returns `{recents: [path, ...], lastProjectPath}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    handler: (args) async {
      // Settings live on disk under VibeSettings.defaultPath(toolId).
      // Read fresh so concurrent edits (settings dialog Save) are
      // reflected without reloading the host process.
      final s = await VibeSettings.load(VibeSettings.defaultPath(toolId));
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'recents': s.recentProjects,
              if (s.lastProjectPath != null)
                'lastProjectPath': s.lastProjectPath,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.project.create',
    description:
        'Create a workspace-scoped project folder at `<parent>/<name>/` '
        'with the standard layout: project metadata file, bundle subdir, '
        '`drafts/`, `build/`, plus any `initialFiles` the caller supplies. '
        'Domain tools wrap this with their own extension + template '
        'config. Refuses if the path already exists or `name` contains '
        'path separators. Returns `{ok, projectPath, bundlePath, metaFile}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'name': <String, dynamic>{'type': 'string'},
        'parent': <String, dynamic>{
          'type': 'string',
          'description':
              'Parent directory (typically the studio '
              'workspaceDir setting).',
        },
        'ext': <String, dynamic>{
          'type': 'string',
          'description': 'Project metadata file extension. Default `.sbproj`.',
        },
        'bundleSubdir': <String, dynamic>{
          'type': 'string',
          'description':
              'Bundle subdirectory name under the project. Default '
              '`<name>.mbd`.',
        },
        'initialFiles': <String, dynamic>{
          'type': 'array',
          'description':
              'Files to seed inside the project. Each entry '
              '`{path, content}` — path is relative to the new project '
              'folder; content is a string (verbatim) or an object '
              '(written as JSON).',
          'items': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'path': <String, dynamic>{'type': 'string'},
              'content': <String, dynamic>{},
            },
          },
        },
      },
      'required': <String>['name', 'parent'],
    },
    handler: (args) async {
      final name = args['name'];
      final parent = args['parent'];
      if (name is! String) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"name required"}'),
          ],
          isError: true,
        );
      }
      if (parent is! String) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"parent required"}',
            ),
          ],
          isError: true,
        );
      }
      final rawFiles = args['initialFiles'];
      final files = <Map<String, dynamic>>[];
      if (rawFiles is List) {
        for (final entry in rawFiles) {
          if (entry is Map) {
            files.add(Map<String, dynamic>.from(entry));
          }
        }
      }
      final result = await createProjectFolder(
        name: name,
        parent: parent,
        ext: (args['ext'] as String?) ?? '.sbproj',
        bundleSubdir: args['bundleSubdir'] as String?,
        initialFiles: files,
      );
      final isError = result['ok'] != true;
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(text: jsonEncode(result)),
        ],
        isError: isError,
      );
    },
  );
  boot.addTool(
    name: 'studio.project.export',
    description:
        'Pack/copy an `.mbd` bundle directory to a destination. '
        'Required: `bundlePath` (absolute path to `.mbd/`). Optional: '
        '`format` ("mcpb" zip archive · "mbd" folder copy · default '
        '"mcpb"), `target` (output path · defaults to '
        '`<bundleParent>/build/<bundleName>.<format>`). Returns '
        '`{ok, format, target}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'bundlePath': <String, dynamic>{'type': 'string'},
        'format': <String, dynamic>{
          'type': 'string',
          'enum': <String>['mcpb', 'mbd'],
        },
        'target': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['bundlePath'],
    },
    handler: (args) async {
      final bundlePath = args['bundlePath'];
      if (bundlePath is! String || bundlePath.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"bundlePath (string) required"}',
            ),
          ],
          isError: true,
        );
      }
      final src = Directory(bundlePath);
      if (!await src.exists()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"bundle not found"}',
            ),
          ],
          isError: true,
        );
      }
      final format = (args['format'] as String?) ?? 'mcpb';
      // Default target: <projectDir>/build/<bundleName>.<ext>
      String? target = args['target'] as String?;
      if (target == null || target.isEmpty) {
        final bundleName = p.basenameWithoutExtension(bundlePath);
        final projectDir = p.dirname(bundlePath);
        final ext = format == 'mbd' ? '.mbd' : '.mcpb';
        target = p.join(projectDir, 'build', '$bundleName$ext');
      }
      await Directory(p.dirname(target)).create(recursive: true);
      try {
        if (format == 'mcpb') {
          await mk.McpbPackager.pack(bundlePath, target, overwrite: true);
        } else if (format == 'mbd') {
          // Folder copy (recursive).
          final dst = Directory(target);
          if (await dst.exists()) {
            await dst.delete(recursive: true);
          }
          await dst.create(recursive: true);
          await for (final entity in src.list(
            recursive: true,
            followLinks: false,
          )) {
            final rel = p.relative(entity.path, from: bundlePath);
            final dstPath = p.join(target, rel);
            if (entity is Directory) {
              await Directory(dstPath).create(recursive: true);
            } else if (entity is File) {
              await Directory(p.dirname(dstPath)).create(recursive: true);
              await entity.copy(dstPath);
            }
          }
        } else {
          return mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text: '{"ok":false,"error":"unknown format: $format"}',
              ),
            ],
            isError: true,
          );
        }
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': true,
                'format': format,
                'target': target,
              }),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"$e"}'),
          ],
          isError: true,
        );
      }
    },
  );
  boot.addTool(
    name: 'studio.settings.get',
    description:
        'Read a value from the studio-wide `VibeSettings` file '
        '(`~/.config/<toolId>/settings.json`) or a per-domain '
        'override file (`<configRoot>/package_settings/<safe(path)>'
        '.json`). Required: `key` (e.g. `workspaceDir`, `llmModel`, '
        '`mcpTransport`, `inheritFromSystem`, `mcpServerUrl`). '
        'Optional `path` selects a domain override — when set, reads '
        '`package_settings/<safe(path)>.json` instead of system. '
        'Returns `{key, value, scope:"system|domain", path?}` — '
        'value is `null` if unset.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'key': <String, dynamic>{'type': 'string'},
        'path': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional. Domain mbdPath or built-in workspace path. '
              'When set, reads from the per-domain override file.',
        },
      },
      'required': <String>['key'],
    },
    handler: (args) async {
      final key = args['key'];
      if (key is! String || key.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"key (string) required"}'),
          ],
          isError: true,
        );
      }
      final domainPath = args['path']?.toString();
      try {
        if (domainPath != null && domainPath.isNotEmpty) {
          final overrideFile = _resolveOverrideFile(bridge, domainPath);
          if (overrideFile == null) {
            return mk.KernelToolResult(
              content: <mk.KernelContent>[
                mk.KernelTextContent(
                  text: '{"error":"configRoot not configured"}',
                ),
              ],
              isError: true,
            );
          }
          Map<String, dynamic> content = <String, dynamic>{};
          if (overrideFile.existsSync()) {
            try {
              final raw = jsonDecode(overrideFile.readAsStringSync());
              if (raw is Map<String, dynamic>) content = raw;
            } catch (_) {
              /* corrupt — empty */
            }
          }
          return mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text: jsonEncode(<String, Object?>{
                  'key': key,
                  'value': content[key],
                  'scope': 'domain',
                  'path': domainPath,
                  'file': overrideFile.path,
                }),
              ),
            ],
          );
        }
        final settings = await VibeSettings.load(
          VibeSettings.defaultPath(toolId),
        );
        final json = settings.toJson();
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'key': key,
                'value': json[key],
                'scope': 'system',
              }),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"$e"}'),
          ],
          isError: true,
        );
      }
    },
  );
  boot.addTool(
    name: 'studio.settings.set',
    description:
        'Write a value to studio-wide settings (`~/.config/<toolId>/'
        'settings.json`) or to a per-domain override file '
        '(`<configRoot>/package_settings/<safe(path)>.json`). Pass '
        '`key` + `value`. Optional `path` selects domain scope — when '
        'set, this also re-fires `DomainServerManager.attach` so a '
        'change to `inheritFromSystem` / `mcpServerUrl` takes effect '
        'at runtime without restart. Returns `{ok, scope, path?, '
        'key, value, reattached?}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'key': <String, dynamic>{'type': 'string'},
        'value': <String, dynamic>{
          'description': 'Any JSON value. Pass `null` to remove the key.',
        },
        'path': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional. Domain mbdPath or built-in workspace path. '
              'When set, writes to per-domain override file.',
        },
      },
      'required': <String>['key'],
    },
    handler: (args) async {
      final key = args['key'];
      if (key is! String || key.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"key (string) required"}'),
          ],
          isError: true,
        );
      }
      final value = args['value'];
      final domainPath = args['path']?.toString();
      try {
        if (domainPath != null && domainPath.isNotEmpty) {
          final overrideFile = _resolveOverrideFile(bridge, domainPath);
          if (overrideFile == null) {
            return mk.KernelToolResult(
              content: <mk.KernelContent>[
                mk.KernelTextContent(
                  text: '{"error":"configRoot not configured"}',
                ),
              ],
              isError: true,
            );
          }
          // Merge into existing content.
          Map<String, dynamic> content = <String, dynamic>{};
          if (overrideFile.existsSync()) {
            try {
              final raw = jsonDecode(overrideFile.readAsStringSync());
              if (raw is Map<String, dynamic>) {
                content = Map<String, dynamic>.from(raw);
              }
            } catch (_) {
              // Corrupt override. Back it up before the write below
              // overwrites it with a fresh single-key map — otherwise
              // EVERY other domain's key in this shared override file is
              // silently wiped (data-loss class). The `.corrupt-<ts>`
              // copy lets the user recover the other keys.
              try {
                final stamp = DateTime.now().millisecondsSinceEpoch;
                overrideFile.copySync('${overrideFile.path}.corrupt-$stamp');
                stderr.writeln(
                  'studio.settings.set: corrupt override backed up '
                  '(${p.basename(overrideFile.path)}.corrupt-$stamp) '
                  'before rewrite',
                );
              } catch (_) {
                /* backup best-effort */
              }
            }
          }
          if (value == null) {
            content.remove(key);
          } else {
            content[key] = value;
          }
          overrideFile.parent.createSync(recursive: true);
          overrideFile.writeAsStringSync(jsonEncode(content));
          // Trigger DomainServerManager re-attach so runtime picks up
          // the new inheritFromSystem / mcpServerUrl without restart.
          // Only meaningful for MCP-server-related keys, but harmless
          // for others (attach is idempotent for inherit=true case).
          bool reattached = false;
          String? reattachError;
          final mgr = bridge.domainServerManager;
          if (mgr != null) {
            try {
              final inherit = content['inheritFromSystem'] != false;
              final url = content['mcpServerUrl'] as String?;
              mgr.detach(domainPath);
              final outcome = await mgr.attach(
                domainPath,
                inheritFromSystem: inherit,
                url: url,
              );
              reattached = outcome.ok;
              if (!outcome.ok) reattachError = outcome.error;
            } catch (e) {
              reattachError = e.toString();
            }
          }
          return mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text: jsonEncode(<String, Object?>{
                  'ok': true,
                  'scope': 'domain',
                  'path': domainPath,
                  'file': overrideFile.path,
                  'key': key,
                  'value': value,
                  'reattached': reattached,
                  if (reattachError != null) 'reattachError': reattachError,
                }),
              ),
            ],
          );
        }
        // System scope.
        final path = VibeSettings.defaultPath(toolId);
        // Detect a corrupt settings file BEFORE load(): load() silently
        // returns defaults on a parse failure, so writing the result back
        // would overwrite every existing key in the file with defaults
        // (data-loss class). Back the corrupt file up so the user can
        // recover, mirroring the domain-scope path above.
        final systemFile = File(path);
        if (systemFile.existsSync()) {
          try {
            jsonDecode(systemFile.readAsStringSync());
          } catch (_) {
            try {
              final stamp = DateTime.now().millisecondsSinceEpoch;
              systemFile.copySync('${systemFile.path}.corrupt-$stamp');
              stderr.writeln(
                'studio.settings.set: corrupt settings backed up '
                '(${p.basename(systemFile.path)}.corrupt-$stamp) '
                'before rewrite',
              );
            } catch (_) {
              /* backup best-effort */
            }
          }
        }
        final settings = await VibeSettings.load(path);
        final json = Map<String, dynamic>.from(settings.toJson());
        if (value == null) {
          json.remove(key);
        } else {
          json[key] = value;
        }
        await File(path).writeAsString(jsonEncode(json));
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': true,
                'scope': 'system',
                'file': path,
                'key': key,
                'value': value,
              }),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"error":"$e"}'),
          ],
          isError: true,
        );
      }
    },
  );
}

/// Resolve the per-domain override file path the same way the
/// workspace shell + host attach use (safe-character mangle of
/// the domain mbdPath).
File? _resolveOverrideFile(ChromeBridge bridge, String domainPath) {
  final cfg = bridge.debugConfig?.call() ?? <String, dynamic>{};
  final root = cfg['configRoot']?.toString() ?? '';
  if (root.isEmpty) return null;
  final safe = domainPath.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
  return File(p.join(root, 'package_settings', '$safe.json'));
}
