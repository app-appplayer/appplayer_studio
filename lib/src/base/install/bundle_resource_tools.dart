/// Host-level MCP tools that read a bundle's reserved sub-folders per
/// mcp_bundle [BundleFolder] spec (7 reserved: ui · assets · skills ·
/// knowledge · profiles · philosophy · agents). Domain tools (`<bundle>.<tool>`)
/// reach their *own* bundle's resources through these without rolling
/// their own file IO — path traversal (`..`) is rejected by
/// [BundleResources].
///
/// Hosts call [registerBundleResourceTools] once during boot. The tools
/// register on the [mk.KernelServerHost] alongside the host's other
/// `studio.*` surfaces. No host-specific dependencies — every studio
/// gets the same readers for free.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

/// Add `studio.bundle.list_assets` + `studio.bundle.read_asset` to
/// [boot]. Both accept an `mbdPath` parameter so callers can target any
/// installed / activated bundle. The optional `folder` argument selects
/// one of the seven reserved [BundleFolder] slots; default `assets`.
void registerBundleResourceTools(mk.KernelServerHost boot) {
  boot.addTool(
    name: 'studio.bundle.list_assets',
    description:
        'List files under the bundle\'s reserved `<folder>/` slot '
        '(default `assets`). Optional `subpath` filters to entries '
        'whose path starts with that prefix. Returns '
        '`{ok, paths: [<relative>, ...]}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the `.mbd/` directory. Required.',
        },
        'folder': <String, dynamic>{
          'type': 'string',
          'description':
              'Reserved folder name — one of `ui`, `assets`, `skills`, '
              '`knowledge`, `profiles`, `philosophy`, `agents`. '
              'Default `assets`.',
        },
        'subpath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional prefix filter relative to the folder root.',
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
              text: '{"ok":false,"error":"mbdPath required"}',
            ),
          ],
          isError: true,
        );
      }
      final folderName = (args['folder'] as String?) ?? 'assets';
      final folder = _bundleFolderByName(folderName);
      if (folder == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'unknown folder: $folderName',
              }),
            ),
          ],
          isError: true,
        );
      }
      final resources = BundleResources(bundleRoot: mbd, folder: folder);
      final all = await resources.list();
      final sub = args['subpath'] as String?;
      final paths =
          (sub == null || sub.isEmpty)
              ? all
              : all
                  .where(
                    (p) =>
                        p.startsWith(sub.endsWith('/') ? sub : '$sub/') ||
                        p == sub,
                  )
                  .toList();
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, Object?>{
              'ok': true,
              'folder': folderName,
              'paths': paths,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.bundle.read_asset',
    description:
        'Read a UTF-8 text file under the bundle\'s reserved '
        '`<folder>/` slot (default `assets`). Returns '
        '`{ok, content}` or `{ok: false, error}` on missing / decode '
        'failure.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the `.mbd/` directory. Required.',
        },
        'folder': <String, dynamic>{
          'type': 'string',
          'description':
              'Reserved folder name — one of `ui`, `assets`, `skills`, '
              '`knowledge`, `profiles`, `philosophy`, `agents`. '
              'Default `assets`.',
        },
        'path': <String, dynamic>{
          'type': 'string',
          'description':
              'Path relative to the folder root. Path traversal '
              '(`..`) is rejected.',
        },
      },
      'required': <String>['mbdPath', 'path'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final relPath = args['path'];
      if (mbd is! String || mbd.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"mbdPath required"}',
            ),
          ],
          isError: true,
        );
      }
      if (relPath is! String || relPath.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"path required"}'),
          ],
          isError: true,
        );
      }
      final folderName = (args['folder'] as String?) ?? 'assets';
      final folder = _bundleFolderByName(folderName);
      if (folder == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'unknown folder: $folderName',
              }),
            ),
          ],
          isError: true,
        );
      }
      try {
        final resources = BundleResources(bundleRoot: mbd, folder: folder);
        final content = await resources.read(relPath);
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': true,
                'folder': folderName,
                'path': relPath,
                'content': content,
              }),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'read failed: $e',
              }),
            ),
          ],
          isError: true,
        );
      }
    },
  );

  // ── Bundle-root scoped read tools (no reserved-folder whitelist) ──
  //
  // The `studio.bundle.list_assets` / `read_asset` pair above limit the
  // reach to the 7 reserved `BundleFolder` slots (ui/assets/skills/...).
  // Real bundles also carry domain-specific subfolders (e.g.
  // `scenarios/`, `branding/`, `tools/`) that those tools cannot see.
  // The two below address that without forking BundleFolder: anything
  // under the bundle root is readable, `..` and absolute paths are
  // rejected, and per-bundle scope is preserved by requiring mbdPath.

  boot.addTool(
    name: 'studio.bundle.list_files',
    description:
        'List files (recursively) under the bundle root at `mbdPath`. '
        'Optional `subpath` filters to entries whose relative path '
        'starts with that prefix. Unlike `studio.bundle.list_assets` '
        'this is NOT confined to the 7 reserved BundleFolder slots — '
        'it sees every file under the bundle root (e.g. `scenarios/*.json`, '
        '`branding/theme.json`, `tools/*.js`). Symlinks are followed; '
        '`..` in `subpath` is rejected. Returns '
        '`{ok, paths:[<relative>,...]}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the bundle directory.',
        },
        'subpath': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional prefix filter relative to the bundle root. '
              '`..` and absolute paths rejected.',
        },
      },
      'required': <String>['mbdPath'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final sub = args['subpath'];
      if (mbd is! String || mbd.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'mbdPath required',
              }),
            ),
          ],
          isError: true,
        );
      }
      if (sub is String) {
        if (p.isAbsolute(sub) || sub.contains('..')) {
          return mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text: jsonEncode(<String, Object?>{
                  'ok': false,
                  'error': 'subpath must be relative + no `..`',
                }),
              ),
            ],
            isError: true,
          );
        }
      }
      final root = Directory(mbd);
      if (!await root.exists()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'bundle not found',
              }),
            ),
          ],
          isError: true,
        );
      }
      final prefix = (sub is String && sub.isNotEmpty) ? sub : null;
      try {
        final out = <String>[];
        await for (final entity in root.list(recursive: true)) {
          if (entity is! File) continue;
          final rel = p.relative(entity.path, from: root.path);
          if (prefix != null && !rel.startsWith(prefix)) continue;
          out.add(rel);
        }
        out.sort();
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': true,
                if (prefix != null) 'subpath': prefix,
                'paths': out,
              }),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'list failed: $e',
              }),
            ),
          ],
          isError: true,
        );
      }
    },
  );

  boot.addTool(
    name: 'studio.bundle.read_file',
    description:
        'Read a UTF-8 text file under the bundle root at `mbdPath`. '
        'Unlike `studio.bundle.read_asset` this is NOT confined to the '
        '7 reserved BundleFolder slots — any file under the bundle '
        'root is readable (e.g. `scenarios/intro.json`, '
        '`branding/theme.json`, `tools/<name>.js`). `..` and absolute '
        '`relPath` are rejected so the scope is preserved to the bundle. '
        'Returns `{ok, content}` or `{ok:false, error}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the bundle directory.',
        },
        'relPath': <String, dynamic>{
          'type': 'string',
          'description':
              'Path relative to the bundle root. Must be relative '
              '(no leading `/`) and cannot contain `..` segments.',
        },
      },
      'required': <String>['mbdPath', 'relPath'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final rel = args['relPath'];
      if (mbd is! String || mbd.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'mbdPath required',
              }),
            ),
          ],
          isError: true,
        );
      }
      if (rel is! String || rel.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'relPath required',
              }),
            ),
          ],
          isError: true,
        );
      }
      if (p.isAbsolute(rel) || rel.contains('..')) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'relPath must be relative + no `..`',
              }),
            ),
          ],
          isError: true,
        );
      }
      try {
        final file = File(p.join(mbd, rel));
        if (!await file.exists()) {
          return mk.KernelToolResult(
            content: <mk.KernelContent>[
              mk.KernelTextContent(
                text: jsonEncode(<String, Object?>{
                  'ok': false,
                  'error': 'file not found: $rel',
                }),
              ),
            ],
            isError: true,
          );
        }
        final content = await file.readAsString();
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': true,
                'path': rel,
                'content': content,
              }),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, Object?>{
                'ok': false,
                'error': 'read failed: $e',
              }),
            ),
          ],
          isError: true,
        );
      }
    },
  );
}

/// Map a friendly folder name (`'ui'`, `'assets'`, …) to the matching
/// [BundleFolder]. Returns `null` when the name doesn't match any of
/// the seven reserved slots — callers surface this as an error to the
/// MCP caller rather than silently picking a wrong folder.
BundleFolder? _bundleFolderByName(String name) {
  for (final f in BundleFolder.values) {
    if (f.name == name) return f;
  }
  return null;
}
