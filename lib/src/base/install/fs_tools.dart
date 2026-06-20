/// Host-level MCP file IO primitives, scoped to the studio's
/// workspaceDir (from [VibeSettings]). Domain tools call these to read /
/// write data files under the workspace without rolling their own
/// `dart:io` — the workspace boundary check prevents a misbehaving
/// bundle from reading outside (`..` rejected, absolute paths must be
/// prefixed by workspaceDir).
///
/// Tools registered:
///   - `studio.fs.read({path})`   → `{ok, content}`
///   - `studio.fs.write({path, content})` → `{ok, bytes}`
///   - `studio.fs.mkdir({path})`  → `{ok, created}`
///   - `studio.fs.list({path})`   → `{ok, entries: [{name, type, size?}]}`
///   - `studio.fs.delete({path, recursive?})` → `{ok, deleted}`
///
/// All `path` arguments are absolute paths. Refused if not inside the
/// resolved workspaceDir.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../settings/vibe_settings.dart';

/// Add the 5 `studio.fs.*` primitives to [boot]. [toolId] identifies the
/// host so `VibeSettings.defaultPath(toolId)` resolves to the right
/// `~/.config/<toolId>/settings.json` for workspaceDir lookup.
void registerFsTools(mk.KernelServerHost boot, {required String toolId}) {
  Future<String?> resolveWorkspace() async {
    try {
      final s = await VibeSettings.load(VibeSettings.defaultPath(toolId));
      return s.workspaceDir;
    } catch (_) {
      return null;
    }
  }

  /// Returns null on success; otherwise an error payload describing
  /// why the path was rejected.
  Map<String, Object?>? rejectIfOutsideWorkspace(
    String path,
    String workspace,
  ) {
    final normalised = p.normalize(p.absolute(path));
    final normalisedWorkspace = p.normalize(p.absolute(workspace));
    final inside =
        normalised == normalisedWorkspace ||
        normalised.startsWith('$normalisedWorkspace${p.separator}');
    if (!inside) {
      return <String, Object?>{
        'ok': false,
        'error':
            'path outside workspaceDir (configured `$normalisedWorkspace`)',
      };
    }
    return null;
  }

  Future<Map<String, Object?>> guard(
    Map<String, dynamic> args,
    Future<Map<String, Object?>> Function(String absPath, String workspace) op,
  ) async {
    final raw = args['path'];
    if (raw is! String || raw.isEmpty) {
      return <String, Object?>{'ok': false, 'error': 'path required'};
    }
    final workspace = await resolveWorkspace();
    if (workspace == null || workspace.isEmpty) {
      return <String, Object?>{
        'ok': false,
        'error': 'workspaceDir not configured — set it in Studio Settings',
      };
    }
    final reject = rejectIfOutsideWorkspace(raw, workspace);
    if (reject != null) return reject;
    try {
      return await op(p.normalize(p.absolute(raw)), workspace);
    } catch (e) {
      return <String, Object?>{'ok': false, 'error': '$e'};
    }
  }

  mk.KernelToolResult okResult(Map<String, Object?> result) {
    return mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(text: jsonEncode(result)),
      ],
      isError: result['ok'] != true,
    );
  }

  boot.addTool(
    name: 'studio.fs.read',
    description:
        'Read a UTF-8 text file under the studio\'s workspaceDir. '
        'Returns `{ok, content}` or `{ok: false, error}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path under workspaceDir.',
        },
      },
      'required': <String>['path'],
    },
    handler: (args) async {
      final r = await guard(args, (abs, ws) async {
        final f = File(abs);
        if (!await f.exists()) {
          return <String, Object?>{
            'ok': false,
            'error': 'file does not exist: $abs',
          };
        }
        return <String, Object?>{
          'ok': true,
          'path': abs,
          'content': await f.readAsString(),
        };
      });
      return okResult(r);
    },
  );

  boot.addTool(
    name: 'studio.fs.write',
    description:
        'Write a UTF-8 text file under the studio\'s workspaceDir. '
        'Creates parent directories as needed. Returns `{ok, bytes}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{'type': 'string'},
        'content': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['path', 'content'],
    },
    handler: (args) async {
      final r = await guard(args, (abs, ws) async {
        final content = args['content'];
        if (content is! String) {
          return <String, Object?>{
            'ok': false,
            'error': 'content must be a string',
          };
        }
        final f = File(abs);
        await f.parent.create(recursive: true);
        await f.writeAsString(content);
        return <String, Object?>{
          'ok': true,
          'path': abs,
          'bytes': utf8.encode(content).length,
        };
      });
      return okResult(r);
    },
  );

  boot.addTool(
    name: 'studio.fs.mkdir',
    description:
        'Create a directory (recursive) under workspaceDir. Idempotent. '
        'Returns `{ok, created}` — `created` is true when the directory '
        'was newly created, false when it already existed.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['path'],
    },
    handler: (args) async {
      final r = await guard(args, (abs, ws) async {
        final dir = Directory(abs);
        final existed = await dir.exists();
        if (!existed) await dir.create(recursive: true);
        return <String, Object?>{'ok': true, 'path': abs, 'created': !existed};
      });
      return okResult(r);
    },
  );

  boot.addTool(
    name: 'studio.fs.list',
    description:
        'List immediate entries under a directory in workspaceDir. '
        'Returns `{ok, entries: [{name, type, size?}]}` where type is '
        '`file` or `directory`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['path'],
    },
    handler: (args) async {
      final r = await guard(args, (abs, ws) async {
        final dir = Directory(abs);
        if (!await dir.exists()) {
          return <String, Object?>{
            'ok': false,
            'error': 'directory does not exist: $abs',
          };
        }
        final entries = <Map<String, Object?>>[];
        await for (final ent in dir.list(followLinks: false)) {
          if (ent is File) {
            final stat = await ent.stat();
            entries.add(<String, Object?>{
              'name': p.basename(ent.path),
              'type': 'file',
              'size': stat.size,
            });
          } else if (ent is Directory) {
            entries.add(<String, Object?>{
              'name': p.basename(ent.path),
              'type': 'directory',
            });
          }
        }
        entries.sort(
          (a, b) => (a['name'] as String).compareTo(b['name'] as String),
        );
        return <String, Object?>{'ok': true, 'path': abs, 'entries': entries};
      });
      return okResult(r);
    },
  );

  boot.addTool(
    name: 'studio.fs.delete',
    description:
        'Delete a file or directory under workspaceDir. `recursive` is '
        'required when targeting a non-empty directory. Returns `{ok, '
        'deleted}` — `deleted` is false when the path didn\'t exist.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'path': <String, dynamic>{'type': 'string'},
        'recursive': <String, dynamic>{
          'type': 'boolean',
          'description': 'Allow non-empty directory deletion. Default false.',
        },
      },
      'required': <String>['path'],
    },
    handler: (args) async {
      final r = await guard(args, (abs, ws) async {
        final recursive = args['recursive'] == true;
        final type = await FileSystemEntity.type(abs);
        if (type == FileSystemEntityType.notFound) {
          return <String, Object?>{'ok': true, 'path': abs, 'deleted': false};
        }
        if (type == FileSystemEntityType.directory) {
          await Directory(abs).delete(recursive: recursive);
        } else {
          await File(abs).delete();
        }
        return <String, Object?>{'ok': true, 'path': abs, 'deleted': true};
      });
      return okResult(r);
    },
  );

  // ── studio.fs.glob ──────────────────────────────────────────────
  // Recursively walk `path` (defaults to workspaceDir) collecting
  // files whose relative path matches `pattern` (glob with `*`/`**`).
  // Returns `{ok, count, matches:[absPath, ...]}`. Capped at
  // `limit` (default 500) so a wild pattern can't flood the
  // response. `**` matches any number of path segments; `*`
  // matches a single segment. Use to find every `manifest.json`
  // under a workspace, every `*.dart`, etc., without shelling out
  // to `find`.
  boot.addTool(
    name: 'studio.fs.glob',
    description:
        'Recursively walk a directory under workspaceDir collecting '
        'files whose relative path matches `pattern` (e.g. '
        '`**/manifest.json`, `**/*.dart`, `ui/**/*.json`). Returns '
        '`{ok, count, matches}` (absolute paths). Capped at `limit` '
        '(default 500). `path` defaults to workspaceDir root.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'pattern': <String, dynamic>{'type': 'string'},
        'path': <String, dynamic>{
          'type': 'string',
          'description': 'Directory to walk. Defaults to workspaceDir root.',
        },
        'limit': <String, dynamic>{'type': 'integer', 'default': 500},
      },
      'required': <String>['pattern'],
    },
    handler: (args) async {
      final pattern = (args['pattern'] as String?)?.trim() ?? '';
      if (pattern.isEmpty) {
        return okResult(<String, Object?>{
          'ok': false,
          'error': 'pattern required',
        });
      }
      final limit = (args['limit'] as num?)?.toInt() ?? 500;
      final pathArg = (args['path'] as String?)?.trim();
      String? root;
      if (pathArg != null && pathArg.isNotEmpty) {
        final probe = await guard(<String, dynamic>{'path': pathArg}, (
          abs,
          ws,
        ) async {
          return <String, Object?>{'ok': true, 'abs': abs};
        });
        if (probe['ok'] != true) return okResult(probe);
        root = probe['abs'] as String;
      } else {
        final ws = await resolveWorkspace();
        if (ws == null || ws.isEmpty) {
          return okResult(<String, Object?>{
            'ok': false,
            'error': 'workspaceDir not configured — set it in Studio Settings',
          });
        }
        root = ws;
      }
      final regex = _globToRegex(pattern);
      final matches = <String>[];
      final dir = Directory(root);
      if (!await dir.exists()) {
        return okResult(<String, Object?>{
          'ok': true,
          'count': 0,
          'matches': <String>[],
        });
      }
      try {
        await for (final entry in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entry is! File) continue;
          final rel = p.relative(entry.path, from: root);
          if (regex.hasMatch(rel)) {
            matches.add(entry.path);
            if (matches.length >= limit) break;
          }
        }
      } catch (_) {
        // Tolerate partial walks (permission errors etc.) — return what we have.
      }
      return okResult(<String, Object?>{
        'ok': true,
        'count': matches.length,
        'matches': matches,
        'truncated': matches.length >= limit,
      });
    },
  );
}

/// Translate a glob pattern into a regex. `**` matches across path
/// separators, `*` matches a single segment, `?` matches one char.
/// Other regex meta chars are escaped.
RegExp _globToRegex(String pattern) {
  final buf = StringBuffer('^');
  var i = 0;
  while (i < pattern.length) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        buf.write('.*');
        i += 2;
        continue;
      }
      buf.write('[^/]*');
    } else if (c == '?') {
      buf.write('[^/]');
    } else if (RegExp(r'[.+^${}()|[\]\\]').hasMatch(c)) {
      buf.write('\\');
      buf.write(c);
    } else {
      buf.write(c);
    }
    i++;
  }
  buf.write(r'$');
  return RegExp(buf.toString());
}
