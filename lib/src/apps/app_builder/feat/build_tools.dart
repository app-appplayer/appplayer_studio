import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mcp_bundle/mcp_bundle.dart'
    hide ValidationIssue, ValidationSeverity;
import 'package:path/path.dart' as p;

import '../conv/llm_server_guide.dart';
import '../core/patch_pipeline.dart';
import '../core/spec_validator.dart';
import '../core/types.dart';
import '../core/vibe_project.dart';
import '../core/workspace_canonical.dart';
import '../infra/vibe_history_log.dart';
import '../infra/workspace_fs_port.dart';
import 'widget_schema_catalog.dart';

/// Outcome of a build-tool call. Mirrors `FileToolResult`'s shape so the
/// LLM tool dispatch can encode results uniformly.
class BuildToolResult {
  BuildToolResult._({
    required this.success,
    required this.message,
    this.path,
    this.payload,
  });

  factory BuildToolResult.success({
    required String message,
    String? path,
    String? payload,
  }) => BuildToolResult._(
    success: true,
    message: message,
    path: path,
    payload: payload,
  );

  factory BuildToolResult.failure(String message, {String? path}) =>
      BuildToolResult._(success: false, message: message, path: path);

  final bool success;
  final String message;
  final String? path;
  final String? payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ok': success,
    'message': message,
    if (path != null) 'path': path,
    if (payload != null) 'payload': payload,
  };
}

/// Callback that runs the project's saved build preset (or accepts
/// per-call overrides). Mirrors the GUI Build button + the MCP
/// `vibe_build_run` tool — auto-saves the canonical first, then
/// dispatches to mcpb pack or Dart codegen depending on `target`.
/// Returns a JSON-shaped map (target, channel, outDir, writtenFiles).
typedef RunBuildCallback =
    Future<Map<String, dynamic>> Function({
      String? target,
      String? channel,
      String? outDir,
    });

/// Callback that captures the live preview surface as PNG bytes.
/// Mirrors the MCP `vibe_preview_capture` tool. Returns null when
/// no preview is mounted (welcome state etc).
typedef CapturePreviewCallback =
    Future<({Uint8List bytes, int width, int height})?> Function({
      double pixelRatio,
    });

/// Callback that walks the rendered widget tree and returns one
/// entry per metadata-tagged node — type, rect, font, decoration,
/// padding. Mirrors the MCP `vibe_layout_snapshot` tool.
typedef LayoutSnapshotCallback = Future<List<Map<String, dynamic>>?> Function();

/// Build-time tools the LLM may call during a chat turn — packing
/// bundles, running shell commands inside the project, and fetching
/// the canonical Dart MCP server pattern guide. Source-level edits go
/// through the file-tool dispatcher (`write_file` / `edit_file`).
class BuildToolsDispatcher {
  BuildToolsDispatcher({
    required this.project,
    this.canonical,
    this.pipeline,
    this.validator,
    this.onRunBuild,
    this.onCapturePreview,
    this.onLayoutSnapshot,
  });

  /// The active project. The dispatcher resolves channel paths and
  /// scopes shell `cwd` against `project.projectPath`.
  final VibeProject project;

  /// Canonical bundle JSON for read-side tools (`tree_outline`,
  /// `get_widget`). Null disables those tools — callers will get a
  /// `not wired` failure result.
  final WorkspaceCanonical? canonical;

  /// Patch pipeline for write-side tools (`set_property`, `add_child`,
  /// `move_widget`, `delete_widget`, `replace_subtree`). Each call
  /// constructs a single-op `CanonicalPatch` and dispatches it. Null
  /// disables those tools.
  final PatchPipeline? pipeline;

  /// Spec validator for `validate_bundle` (full bundle JSON-Schema
  /// check across manifest / app / theme / pages / templates).
  /// Null disables that tool only — other tools still work.
  final SpecValidator? validator;

  /// Optional callback that executes the project's saved build
  /// preset (target/channel/outDir) — same path as the GUI's Build
  /// button. When wired, the chat LLM sees `run_build` and
  /// `get_build_config` tools and can ship an artifact without the
  /// user clicking through the GUI dialog. Null = chat-side build
  /// not wired (the tools are still listed but throw on call).
  final RunBuildCallback? onRunBuild;

  /// Optional callback for `preview_capture` — returns PNG bytes of
  /// the live preview surface. Lets the chat LLM verify visual
  /// outcomes (vs only reading JSON) when the user reports rendering
  /// issues. Null disables the tool.
  final CapturePreviewCallback? onCapturePreview;

  /// Optional callback for `layout_snapshot` — returns rendered
  /// rect / style of every metadata-tagged widget. Cheaper than
  /// vision (no image bytes) and gives the LLM precise numbers to
  /// reason about (button sizes, computed colors, padding).
  final LayoutSnapshotCallback? onLayoutSnapshot;

  String get _projectRoot => project.projectPath;

  String? _resolveRel(String rel) {
    if (rel.isEmpty) return _projectRoot;
    final canonicalRoot = p.normalize(_projectRoot);
    final normalized =
        p.isAbsolute(rel)
            ? p.normalize(rel)
            : p.normalize(p.join(canonicalRoot, rel));
    if (!p.isWithin(canonicalRoot, normalized) && normalized != canonicalRoot) {
      return null;
    }
    return normalized;
  }

  /// Pack a channel's `.mbd/` directory into a single `.mcpb` archive.
  /// `outPath` is project-relative — typical value `build/mcpb/bundle.mcpb`.
  Future<BuildToolResult> packBundle({
    required String channel,
    required String outPath,
  }) async {
    final src = project.bundlePathFor(channel);
    if (src == null) {
      return BuildToolResult.failure(
        'channel "$channel" is not enabled or does not exist',
      );
    }
    final dest = _resolveRel(outPath);
    if (dest == null) {
      return BuildToolResult.failure(
        'outPath escapes the project root',
        path: outPath,
      );
    }
    try {
      await Directory(p.dirname(dest)).create(recursive: true);
      final bytes = await McpBundlePacker.packDirectory(src);
      await File(dest).writeAsBytes(bytes, flush: true);
      return BuildToolResult.success(
        message: 'packed $channel → $outPath (${bytes.length} bytes)',
        path: outPath,
      );
    } catch (e) {
      return BuildToolResult.failure('pack failed: $e', path: outPath);
    }
  }

  /// Run a shell command with `cwd` rooted at a project-relative path.
  /// `command` is the executable; `args` is the argv tail. Output and
  /// exit code are returned in the result payload so the LLM can parse
  /// them. The command itself is not whitelisted — be specific in the
  /// prompt.
  Future<BuildToolResult> runShell({
    required String command,
    required List<String> args,
    String cwd = '',
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final workDir = _resolveRel(cwd);
    if (workDir == null) {
      return BuildToolResult.failure('cwd escapes the project root', path: cwd);
    }
    if (!await Directory(workDir).exists()) {
      return BuildToolResult.failure('cwd does not exist: $cwd', path: cwd);
    }
    if (command.isEmpty || command.contains(RegExp(r'\s'))) {
      return BuildToolResult.failure(
        'command must be a single executable name without whitespace; '
        'pass arguments via the `args` array',
        path: cwd,
      );
    }
    // Resolve the executable up-front so a missing binary surfaces as a
    // clean failure result instead of an unhandled ProcessException —
    // an uncaught spawn error from the Flutter macOS host abruptly
    // tears down the entire app.
    final resolved = await _resolveExecutable(command);
    if (resolved == null) {
      return BuildToolResult.failure(
        'executable not found on PATH: $command',
        path: cwd,
      );
    }
    Process process;
    try {
      process = await Process.start(
        resolved,
        args,
        workingDirectory: workDir,
        runInShell: false,
      );
    } on ProcessException catch (e) {
      return BuildToolResult.failure('spawn failed: ${e.message}', path: cwd);
    } catch (e) {
      return BuildToolResult.failure('spawn failed: $e', path: cwd);
    }
    try {
      // Drain stdout / stderr to completion. A `listen + cancel after
      // exitCode` pattern races short-lived children whose output
      // hasn't been delivered to our isolate by the time the exit
      // code resolves (`pwd`, `true`, etc. lose their stdout). The
      // `.join()` futures only resolve when each stream closes — wait
      // for all three before assembling the payload.
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      final stdoutStr = await stdoutFuture;
      final stderrStr = await stderrFuture;
      final payload = jsonEncode(<String, dynamic>{
        'exitCode': exitCode,
        'stdout': _truncate(stdoutStr),
        'stderr': _truncate(stderrStr),
      });
      if (exitCode == 0) {
        return BuildToolResult.success(
          message: '$command ${args.join(' ')} (exit 0)',
          path: cwd,
          payload: payload,
        );
      }
      return BuildToolResult.failure(
        '$command ${args.join(' ')} exited $exitCode',
        path: cwd,
      ).._appendPayload(payload);
    } catch (e) {
      try {
        process.kill();
      } catch (_) {
        /* ignore */
      }
      return BuildToolResult.failure('shell io error: $e', path: cwd);
    }
  }

  /// Resolve [command] to an absolute executable path. Returns null
  /// when nothing on PATH (or the literal absolute path) can be exec'd.
  /// Looking up the path ourselves avoids passing a bare unresolved
  /// name to `Process.start`, where a posix_spawn failure on macOS can
  /// escape the Dart-level catch and abort the embedder.
  Future<String?> _resolveExecutable(String command) async {
    if (p.isAbsolute(command)) {
      final f = File(command);
      if (await f.exists()) return command;
      return null;
    }
    if (command.contains(p.separator)) {
      final candidate = p.normalize(p.join(_projectRoot, command));
      if (await File(candidate).exists()) return candidate;
      return null;
    }
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final dir in pathEnv.split(Platform.isWindows ? ';' : ':')) {
      if (dir.isEmpty) continue;
      final candidate = p.join(dir, command);
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  static String _truncate(String s, {int max = 8192}) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}\n...[truncated ${s.length - max} bytes]';
  }

  /// Return the MCP server Dart pattern guide so the LLM can ground
  /// its code generation. Bundled as a const string in `llm_server_guide.dart`.
  Future<BuildToolResult> readBuildGuide() async {
    return BuildToolResult.success(
      message: 'pattern guide (${mcpServerDartPattern.length} bytes)',
      payload: mcpServerDartPattern,
    );
  }

  /// Return a one-line summary of channels, paths, and active context
  /// the LLM needs before generating code. Cheap call — doesn't read
  /// the canonical JSON.
  Future<BuildToolResult> projectInfo() async {
    final channels = <String, dynamic>{};
    for (final entry in project.channels.entries) {
      channels[entry.key] = <String, dynamic>{
        'enabled': entry.value.enabled,
        'subdir': entry.value.subdir,
      };
    }
    return BuildToolResult.success(
      message: 'project info',
      payload: jsonEncode(<String, dynamic>{
        'name': project.name,
        'projectPath': project.projectPath,
        'activeChannel': project.activeChannel,
        'channels': channels,
      }),
    );
  }

  // ── Semantic bundle editing ───────────────────────────────────────
  // The LLM uses these instead of `read_file` / `write_file` for any
  // canonical-bundle target — widgets AND non-widget areas (theme,
  // app metadata, page lifecycle, templates, manifest). Path = RFC 6901
  // JSON Pointer (e.g. `/ui/pages/home/content/children/2` for a
  // widget, `/ui/theme/color/primary` for a theme token). The pipeline
  // validates each patch against the spec — the LLM cannot produce
  // structurally invalid JSON through this surface.

  /// Top-level overview of every section the canonical bundle contains.
  /// Cheap call (a few hundred bytes); the LLM uses this as the
  /// entry point when the user asks "what's in this bundle?" or
  /// "what pages exist?". Avoids reading the whole tree.
  Future<BuildToolResult> bundleOutline() async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final root = c.currentJson;
    final out = <String, dynamic>{};

    final manifest = root['manifest'];
    if (manifest is Map) {
      out['manifest'] = <String, dynamic>{
        if (manifest['name'] is String) 'name': manifest['name'],
        if (manifest['version'] is String) 'version': manifest['version'],
        if (manifest['description'] is String)
          'description': manifest['description'],
      };
      final assetsSection = manifest['assets'];
      if (assetsSection is Map) {
        final entries = assetsSection['assets'];
        if (entries is List && entries.isNotEmpty) {
          out['assets'] = entries
              .whereType<Map>()
              .map(
                (a) => <String, dynamic>{
                  if (a['id'] is String) 'id': a['id'],
                  if (a['type'] is String) 'type': a['type'],
                  if (a['contentRef'] is String) 'contentRef': a['contentRef'],
                  if (a['path'] is String) 'path': a['path'],
                },
              )
              .toList(growable: false);
        }
      }
    }

    final ui = root['ui'];
    if (ui is Map) {
      // App metadata — strip the heavy nested sections so the outline
      // stays small. Caller picks them up via get_section.
      final appOut = <String, dynamic>{};
      const heavy = <String>{'pages', 'templates', 'theme', 'dashboard'};
      for (final entry in ui.entries) {
        if (heavy.contains(entry.key)) continue;
        final v = entry.value;
        if (v is String || v is num || v is bool) appOut[entry.key] = v;
      }
      if (ui['routes'] is Map) {
        appOut['routeCount'] = (ui['routes'] as Map).length;
      } else if (ui['routes'] is List) {
        appOut['routeCount'] = (ui['routes'] as List).length;
      }
      if (appOut.isNotEmpty) out['app'] = appOut;

      if (ui['theme'] is Map) {
        final theme = ui['theme'] as Map;
        out['theme'] = <String, dynamic>{
          if (theme['mode'] is String) 'mode': theme['mode'],
          'sections': theme.keys.toList(growable: false),
        };
      }

      if (ui['pages'] is Map) {
        final pages = ui['pages'] as Map;
        out['pages'] = pages.entries
            .map((e) {
              final v = e.value;
              return <String, dynamic>{
                'id': e.key,
                'path': '/ui/pages/${e.key}',
                if (v is Map && v['title'] is String) 'title': v['title'],
                if (v is Map && v['type'] is String) 'type': v['type'],
              };
            })
            .toList(growable: false);
      }

      if (ui['templates'] is Map) {
        final templates = ui['templates'] as Map;
        out['templates'] = templates.keys
            .map((k) => <String, dynamic>{'id': k, 'path': '/ui/templates/$k'})
            .toList(growable: false);
      }

      if (ui['dashboard'] is Map) {
        out['dashboard'] = <String, dynamic>{'path': '/ui/dashboard'};
      }

      if (ui['navigation'] is Map) {
        final nav = ui['navigation'] as Map;
        final items = nav['items'];
        out['navigation'] = <String, dynamic>{
          'path': '/ui/navigation',
          if (nav['type'] is String) 'type': nav['type'],
          if (items is List) 'itemCount': items.length,
        };
      }
    }

    return BuildToolResult.success(
      message: 'bundle outline',
      payload: jsonEncode(out),
    );
  }

  /// Read an entire named section. Use for theme, app metadata, full
  /// page object, full template definition, manifest. For widget
  /// inspection prefer `tree_outline` + `get_widget` (smaller payload).
  Future<BuildToolResult> getSection({
    required String section,
    String? id,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    String? path;
    switch (section) {
      case 'manifest':
        path = '/manifest';
        break;
      case 'app':
        path = '/ui';
        break;
      case 'theme':
        path = '/ui/theme';
        break;
      case 'dashboard':
        path = '/ui/dashboard';
        break;
      case 'navigation':
        path = '/ui/navigation';
        break;
      case 'assets':
        path = '/manifest/assets';
        break;
      case 'pages':
        path = id == null ? '/ui/pages' : '/ui/pages/$id';
        break;
      case 'templates':
        path = id == null ? '/ui/templates' : '/ui/templates/$id';
        break;
      default:
        return BuildToolResult.failure(
          'unknown section: $section. Known: manifest, app, theme, '
          'dashboard, navigation, assets, pages, templates',
        );
    }
    final node = _resolvePath(c.currentJson, path);
    if (node == null) {
      return BuildToolResult.success(
        message: '$section is empty',
        payload: jsonEncode(<String, dynamic>{
          'section': section,
          'path': path,
          'value': null,
        }),
      );
    }
    // For 'app', strip the heavy nested sections — caller fetches
    // those separately. Keeps the payload focused on app metadata.
    dynamic value = node;
    if (section == 'app' && node is Map) {
      const heavy = <String>{'pages', 'templates', 'theme', 'dashboard'};
      final filtered = <String, dynamic>{};
      for (final entry in node.entries) {
        if (heavy.contains(entry.key)) continue;
        filtered[entry.key.toString()] = entry.value;
      }
      value = filtered;
    }
    return BuildToolResult.success(
      message: '$section section ($path)',
      payload: jsonEncode(<String, dynamic>{
        'section': section,
        'path': path,
        if (id != null) 'id': id,
        'value': value,
      }),
    );
  }

  /// Walk the canonical bundle (or [scope] subtree) and return one
  /// flat entry per widget: `{path, type, label, depth, hasChildren}`.
  /// Cheap replacement for `read_file` when the LLM only needs to
  /// locate widgets — typical home page is < 1KB of summary vs ~6KB
  /// of raw JSON.
  Future<BuildToolResult> treeOutline({String? scope}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final root = c.currentJson;
    final base = _normalizePath(scope) ?? '/ui';
    final node = _resolvePath(root, base);
    if (node == null) {
      return BuildToolResult.failure('scope not found: $base');
    }
    final out = <Map<String, dynamic>>[];
    _walkWidgets(node, base, 0, out, limit: 300);
    return BuildToolResult.success(
      message:
          'outline of $base — ${out.length} widget'
          '${out.length == 1 ? '' : 's'}',
      payload: jsonEncode(<String, dynamic>{'scope': base, 'widgets': out}),
    );
  }

  /// Read one widget subtree by JSON Pointer path. Returns the widget
  /// + its direct properties + its children meta (path/type only, not
  /// the full child subtrees) so the LLM can drill down without
  /// re-fetching the whole tree.
  Future<BuildToolResult> getWidget({required String path}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final norm = _normalizePath(path);
    if (norm == null) return BuildToolResult.failure('invalid path: $path');
    final node = _resolvePath(c.currentJson, norm);
    if (node == null) return BuildToolResult.failure('not found: $norm');
    if (node is! Map) {
      return BuildToolResult.failure(
        'not a widget at $norm: ${node.runtimeType}',
      );
    }
    return BuildToolResult.success(
      message: 'widget $norm (${node['type']})',
      payload: jsonEncode(<String, dynamic>{'path': norm, 'widget': node}),
    );
  }

  /// Set one property on any node — widget, theme token, app
  /// metadata, page-as-map entry, template, manifest field. `key` is
  /// dot-pathed inside [path] (e.g. `style.color`, `text`,
  /// `color.primary`). Uses RFC 6902 `add` semantics so it acts as
  /// an upsert for object members (creates new keys, replaces
  /// existing). For array slot replacement use `replace_subtree`.
  Future<BuildToolResult> setProperty({
    required String path,
    required String key,
    required dynamic value,
    bool force = false,
  }) async {
    final norm = _normalizePath(path);
    if (norm == null) return BuildToolResult.failure('invalid path: $path');
    final keyTrimmed = key.trim();
    final fullPath =
        keyTrimmed.isEmpty ? norm : '$norm/${_keyToPointer(keyTrimmed)}';
    // Pre-flight existence check on the base path. Without this guard,
    // setProperty on a non-existent path (e.g. `/ui/pages/ghost/children/99`)
    // silently succeeds via RFC 6902 `add`, since `add` creates missing
    // intermediates. LLM callers cannot tell apart a real edit from a
    // typo. Refuse the write when the parent widget does not exist;
    // legitimate creations should go through add_child / replace_subtree.
    final c = canonical;
    if (c != null) {
      final base = _resolvePath(c.currentJson, norm);
      if (base == null) {
        return BuildToolResult.failure(
          'path does not exist: $norm. '
          'Use vibe_build_tree_outline to inspect the current tree, '
          'or vibe_build_add_child to create a new widget.',
          path: norm,
        );
      }
    }
    // Destructive-write guard: refuse to land a write that wipes a
    // non-trivial widget subtree. The `force` parameter is reserved
    // for the human shell (Inspector override checkbox) — we deny it
    // for any caller through the MCP layer because an LLM that sees
    // a guarded error will read the `force:true` hint and bypass
    // mechanically (observed in the calc_dash round). Keep the LLM
    // path strict: rebuild incrementally with add_child /
    // replace_subtree, no escape.
    if (!force) {
      final destructive = _destructiveCheck(fullPath, value);
      if (destructive != null) {
        return BuildToolResult.failure(
          'destructive write blocked — $destructive. '
          'Rebuild incrementally — use replace_subtree(path, '
          'widget) for a whole-subtree swap (single Map widget '
          'argument), or delete_widget then add_child for an '
          'edit-in-place. Both run through this guard so a '
          'large overwrite stays explicit.',
          path: fullPath,
        );
      }
    }
    return _applySingleOp(
      op: 'add',
      path: fullPath,
      value: value,
      summary: keyTrimmed.isEmpty ? 'set $norm' : 'set $key on $norm',
    );
  }

  /// Pre-flight guard for a write at [pointer] with [proposedValue].
  /// Returns a human-readable reason when the write would clear a
  /// non-trivial widget subtree, else null. Heuristic — counts the
  /// number of widget descendants currently at the target and warns
  /// when the new value would drop more than [_kDestructiveThreshold]
  /// widgets in one call. The check is intentionally cheap (single
  /// walk per call) and triggers only on whole-subtree replaces; key
  /// edits on small leaves pass through unchanged.
  static const int _kDestructiveThreshold = 10;
  String? _destructiveCheck(String pointer, dynamic proposedValue) {
    final c = canonical;
    if (c == null) return null;
    final current = _resolvePath(c.currentJson, pointer);
    if (current == null) return null;
    final beforeCount = _countWidgetDescendants(current);
    if (beforeCount < _kDestructiveThreshold) return null;
    final afterCount = _countWidgetDescendants(proposedValue);
    final lost = beforeCount - afterCount;
    if (lost < _kDestructiveThreshold) return null;
    return 'this write would remove $lost widget'
        '${lost == 1 ? '' : 's'} from $pointer '
        '(before: $beforeCount, after: $afterCount)';
  }

  /// Count widget-shaped Map nodes in a subtree (any Map with a
  /// String `type` field). Cheap pre-flight metric — no recursion
  /// limit needed because canonical trees stay shallow per spec.
  static int _countWidgetDescendants(dynamic node) {
    var count = 0;
    void walk(dynamic n) {
      if (n is Map) {
        if (n['type'] is String) count++;
        for (final v in n.values) {
          walk(v);
        }
      } else if (n is List) {
        for (final v in n) {
          walk(v);
        }
      }
    }

    walk(node);
    return count;
  }

  /// Convert a user-friendly dotted key into a JSON Pointer suffix.
  /// `.` separates nesting levels; literal `/` and `~` inside any
  /// segment get RFC 6901-escaped (`~1`, `~0`). Without this,
  /// keys like URL routes (`/about`) corrupt the pointer with
  /// double-slash segments.
  static String _keyToPointer(String key) => key
      .split('.')
      .map((s) => s.replaceAll('~', '~0').replaceAll('/', '~1'))
      .join('/');

  /// Append a child widget to a parent's `children` (or named slot).
  /// Default slot is `children`; pass `slot: 'child'` for single-child
  /// containers. `index` inserts at that position; null appends.
  Future<BuildToolResult> addChild({
    required String parentPath,
    required Map<String, dynamic> widget,
    String slot = 'children',
    int? index,
  }) async {
    final norm = _normalizePath(parentPath);
    if (norm == null) {
      return BuildToolResult.failure('invalid parentPath: $parentPath');
    }
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    // The parent MUST resolve to an existing container node. Without this
    // guard a wrong path (e.g. `/content` instead of the full
    // `/ui/pages/<id>/content`) silently "succeeds" — the patch pipeline
    // auto-vivifies a phantom orphan at the root and the widget never
    // appears in the page. Fail loudly with a hint instead.
    final parent = _resolvePath(c.currentJson, norm);
    if (parent is! Map) {
      return BuildToolResult.failure(
        'parentPath does not resolve to a node: "$parentPath". Pass the '
        'full canonical path, e.g. "/ui/pages/<pageId>/content" (see '
        'vibe_build_tree_outline for valid paths).',
      );
    }
    if (slot == 'children') {
      final list = parent[slot];
      final pos = index ?? (list is List ? list.length : 0);
      return _applySingleOp(
        op: 'add',
        path: '$norm/$slot/$pos',
        value: widget,
        summary: 'add child to $norm/$slot[$pos]',
      );
    }
    return _applySingleOp(
      op: 'add',
      path: '$norm/$slot',
      value: widget,
      summary: 'set $slot on $norm',
    );
  }

  /// Move a widget to a new parent slot. Implemented as remove + add
  /// in a single atomic patch so the pipeline validates the resulting
  /// state, not the intermediate one.
  Future<BuildToolResult> moveWidget({
    required String path,
    required String newParentPath,
    String slot = 'children',
    int? index,
  }) async {
    final c = canonical;
    final pl = pipeline;
    if (c == null || pl == null) {
      return BuildToolResult.failure('canonical/pipeline not wired');
    }
    final fromNorm = _normalizePath(path);
    final toNorm = _normalizePath(newParentPath);
    if (fromNorm == null || toNorm == null) {
      return BuildToolResult.failure('invalid path');
    }
    final node = _resolvePath(c.currentJson, fromNorm);
    if (node == null) {
      return BuildToolResult.failure('source not found: $fromNorm');
    }
    final parent = _resolvePath(c.currentJson, toNorm);
    final list = (parent is Map ? parent[slot] : null);
    final pos = index ?? (list is List ? list.length : 0);
    final ops = <PatchOp>[
      PatchOp(op: 'remove', path: fromNorm),
      PatchOp(
        op: 'add',
        path: slot == 'children' ? '$toNorm/$slot/$pos' : '$toNorm/$slot',
        value: node,
      ),
    ];
    return _dispatchOps(
      ops: ops,
      layer: _inferLayer(toNorm),
      summary:
          'move $fromNorm → $toNorm/$slot${slot == 'children' ? '[$pos]' : ''}',
    );
  }

  /// Delete a widget by path.
  Future<BuildToolResult> deleteWidget({required String path}) async {
    final norm = _normalizePath(path);
    if (norm == null) return BuildToolResult.failure('invalid path: $path');
    return _applySingleOp(
      op: 'remove',
      path: norm,
      value: null,
      summary: 'delete $norm',
    );
  }

  /// Search for widgets across the bundle by type, label substring,
  /// presence of a property, or value reference (binding / template
  /// id). Returns one entry per match — `{path, type, label?}`.
  /// Provide AT LEAST ONE filter; without filters this would just be
  /// tree_outline.
  Future<BuildToolResult> findWidgets({
    String? type,
    String? label,
    String? hasProp,
    String? refersTo,
    String? scope,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    if (type == null && label == null && hasProp == null && refersTo == null) {
      return BuildToolResult.failure(
        'provide at least one filter (type / label / hasProp / refersTo)',
      );
    }
    final base = _normalizePath(scope) ?? '/ui';
    final node = _resolvePath(c.currentJson, base);
    if (node == null) {
      return BuildToolResult.failure('scope not found: $base');
    }
    final out = <Map<String, dynamic>>[];
    final labelLc = label?.toLowerCase();
    _walkAll(node, base, (n, path) {
      if (n is! Map) return;
      final actualType = n['type'];
      if (actualType is! String) return;
      if (type != null && actualType != type) return;
      if (hasProp != null && !n.containsKey(hasProp)) return;
      if (labelLc != null) {
        final l = _label(n);
        if (l == null || !l.toLowerCase().contains(labelLc)) return;
      }
      if (refersTo != null) {
        // Scan strings inside this widget's OWN properties — stop
        // descending the moment we re-enter another widget (which
        // gets its own match if it qualifies). Without this guard
        // every ancestor of a matching widget also matches, which
        // overwhelms the result and obscures the actual reference.
        if (!_refersInOwnProps(n, refersTo)) return;
      }
      final entry = <String, dynamic>{'path': path, 'type': actualType};
      final lbl = _label(n);
      if (lbl != null) entry['label'] = lbl;
      out.add(entry);
      if (out.length >= 200) return; // hard cap
    });
    return BuildToolResult.success(
      message: 'found ${out.length} match${out.length == 1 ? '' : 'es'}',
      payload: jsonEncode(<String, dynamic>{
        'scope': base,
        'filters': <String, dynamic>{
          if (type != null) 'type': type,
          if (label != null) 'label': label,
          if (hasProp != null) 'hasProp': hasProp,
          if (refersTo != null) 'refersTo': refersTo,
        },
        'matches': out,
      }),
    );
  }

  /// Bundle-wide wiring health check. Returns issues across these
  /// categories:
  ///   - orphan_page          page declared but no route points to it
  ///   - missing_route_target route value is not a declared page id
  ///   - missing_initial_route initialRoute is not a route key
  ///   - undefined_template   `use` references unknown template id
  ///   - unused_template      template declared but no `use` of it
  ///   - undefined_state      widget binds to state.X but state.X
  ///                          is not declared on the page
  /// Run this before save/build to catch authoring drift the spec
  /// validator alone cannot detect.
  Future<BuildToolResult> checkWiring() async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final root = c.currentJson;
    final ui = root['ui'];
    if (ui is! Map) {
      return BuildToolResult.success(
        message: 'no /ui section',
        payload: jsonEncode(<String, dynamic>{'issues': const <Object?>[]}),
      );
    }

    final issues = <Map<String, dynamic>>[];
    final pages = ui['pages'];
    final routes = ui['routes'];
    final initialRoute = ui['initialRoute'];
    final templates = ui['templates'];

    final pageIds =
        pages is Map ? pages.keys.map((e) => e.toString()).toSet() : <String>{};

    if (routes is Map) {
      final routedPages = <String>{};
      // Resolve a routes-map value to the page id it points at.
      // Per app.schema.json §RouteValue, route values can be:
      //   1. raw page id ("home")
      //   2. `ui://pages/<id>` URI form (canonical for cross-bundle
      //      page references)
      //   3. transition wrapper `{page, transition}` (recurse on page)
      // The wiring checker compares against `pages` map keys (raw
      // ids), so any `ui://pages/<id>` value must be unwrapped first.
      String? resolvePageRef(dynamic v) {
        if (v is String) {
          if (v.startsWith('ui://pages/')) {
            return v.substring('ui://pages/'.length);
          }
          return v;
        }
        if (v is Map) {
          final inner = v['page'];
          if (inner != null) return resolvePageRef(inner);
        }
        return null;
      }

      for (final entry in routes.entries) {
        final routeKey = entry.key.toString();
        final target = entry.value;
        final pageId = resolvePageRef(target);
        if (pageId != null) {
          routedPages.add(pageId);
          if (!pageIds.contains(pageId)) {
            issues.add(<String, dynamic>{
              'kind': 'missing_route_target',
              'route': routeKey,
              'target': target,
              'pageId': pageId,
              'message':
                  'route "$routeKey" → "$target" but no page "$pageId" exists',
            });
          }
        }
      }
      for (final id in pageIds) {
        if (!routedPages.contains(id)) {
          issues.add(<String, dynamic>{
            'kind': 'orphan_page',
            'page': id,
            'message': 'page "$id" is not wired to any route — unreachable',
          });
        }
      }
      if (initialRoute is String &&
          initialRoute.isNotEmpty &&
          !routes.containsKey(initialRoute)) {
        issues.add(<String, dynamic>{
          'kind': 'missing_initial_route',
          'initialRoute': initialRoute,
          'message': 'initialRoute "$initialRoute" is not a key in /ui/routes',
        });
      }
    } else if (pageIds.isNotEmpty) {
      issues.add(<String, dynamic>{
        'kind': 'no_routes',
        'message': 'pages exist but /ui/routes is missing or not a map',
      });
    }

    if (templates is Map) {
      final declared = templates.keys.map((e) => e.toString()).toSet();
      final referenced = <String>{};
      _walkAll(ui, '/ui', (n, path) {
        if (n is Map && n['type'] == 'use') {
          final tpl = n['template'];
          if (tpl is String) {
            referenced.add(tpl);
            if (!declared.contains(tpl)) {
              issues.add(<String, dynamic>{
                'kind': 'undefined_template',
                'path': path,
                'template': tpl,
                'message':
                    'use at $path references template "$tpl" which is not declared',
              });
            }
          }
        }
      });
      for (final id in declared) {
        if (!referenced.contains(id)) {
          issues.add(<String, dynamic>{
            'kind': 'unused_template',
            'template': id,
            'message':
                'template "$id" is declared but never referenced via `use`',
          });
        }
      }
    }

    if (pages is Map) {
      for (final entry in pages.entries) {
        final pageId = entry.key.toString();
        final page = entry.value;
        if (page is! Map) continue;
        final state = page['state'];
        final declared = <String>{};
        if (state is Map) {
          for (final k in state.keys) {
            declared.add(k.toString());
          }
        }
        final referenced = <String>{};
        void scanString(String s) {
          final at = RegExp(r'@\{\s*state\.([\w.]+)\s*\}');
          for (final m in at.allMatches(s)) {
            referenced.add(m.group(1)!.split('.').first);
          }
          final mu = RegExp(r'\{\{\s*state\.([\w.]+)\s*\}\}');
          for (final m in mu.allMatches(s)) {
            referenced.add(m.group(1)!.split('.').first);
          }
        }

        _walkAll(page, '/ui/pages/$pageId', (n, _) {
          if (n is String) scanString(n);
          if (n is Map && n['type'] == 'state') {
            final binding = n['binding'];
            if (binding is String) {
              referenced.add(binding.split('.').first);
            }
          }
        });
        for (final ref in referenced) {
          if (ref.isEmpty) continue;
          if (!declared.contains(ref)) {
            issues.add(<String, dynamic>{
              'kind': 'undefined_state',
              'page': pageId,
              'key': ref,
              'message':
                  'page "$pageId" binds state.$ref but key "$ref" is not '
                  'declared in /ui/pages/$pageId/state',
            });
          }
        }
      }
    }

    return BuildToolResult.success(
      message: '${issues.length} issue${issues.length == 1 ? '' : 's'}',
      payload: jsonEncode(<String, dynamic>{'issues': issues}),
    );
  }

  /// Atomically rename a page. Updates the pages map key AND every
  /// /ui/routes entry that pointed to the old id. Without this, rename
  /// requires multiple set_property/delete_widget calls, and a missed
  /// route silently breaks navigation.
  Future<BuildToolResult> renamePage({
    required String oldId,
    required String newId,
  }) async {
    final c = canonical;
    if (c == null || pipeline == null) {
      return BuildToolResult.failure('canonical/pipeline not wired');
    }
    final oldT = oldId.trim();
    final newT = newId.trim();
    if (oldT.isEmpty || newT.isEmpty) {
      return BuildToolResult.failure('oldId / newId must be non-empty');
    }
    if (oldT == newT) {
      return BuildToolResult.failure('oldId equals newId — nothing to do');
    }
    final root = c.currentJson;
    final ui = root['ui'];
    final pages = ui is Map ? ui['pages'] : null;
    if (pages is! Map) {
      return BuildToolResult.failure('/ui/pages is not a map');
    }
    if (!pages.containsKey(oldT)) {
      return BuildToolResult.failure('page "$oldT" not found');
    }
    if (pages.containsKey(newT)) {
      return BuildToolResult.failure('page "$newT" already exists');
    }

    final pageObj = pages[oldT];
    final ops = <PatchOp>[
      PatchOp(
        op: 'add',
        path: '/ui/pages/${_keyToPointer(newT)}',
        value: pageObj,
      ),
      PatchOp(op: 'remove', path: '/ui/pages/${_keyToPointer(oldT)}'),
    ];

    final routes = ui['routes'];
    final routeUpdates = <String>[];
    if (routes is Map) {
      for (final entry in routes.entries) {
        if (entry.value == oldT) {
          final k = entry.key.toString();
          ops.add(
            PatchOp(
              op: 'replace',
              path: '/ui/routes/${_keyToPointer(k)}',
              value: newT,
            ),
          );
          routeUpdates.add(k);
        }
      }
    }

    final result = await _dispatchOps(
      ops: ops,
      layer: LayerId.appStructure,
      summary:
          'rename page "$oldT" → "$newT"'
          '${routeUpdates.isEmpty ? '' : ' (+ ${routeUpdates.length} route${routeUpdates.length == 1 ? '' : 's'})'}',
    );
    return result;
  }

  /// Rename a template id and propagate the change to every `use`
  /// widget that names it. Atomic — fails when the new id collides
  /// with an existing template, when the source isn't found, or
  /// when ops fail spec validation. Returns the count of `use`
  /// widgets rewritten alongside the move.
  Future<BuildToolResult> renameTemplate({
    required String oldId,
    required String newId,
  }) async {
    final c = canonical;
    if (c == null || pipeline == null) {
      return BuildToolResult.failure('canonical/pipeline not wired');
    }
    final oldT = oldId.trim();
    final newT = newId.trim();
    if (oldT.isEmpty || newT.isEmpty) {
      return BuildToolResult.failure('oldId / newId must be non-empty');
    }
    if (oldT == newT) {
      return BuildToolResult.failure('oldId equals newId — nothing to do');
    }
    final root = c.currentJson;
    final ui = root['ui'];
    final templates = ui is Map ? ui['templates'] : null;
    if (templates is! Map) {
      return BuildToolResult.failure('/ui/templates is not a map');
    }
    if (!templates.containsKey(oldT)) {
      return BuildToolResult.failure('template "$oldT" not found');
    }
    if (templates.containsKey(newT)) {
      return BuildToolResult.failure('template "$newT" already exists');
    }

    final templateObj = templates[oldT];
    final ops = <PatchOp>[
      PatchOp(
        op: 'add',
        path: '/ui/templates/${_keyToPointer(newT)}',
        value: templateObj,
      ),
      PatchOp(op: 'remove', path: '/ui/templates/${_keyToPointer(oldT)}'),
    ];
    // Walk every `use` widget — rewrite `template: oldT` → `template: newT`.
    // Use-widgets reference their template via the `template` field (see how
    // they are created: `{type:'use', template:<id>}` and read everywhere via
    // `node['template']`). The previous code matched/rewrote `name`, so a
    // rename removed the old template (above) while leaving every use-widget
    // pointing at the now-deleted id — dangling references.
    var useCount = 0;
    void walk(dynamic node, String pointer) {
      if (node is Map) {
        if (node['type'] == 'use' && node['template'] == oldT) {
          ops.add(
            PatchOp(op: 'replace', path: '$pointer/template', value: newT),
          );
          useCount++;
        }
        for (final entry in node.entries) {
          final key = '${entry.key}';
          final escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
          walk(entry.value, '$pointer/$escaped');
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$pointer/$i');
        }
      }
    }

    walk(ui, '/ui');
    return _dispatchOps(
      ops: ops,
      layer: LayerId.components,
      summary:
          'rename template "$oldT" → "$newT"'
          '${useCount == 0 ? '' : ' (+ $useCount use ref${useCount == 1 ? '' : 's'})'}',
    );
  }

  /// Rename a reactive state key and propagate the change to every
  /// `{{state.<oldKey>}}` binding string in the canonical. Scope ∈
  ///   - `app`        — `/ui/state/<oldKey>` (app-wide)
  ///   - `page:<id>`  — `/ui/pages/<id>/state/<oldKey>`
  /// Atomic. Bindings inside templates / dashboard / navigation are
  /// rewritten too — anywhere a string contains `{{state.<oldKey>}}`
  /// (or `{{ state.<oldKey> }}` with whitespace).
  Future<BuildToolResult> renameStateKey({
    required String oldKey,
    required String newKey,
    String scope = 'app',
  }) async {
    final c = canonical;
    if (c == null || pipeline == null) {
      return BuildToolResult.failure('canonical/pipeline not wired');
    }
    final oldK = oldKey.trim();
    final newK = newKey.trim();
    if (oldK.isEmpty || newK.isEmpty) {
      return BuildToolResult.failure('oldKey / newKey must be non-empty');
    }
    if (oldK == newK) {
      return BuildToolResult.failure('oldKey equals newKey');
    }
    String stateBasePath;
    if (scope == 'app') {
      stateBasePath = '/ui/state';
    } else if (scope.startsWith('page:')) {
      final id = scope.substring('page:'.length);
      stateBasePath = '/ui/pages/${_keyToPointer(id)}/state';
    } else {
      return BuildToolResult.failure('scope must be `app` or `page:<id>`');
    }
    final state = _resolvePath(c.currentJson, stateBasePath);
    if (state is! Map) {
      return BuildToolResult.failure('no state map at $stateBasePath');
    }
    if (!state.containsKey(oldK)) {
      return BuildToolResult.failure(
        'state key "$oldK" not found at $stateBasePath',
      );
    }
    if (state.containsKey(newK)) {
      return BuildToolResult.failure(
        'state key "$newK" already exists at $stateBasePath',
      );
    }
    final value = state[oldK];
    final ops = <PatchOp>[
      PatchOp(
        op: 'add',
        path: '$stateBasePath/${_keyToPointer(newK)}',
        value: value,
      ),
      PatchOp(op: 'remove', path: '$stateBasePath/${_keyToPointer(oldK)}'),
    ];
    // Walk every string leaf — replace {{state.oldK}} with
    // {{state.newK}}. Tolerate whitespace inside the braces.
    final pattern = RegExp(
      r'\{\{(\s*)state\.' + RegExp.escape(oldK) + r'(\s*[\w.\[\]]*\s*)\}\}',
    );
    var bindingCount = 0;
    void walk(dynamic node, String pointer) {
      if (node is String) {
        if (pattern.hasMatch(node)) {
          final next = node.replaceAllMapped(
            pattern,
            (m) => '{{${m.group(1)}state.$newK${m.group(2)}}}',
          );
          ops.add(PatchOp(op: 'replace', path: pointer, value: next));
          bindingCount++;
        }
        return;
      }
      if (node is Map) {
        for (final entry in node.entries) {
          final key = '${entry.key}';
          final escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
          walk(entry.value, '$pointer/$escaped');
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$pointer/$i');
        }
      }
    }

    walk(c.currentJson['ui'], '/ui');
    final layer = scope == 'app' ? LayerId.appStructure : LayerId.pages;
    return _dispatchOps(
      ops: ops,
      layer: layer,
      summary:
          'rename state "$oldK" → "$newK"'
          '${bindingCount == 0 ? '' : ' (+ $bindingCount binding${bindingCount == 1 ? '' : 's'})'}',
    );
  }

  /// Apply a Material 3 theme preset built from [seedColor]. Sets
  /// `color.seed` (runtime derives the full color scheme), the full
  /// 15-role typography scale, M3 spacing tokens, and shape defaults.
  /// `mode` is one of `light`, `dark`, `system` (default `system`).
  /// Use this to bootstrap a theme — incremental tweaks afterwards
  /// go through `set_property(/ui/theme/...)`.
  Future<BuildToolResult> applyThemePreset({
    required String seedColor,
    String mode = 'system',
  }) async {
    if (!RegExp(r'^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$').hasMatch(seedColor)) {
      return BuildToolResult.failure(
        'seedColor must be #RRGGBB or #RRGGBBAA — got "$seedColor"',
      );
    }
    if (!const <String>{'light', 'dark', 'system'}.contains(mode)) {
      return BuildToolResult.failure(
        'mode must be one of light / dark / system',
      );
    }
    final theme = <String, dynamic>{
      'mode': mode,
      'color': <String, dynamic>{'seed': seedColor},
      'typography': const <String, dynamic>{
        'displayLarge': <String, dynamic>{
          'fontSize': 57,
          'lineHeight': 64,
          'letterSpacing': -0.25,
          'fontWeight': 400,
        },
        'displayMedium': <String, dynamic>{
          'fontSize': 45,
          'lineHeight': 52,
          'fontWeight': 400,
        },
        'displaySmall': <String, dynamic>{
          'fontSize': 36,
          'lineHeight': 44,
          'fontWeight': 400,
        },
        'headlineLarge': <String, dynamic>{
          'fontSize': 32,
          'lineHeight': 40,
          'fontWeight': 400,
        },
        'headlineMedium': <String, dynamic>{
          'fontSize': 28,
          'lineHeight': 36,
          'fontWeight': 400,
        },
        'headlineSmall': <String, dynamic>{
          'fontSize': 24,
          'lineHeight': 32,
          'fontWeight': 400,
        },
        'titleLarge': <String, dynamic>{
          'fontSize': 22,
          'lineHeight': 28,
          'fontWeight': 400,
        },
        'titleMedium': <String, dynamic>{
          'fontSize': 16,
          'lineHeight': 24,
          'letterSpacing': 0.15,
          'fontWeight': 500,
        },
        'titleSmall': <String, dynamic>{
          'fontSize': 14,
          'lineHeight': 20,
          'letterSpacing': 0.1,
          'fontWeight': 500,
        },
        'bodyLarge': <String, dynamic>{
          'fontSize': 16,
          'lineHeight': 24,
          'letterSpacing': 0.5,
          'fontWeight': 400,
        },
        'bodyMedium': <String, dynamic>{
          'fontSize': 14,
          'lineHeight': 20,
          'letterSpacing': 0.25,
          'fontWeight': 400,
        },
        'bodySmall': <String, dynamic>{
          'fontSize': 12,
          'lineHeight': 16,
          'letterSpacing': 0.4,
          'fontWeight': 400,
        },
        'labelLarge': <String, dynamic>{
          'fontSize': 14,
          'lineHeight': 20,
          'letterSpacing': 0.1,
          'fontWeight': 500,
        },
        'labelMedium': <String, dynamic>{
          'fontSize': 12,
          'lineHeight': 16,
          'letterSpacing': 0.5,
          'fontWeight': 500,
        },
        'labelSmall': <String, dynamic>{
          'fontSize': 11,
          'lineHeight': 16,
          'letterSpacing': 0.5,
          'fontWeight': 500,
        },
      },
      'spacing': const <String, dynamic>{
        'xxs': 2,
        'xs': 4,
        'sm': 8,
        'md': 16,
        'lg': 24,
        'xl': 32,
        '2xl': 48,
        '3xl': 64,
        '4xl': 96,
        'screenPadding': 16,
        'cardPadding': 16,
        'sectionGap': 24,
        'inlineGap': 8,
      },
      'shape': const <String, dynamic>{
        'none': 0,
        'extraSmall': 4,
        'small': 8,
        'medium': 12,
        'large': 16,
        'extraLarge': 28,
        'full': 9999,
      },
    };
    return _applySingleOp(
      op: 'replace',
      path: '/ui/theme',
      value: theme,
      summary: 'apply theme preset (seed=$seedColor, mode=$mode)',
    );
  }

  /// Replace a page's content (and seed its state) with a verified
  /// layout skeleton. Kinds:
  ///   - `hero`     large title + subtitle + CTA button
  ///   - `cardList` scrollable column of placeholder cards
  ///   - `form`     title + 2 textfields + submit; state seeded with
  ///                `fields` and `errors`
  ///   - `settings` list of switch / value rows
  /// All output is mcp_ui DSL 1.3 spec-compliant — `linear` /
  /// `text` / `textfield` / `button` / `card`. After applying,
  /// further customise via set_property.
  Future<BuildToolResult> applyLayoutPreset({
    required String pageId,
    required String kind,
    bool dryRun = false,
  }) async {
    final c = canonical;
    if (c == null || pipeline == null) {
      return BuildToolResult.failure('canonical/pipeline not wired');
    }
    final id = pageId.trim();
    if (id.isEmpty) return BuildToolResult.failure('pageId required');
    final pages = (c.currentJson['ui'] as Map?)?['pages'];
    if (pages is! Map || !pages.containsKey(id)) {
      return BuildToolResult.failure(
        'page "$id" not found — '
        'create it first with set_property(/ui/pages, "$id", {...})',
      );
    }
    Map<String, dynamic>? content;
    Map<String, dynamic>? state;
    switch (kind) {
      case 'hero':
        content = <String, dynamic>{
          'type': 'linear',
          'direction': 'vertical',
          'gap': 16,
          'padding': 48,
          'children': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'variant': 'displaySmall',
              'text': 'Welcome',
            },
            <String, dynamic>{
              'type': 'text',
              'variant': 'bodyLarge',
              'text': 'Replace this subtitle.',
            },
            <String, dynamic>{
              'type': 'button',
              'variant': 'filled',
              'label': 'Get started',
            },
          ],
        };
        break;
      case 'cardList':
        content = <String, dynamic>{
          'type': 'linear',
          'direction': 'vertical',
          'gap': 12,
          'padding': 16,
          'children': List<Map<String, dynamic>>.generate(
            3,
            (i) => <String, dynamic>{
              'type': 'card',
              'child': <String, dynamic>{
                'type': 'linear',
                'direction': 'vertical',
                'gap': 4,
                'padding': 16,
                'children': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'text',
                    'variant': 'titleMedium',
                    'text': 'Card ${i + 1}',
                  },
                  <String, dynamic>{
                    'type': 'text',
                    'variant': 'bodyMedium',
                    'text': 'Description placeholder.',
                  },
                ],
              },
            },
          ),
        };
        break;
      case 'form':
        state = <String, dynamic>{
          'fields': <String, dynamic>{'name': '', 'email': ''},
          'errors': <String, dynamic>{},
        };
        content = <String, dynamic>{
          'type': 'linear',
          'direction': 'vertical',
          'gap': 12,
          'padding': 24,
          'children': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'variant': 'titleLarge',
              'text': 'Form',
            },
            <String, dynamic>{
              'type': 'textfield',
              'label': 'Name',
              'value': '@{state.fields.name}',
              'onChange': <String, dynamic>{
                'type': 'state',
                'action': 'set',
                'binding': 'fields.name',
              },
            },
            <String, dynamic>{
              'type': 'textfield',
              'label': 'Email',
              'value': '@{state.fields.email}',
              'onChange': <String, dynamic>{
                'type': 'state',
                'action': 'set',
                'binding': 'fields.email',
              },
            },
            <String, dynamic>{
              'type': 'button',
              'variant': 'filled',
              'label': 'Submit',
            },
          ],
        };
        break;
      case 'settings':
        content = <String, dynamic>{
          'type': 'linear',
          'direction': 'vertical',
          'gap': 8,
          'padding': 16,
          'children': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'variant': 'titleLarge',
              'text': 'Settings',
            },
            ...List<Map<String, dynamic>>.generate(
              3,
              (i) => <String, dynamic>{
                'type': 'linear',
                'direction': 'horizontal',
                'gap': 12,
                'padding': 12,
                'children': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'text',
                    'variant': 'bodyLarge',
                    'text': 'Option ${i + 1}',
                  },
                  <String, dynamic>{
                    'type': 'text',
                    'variant': 'bodyMedium',
                    'text': 'value',
                  },
                ],
              },
            ),
          ],
        };
        break;
      // 1.3.4 content-app presets — built on the new Phase 2-4 widgets.
      case 'gallery':
        content = <String, dynamic>{
          'type': 'staggeredGrid',
          'crossAxisCount': 2,
          'mainAxisSpacing': 8,
          'crossAxisSpacing': 8,
          'padding': 16,
          'children': <Map<String, dynamic>>[
            for (var i = 1; i <= 6; i++)
              <String, dynamic>{
                'type': 'card',
                'child': <String, dynamic>{
                  'type': 'linear',
                  'direction': 'vertical',
                  'children': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'type': 'image',
                      'src':
                          'https://picsum.photos/seed/$i/600/${400 + (i % 3) * 80}',
                      'fit': 'cover',
                      'semanticLabel': 'Photo $i',
                    },
                    <String, dynamic>{
                      'type': 'text',
                      'content': 'Item $i',
                      'style': <String, dynamic>{'fontWeight': '600'},
                    },
                  ],
                },
              },
          ],
        };
        break;
      case 'magazine':
        content = <String, dynamic>{
          'type': 'scrollView',
          'children': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'kenBurnsImage',
              'src': 'https://picsum.photos/seed/cover/1200/800',
              'duration': 8000,
              'semanticLabel': 'Cover image',
            },
            <String, dynamic>{
              'type': 'linear',
              'direction': 'vertical',
              'padding': 24,
              'gap': 12,
              'children': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'text',
                  'content': 'Headline goes here',
                  'style': <String, dynamic>{
                    'fontSize': 32,
                    'fontWeight': '700',
                    'height': 1.2,
                  },
                },
                <String, dynamic>{
                  'type': 'text',
                  'content': 'Subhead with a brief lede that sets the scene.',
                  'style': <String, dynamic>{
                    'fontSize': 18,
                    'color': '{{theme.color.onSurfaceVariant}}',
                  },
                },
                <String, dynamic>{
                  'type': 'text',
                  'content':
                      'Body text starts here with a drop cap. Replace this paragraph with the article body.',
                  'dropCap': <String, dynamic>{'lines': 3},
                  'style': <String, dynamic>{'fontSize': 16, 'height': 1.5},
                },
              ],
            },
          ],
        };
        break;
      case 'carousel':
        content = <String, dynamic>{
          'type': 'linear',
          'direction': 'vertical',
          'gap': 16,
          'padding': 16,
          'children': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'text',
              'content': 'Featured',
              'style': <String, dynamic>{'fontSize': 22, 'fontWeight': '700'},
            },
            <String, dynamic>{
              'type': 'carousel',
              'viewportFraction': 0.85,
              'loop': true,
              'autoPlay': true,
              'transition': 'slide',
              'indicatorPosition': 'bottom',
              'children': <Map<String, dynamic>>[
                for (var i = 1; i <= 3; i++)
                  <String, dynamic>{
                    'type': 'card',
                    'child': <String, dynamic>{
                      'type': 'image',
                      'src': 'https://picsum.photos/seed/feat$i/800/450',
                      'fit': 'cover',
                      'semanticLabel': 'Featured slide $i',
                    },
                  },
              ],
            },
          ],
        };
        break;
      case 'playlist':
        // List rows with album art + title + subtitle + duration.
        content = <String, dynamic>{
          'type': 'scrollView',
          'children': <Map<String, dynamic>>[
            for (var i = 1; i <= 8; i++)
              <String, dynamic>{
                'type': 'linear',
                'direction': 'horizontal',
                'gap': 12,
                'padding': 12,
                'children': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'type': 'image',
                    'src': 'https://picsum.photos/seed/album$i/56/56',
                    'width': 56,
                    'height': 56,
                    'semanticLabel': 'Album art',
                  },
                  <String, dynamic>{
                    'type': 'expanded',
                    'child': <String, dynamic>{
                      'type': 'linear',
                      'direction': 'vertical',
                      'gap': 4,
                      'children': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'type': 'text',
                          'content': 'Track $i',
                          'style': <String, dynamic>{'fontWeight': '600'},
                        },
                        <String, dynamic>{
                          'type': 'text',
                          'content': 'Artist · Album',
                          'style': <String, dynamic>{
                            'fontSize': 13,
                            'color': '{{theme.color.onSurfaceVariant}}',
                          },
                        },
                      ],
                    },
                  },
                  <String, dynamic>{
                    'type': 'text',
                    'content': '3:${20 + i}',
                    'style': <String, dynamic>{
                      'color': '{{theme.color.onSurfaceVariant}}',
                    },
                  },
                ],
              },
          ],
        };
        break;
      case 'landing':
        content = <String, dynamic>{
          'type': 'linear',
          'direction': 'vertical',
          'children': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'kenBurnsImage',
              'src': 'https://picsum.photos/seed/landing/1200/720',
              'duration': 12000,
              'semanticLabel': 'Hero',
            },
            <String, dynamic>{
              'type': 'linear',
              'direction': 'vertical',
              'padding': 32,
              'gap': 16,
              'children': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'animatedDefaultTextStyle',
                  'duration': 500,
                  'curve': 'emphasized',
                  'style': <String, dynamic>{
                    'fontSize': 36,
                    'fontWeight': '700',
                  },
                  'child': <String, dynamic>{
                    'type': 'text',
                    'content': 'Welcome',
                  },
                },
                <String, dynamic>{
                  'type': 'text',
                  'content': 'Subhead — replace with a value prop.',
                  'style': <String, dynamic>{
                    'fontSize': 18,
                    'color': '{{theme.color.onSurfaceVariant}}',
                  },
                },
                <String, dynamic>{
                  'type': 'button',
                  'label': 'Get started',
                  'variant': 'filled',
                },
              ],
            },
          ],
        };
        break;
      default:
        return BuildToolResult.failure(
          'unknown kind: $kind. Known: hero, cardList, form, '
          'settings, gallery, magazine, carousel, playlist, landing',
        );
    }
    final ops = <PatchOp>[
      PatchOp(
        op: 'replace',
        path: '/ui/pages/${_keyToPointer(id)}/content',
        value: content,
      ),
    ];
    if (state != null) {
      ops.add(
        PatchOp(
          op: 'add',
          path: '/ui/pages/${_keyToPointer(id)}/state',
          value: state,
        ),
      );
    }
    if (dryRun) {
      return BuildToolResult.success(
        message:
            'preview $kind preset for "$id" '
            '(${ops.length} op${ops.length == 1 ? '' : 's'})',
        payload: jsonEncode(<String, dynamic>{
          'kind': kind,
          'pageId': id,
          'content': content,
          'state': state,
          'opCount': ops.length,
        }),
      );
    }
    return _dispatchOps(
      ops: ops,
      layer: LayerId.pages,
      summary: 'apply $kind preset to page "$id"',
    );
  }

  // ─── 1.3.4 Phase-5 surfaces — i18n / services / templateLibraries
  //                              / theme.preset / theme.fonts /
  //                              navigation.style ─────────────────

  /// Add a BCP-47 locale tag to `/ui/i18n/locales`. Idempotent —
  /// silently no-ops when the tag already exists. Pass
  /// `setAsDefault: true` to also seed `/ui/i18n/defaultLocale`.
  Future<BuildToolResult> i18nLocaleAdd({
    required String tag,
    bool setAsDefault = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final locale = tag.trim();
    if (!RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(locale)) {
      return BuildToolResult.failure(
        'tag must be a BCP-47 locale (e.g. `en`, `en-US`, `zh-Hant-TW`)',
      );
    }
    final existing = _resolvePath(c.currentJson, '/ui/i18n/locales');
    final list =
        existing is List
            ? existing.whereType<String>().toList(growable: true)
            : <String>[];
    if (list.contains(locale)) {
      return BuildToolResult.success(
        message: 'locale "$locale" already registered',
        payload: jsonEncode(<String, dynamic>{
          'locales': list,
          if (setAsDefault) 'defaultLocale': locale,
        }),
      );
    }
    list.add(locale);
    final ops = <PatchOp>[
      PatchOp(op: 'add', path: '/ui/i18n/locales', value: list),
      if (setAsDefault)
        PatchOp(op: 'add', path: '/ui/i18n/defaultLocale', value: locale),
    ];
    return _dispatchOps(
      ops: ops,
      layer: LayerId.appStructure,
      summary:
          'add locale "$locale"'
          '${setAsDefault ? ' (default)' : ''}',
    );
  }

  /// Remove a locale tag from `/ui/i18n/locales`. Clears
  /// `defaultLocale` when it pointed at the removed tag.
  Future<BuildToolResult> i18nLocaleRemove({required String tag}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final locale = tag.trim();
    final existing = _resolvePath(c.currentJson, '/ui/i18n/locales');
    final list =
        existing is List
            ? existing.whereType<String>().toList(growable: true)
            : <String>[];
    if (!list.contains(locale)) {
      return BuildToolResult.failure('locale "$locale" not registered');
    }
    list.remove(locale);
    final defaultLocale = _resolvePath(c.currentJson, '/ui/i18n/defaultLocale');
    final ops = <PatchOp>[
      PatchOp(
        op: list.isEmpty ? 'remove' : 'replace',
        path: '/ui/i18n/locales',
        value: list.isEmpty ? null : list,
      ),
      if (defaultLocale == locale)
        PatchOp(op: 'remove', path: '/ui/i18n/defaultLocale', value: null),
    ];
    return _dispatchOps(
      ops: ops,
      layer: LayerId.appStructure,
      summary: 'remove locale "$locale"',
    );
  }

  /// Upsert a service entry under `/ui/services/<name>`. Required
  /// `name`. Optional fields go straight into the entry — pass only
  /// the ones you want to set; others stay untouched (when the entry
  /// already exists). Pass `entry` as a complete map to fully replace.
  Future<BuildToolResult> serviceSet({
    required String name,
    String? kind,
    num? interval,
    String? tool,
    Map<String, dynamic>? params,
    String? binding,
    dynamic onMessage,
    dynamic onError,
    bool? autoStart,
    Map<String, dynamic>? entry,
  }) async {
    final id = name.trim();
    if (id.isEmpty) return BuildToolResult.failure('name required');
    if (kind != null && kind.isNotEmpty) {
      if (!const <String>{'polling', 'subscription'}.contains(kind)) {
        return BuildToolResult.failure(
          'kind must be one of polling / subscription',
        );
      }
    }
    if (entry != null) {
      return _applySingleOp(
        op: 'add',
        path: '/ui/services/$id',
        value: entry,
        summary: 'replace service "$id"',
      );
    }
    final ops = <PatchOp>[];
    void put(String key, dynamic v) {
      if (v == null) return;
      ops.add(PatchOp(op: 'add', path: '/ui/services/$id/$key', value: v));
    }

    put('kind', kind);
    put('interval', interval);
    put('tool', tool);
    put('params', params);
    put('binding', binding);
    put('onMessage', onMessage);
    put('onError', onError);
    put('autoStart', autoStart);
    if (ops.isEmpty) {
      return BuildToolResult.failure(
        'provide at least one field (kind / interval / tool / binding / '
        'autoStart / params / onMessage / onError) or `entry`',
      );
    }
    return _dispatchOps(
      ops: ops,
      layer: LayerId.appStructure,
      summary: 'set service "$id"',
    );
  }

  /// Remove a service entry under `/ui/services/<name>`.
  Future<BuildToolResult> serviceRemove({required String name}) async {
    final id = name.trim();
    if (id.isEmpty) return BuildToolResult.failure('name required');
    return _applySingleOp(
      op: 'remove',
      path: '/ui/services/$id',
      value: null,
      summary: 'remove service "$id"',
    );
  }

  /// Append a TemplateLibraryRef to `/ui/templateLibraries`.
  /// Idempotent on `uri` — overwrites the existing entry rather
  /// than duplicating.
  Future<BuildToolResult> templateLibraryAdd({
    required String uri,
    String? version,
    String? integrity,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final href = uri.trim();
    if (href.isEmpty) return BuildToolResult.failure('uri required');
    final entry = <String, dynamic>{
      'uri': href,
      if (version != null && version.trim().isNotEmpty)
        'version': version.trim(),
      if (integrity != null && integrity.trim().isNotEmpty)
        'integrity': integrity.trim(),
    };
    final existing = _resolvePath(c.currentJson, '/ui/templateLibraries');
    final list =
        existing is List
            ? existing
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList(growable: true)
            : <Map<String, dynamic>>[];
    final idx = list.indexWhere((e) => e['uri'] == href);
    if (idx >= 0) {
      list[idx] = entry;
    } else {
      list.add(entry);
    }
    return _applySingleOp(
      op: 'add',
      path: '/ui/templateLibraries',
      value: list,
      summary:
          idx >= 0
              ? 'update template library "$href"'
              : 'add template library "$href"',
    );
  }

  /// Remove a TemplateLibraryRef by `uri` from
  /// `/ui/templateLibraries`. No-op if no match.
  Future<BuildToolResult> templateLibraryRemove({required String uri}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final href = uri.trim();
    if (href.isEmpty) return BuildToolResult.failure('uri required');
    final existing = _resolvePath(c.currentJson, '/ui/templateLibraries');
    final list =
        existing is List
            ? existing
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList(growable: true)
            : <Map<String, dynamic>>[];
    final filtered = list.where((e) => e['uri'] != href).toList();
    if (filtered.length == list.length) {
      return BuildToolResult.failure('template library "$href" not registered');
    }
    return _applySingleOp(
      op: filtered.isEmpty ? 'remove' : 'replace',
      path: '/ui/templateLibraries',
      value: filtered.isEmpty ? null : filtered,
      summary: 'remove template library "$href"',
    );
  }

  /// Set the curated content-app theme preset (1.3.4 Phase 5). Five
  /// values: `warm` / `cool` / `sepia` / `mono` / `highContrast`.
  /// Other `theme.*` fields stay layered on top.
  Future<BuildToolResult> themePresetSet({required String preset}) async {
    if (!const <String>{
      'warm',
      'cool',
      'sepia',
      'mono',
      'highContrast',
    }.contains(preset)) {
      return BuildToolResult.failure(
        'preset must be one of warm / cool / sepia / mono / highContrast',
      );
    }
    return _applySingleOp(
      op: 'add',
      path: '/ui/theme/preset',
      value: preset,
      summary: 'set theme preset "$preset"',
    );
  }

  /// Upsert a font family entry under `/ui/theme/fonts/<family>`.
  /// At least one of weights / variableAxes / fallbacks must be set
  /// — empty entries are rejected by the spec validator.
  Future<BuildToolResult> themeFontSet({
    required String family,
    Map<String, dynamic>? weights,
    List<dynamic>? variableAxes,
    List<String>? fallbacks,
  }) async {
    final fam = family.trim();
    if (fam.isEmpty) return BuildToolResult.failure('family required');
    if ((weights == null || weights.isEmpty) &&
        (variableAxes == null || variableAxes.isEmpty) &&
        (fallbacks == null || fallbacks.isEmpty)) {
      return BuildToolResult.failure(
        'set at least one of weights / variableAxes / fallbacks',
      );
    }
    final entry = <String, dynamic>{
      if (weights != null) 'weights': weights,
      if (variableAxes != null) 'variableAxes': variableAxes,
      if (fallbacks != null) 'fallbacks': fallbacks,
    };
    return _applySingleOp(
      op: 'add',
      path: '/ui/theme/fonts/$fam',
      value: entry,
      summary: 'set font "$fam"',
    );
  }

  /// Remove a font family from `/ui/theme/fonts`.
  Future<BuildToolResult> themeFontRemove({required String family}) async {
    final fam = family.trim();
    if (fam.isEmpty) return BuildToolResult.failure('family required');
    return _applySingleOp(
      op: 'remove',
      path: '/ui/theme/fonts/$fam',
      value: null,
      summary: 'remove font "$fam"',
    );
  }

  /// Upsert a single i18n string under
  /// `/ui/i18n/text/<locale>/<key>`. Locale is BCP-47 (validated);
  /// key is treated as a literal map key (RFC 6901 escapes applied
  /// for `/` and `~`).
  Future<BuildToolResult> i18nTextSet({
    required String locale,
    required String key,
    required String value,
  }) async {
    final loc = locale.trim();
    final k = key.trim();
    if (!RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(loc)) {
      return BuildToolResult.failure(
        'locale must be BCP-47 (e.g. `en`, `en-US`, `zh-Hant-TW`)',
      );
    }
    if (k.isEmpty) return BuildToolResult.failure('key required');
    final escaped = k.replaceAll('~', '~0').replaceAll('/', '~1');
    return _applySingleOp(
      op: 'add',
      path: '/ui/i18n/text/$loc/$escaped',
      value: value,
      summary: 'set i18n.$loc.$k',
    );
  }

  /// Upsert pluralization forms for a key in one locale —
  /// `/ui/i18n/pluralization/<locale>/<key>` typically maps CLDR
  /// categories (`zero` / `one` / `two` / `few` / `many` / `other`)
  /// to localized strings. `forms` replaces the whole entry.
  Future<BuildToolResult> i18nPluralizationSet({
    required String locale,
    required String key,
    required Map<String, dynamic> forms,
  }) async {
    final loc = locale.trim();
    final k = key.trim();
    if (!RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(loc)) {
      return BuildToolResult.failure(
        'locale must be BCP-47 (e.g. `en`, `en-US`)',
      );
    }
    if (k.isEmpty) return BuildToolResult.failure('key required');
    if (forms.isEmpty) return BuildToolResult.failure('forms required');
    final escaped = k.replaceAll('~', '~0').replaceAll('/', '~1');
    return _applySingleOp(
      op: 'add',
      path: '/ui/i18n/pluralization/$loc/$escaped',
      value: forms,
      summary: 'set i18n.pluralization.$loc.$k',
    );
  }

  /// Set the text direction for a locale —
  /// `/ui/i18n/textDirection/<locale>` ∈ `ltr` / `rtl`.
  Future<BuildToolResult> i18nTextDirectionSet({
    required String locale,
    required String direction,
  }) async {
    final loc = locale.trim();
    if (!RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(loc)) {
      return BuildToolResult.failure(
        'locale must be BCP-47 (e.g. `en`, `ar-SA`)',
      );
    }
    if (!const <String>{'ltr', 'rtl'}.contains(direction)) {
      return BuildToolResult.failure('direction must be ltr / rtl');
    }
    return _applySingleOp(
      op: 'add',
      path: '/ui/i18n/textDirection/$loc',
      value: direction,
      summary: 'set i18n.textDirection.$loc=$direction',
    );
  }

  /// Set a NavigationStyle slot for a single nav item —
  /// `/ui/navigation/items/<index>/style/<slot>`. Layered on top of
  /// the surface-level `NavigationConfig.style`.
  Future<BuildToolResult> navigationItemStyleSet({
    required int index,
    String? slot,
    dynamic value,
    Map<String, dynamic>? style,
  }) async {
    if (index < 0) {
      return BuildToolResult.failure('index must be >= 0');
    }
    if (style != null) {
      return _applySingleOp(
        op: 'add',
        path: '/ui/navigation/items/$index/style',
        value: style,
        summary: 'replace nav item[$index] style',
      );
    }
    final s = (slot ?? '').trim();
    if (s.isEmpty) {
      return BuildToolResult.failure('provide `slot`+`value` or `style`');
    }
    final pointer = s.split('.').join('/');
    return _applySingleOp(
      op: value == null ? 'remove' : 'add',
      path: '/ui/navigation/items/$index/style/$pointer',
      value: value,
      summary:
          value == null
              ? 'clear nav item[$index] style "$s"'
              : 'set nav item[$index] style "$s"',
    );
  }

  /// Apply a curated micro-recipe — small structural transform
  /// composed of a few patches. Recipes are quick-pick "wrap this
  /// widget in X" or "scaffold this page with Y" actions that the
  /// LLM (or an IDE button) can fire without spelling out every
  /// patch. Catalog:
  ///
  ///   `wrap_with_card({path})`
  ///       Wraps the widget at `path` in a `card`; the original
  ///       widget becomes the card's `child`.
  ///   `wrap_with_padding({path, value})`
  ///       Wraps in a `box` with the given numeric padding.
  ///   `wrap_with_hero({path, tag})`
  ///       Wraps in `hero` with the supplied shared-element tag.
  ///   `wrap_with_safearea({pageId})`
  ///       Wraps a page's existing `content` in `safeArea` so the
  ///       page respects device insets.
  ///   `add_floating_action({pageId, label, route})`
  ///       Sets the page's `floatingActionButton` slot to a
  ///       `floatingActionButton` widget that navigates on tap.
  ///   `add_loading_state({pageId, key})`
  ///       Seeds `state.<key> = false` on the page and wraps the
  ///       content in a `conditional` keyed off that flag — flip
  ///       the flag to show a `circularProgressIndicator` instead.
  ///
  /// Pass `dryRun:true` to return the patch shape without applying.
  Future<BuildToolResult> applyRecipe({
    required String name,
    required Map<String, dynamic> args,
    bool dryRun = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    Future<BuildToolResult> commit({
      required List<PatchOp> ops,
      required LayerId layer,
      required String summary,
    }) async {
      if (dryRun) {
        return BuildToolResult.success(
          message: 'recipe `$name` — dryRun · ${ops.length} ops',
          payload: jsonEncode(<String, dynamic>{
            'recipe': name,
            'ops': <Map<String, dynamic>>[
              for (final op in ops)
                <String, dynamic>{
                  'op': op.op,
                  'path': op.path,
                  if (op.op != 'remove') 'value': op.value,
                },
            ],
          }),
        );
      }
      return _dispatchOps(ops: ops, layer: layer, summary: summary);
    }

    String? requirePath() {
      final p = (args['path'] as String?)?.trim();
      if (p == null || p.isEmpty) return null;
      return _normalizePath(p);
    }

    String? requirePageId() {
      final id = (args['pageId'] as String?)?.trim();
      if (id == null || id.isEmpty) return null;
      final pages = (c.currentJson['ui'] as Map?)?['pages'];
      if (pages is! Map || !pages.containsKey(id)) return null;
      return id;
    }

    switch (name) {
      case 'wrap_with_card':
        {
          final path = requirePath();
          if (path == null) {
            return BuildToolResult.failure('path required');
          }
          final node = _resolvePath(c.currentJson, path);
          if (node == null) {
            return BuildToolResult.failure('no widget at $path');
          }
          final wrapped = <String, dynamic>{'type': 'card', 'child': node};
          return commit(
            ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: wrapped)],
            layer: _inferLayer(path),
            summary: 'recipe wrap_with_card @ $path',
          );
        }
      case 'wrap_with_padding':
        {
          final path = requirePath();
          if (path == null) {
            return BuildToolResult.failure('path required');
          }
          final padding = (args['value'] as num?) ?? 16;
          final node = _resolvePath(c.currentJson, path);
          if (node == null) {
            return BuildToolResult.failure('no widget at $path');
          }
          final wrapped = <String, dynamic>{
            'type': 'box',
            'padding': padding,
            'child': node,
          };
          return commit(
            ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: wrapped)],
            layer: _inferLayer(path),
            summary: 'recipe wrap_with_padding($padding) @ $path',
          );
        }
      case 'wrap_with_scroll':
        {
          final path = requirePath();
          if (path == null) {
            return BuildToolResult.failure('path required');
          }
          final direction =
              (args['direction'] as String?)?.trim() ?? 'vertical';
          if (direction != 'vertical' && direction != 'horizontal') {
            return BuildToolResult.failure(
              'direction must be vertical / horizontal',
            );
          }
          final node = _resolvePath(c.currentJson, path);
          if (node == null) {
            return BuildToolResult.failure('no widget at $path');
          }
          final wrapped = <String, dynamic>{
            'type': 'scrollView',
            'scrollDirection': direction,
            'children': <dynamic>[node],
          };
          return commit(
            ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: wrapped)],
            layer: _inferLayer(path),
            summary: 'recipe wrap_with_scroll($direction) @ $path',
          );
        }
      case 'wrap_with_expanded':
        {
          final path = requirePath();
          if (path == null) {
            return BuildToolResult.failure('path required');
          }
          final flex = (args['flex'] as num?)?.toInt() ?? 1;
          final node = _resolvePath(c.currentJson, path);
          if (node == null) {
            return BuildToolResult.failure('no widget at $path');
          }
          final wrapped = <String, dynamic>{
            'type': 'expanded',
            'flex': flex,
            'child': node,
          };
          return commit(
            ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: wrapped)],
            layer: _inferLayer(path),
            summary: 'recipe wrap_with_expanded(flex=$flex) @ $path',
          );
        }
      case 'wrap_with_centered':
        {
          final path = requirePath();
          if (path == null) {
            return BuildToolResult.failure('path required');
          }
          final node = _resolvePath(c.currentJson, path);
          if (node == null) {
            return BuildToolResult.failure('no widget at $path');
          }
          final wrapped = <String, dynamic>{'type': 'center', 'child': node};
          return commit(
            ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: wrapped)],
            layer: _inferLayer(path),
            summary: 'recipe wrap_with_centered @ $path',
          );
        }
      case 'wrap_with_aspect_ratio':
        {
          final path = requirePath();
          if (path == null) {
            return BuildToolResult.failure('path required');
          }
          final ratio = (args['ratio'] as num?)?.toDouble() ?? 16 / 9;
          final node = _resolvePath(c.currentJson, path);
          if (node == null) {
            return BuildToolResult.failure('no widget at $path');
          }
          final wrapped = <String, dynamic>{
            'type': 'aspectRatio',
            'aspectRatio': ratio,
            'child': node,
          };
          return commit(
            ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: wrapped)],
            layer: _inferLayer(path),
            summary: 'recipe wrap_with_aspect_ratio($ratio) @ $path',
          );
        }
      case 'wrap_with_clip_oval':
        {
          final path = requirePath();
          if (path == null) {
            return BuildToolResult.failure('path required');
          }
          final node = _resolvePath(c.currentJson, path);
          if (node == null) {
            return BuildToolResult.failure('no widget at $path');
          }
          final wrapped = <String, dynamic>{'type': 'clipOval', 'child': node};
          return commit(
            ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: wrapped)],
            layer: _inferLayer(path),
            summary: 'recipe wrap_with_clip_oval @ $path',
          );
        }
      case 'wrap_with_animated_opacity':
        {
          final path = requirePath();
          if (path == null) {
            return BuildToolResult.failure('path required');
          }
          final binding = (args['binding'] as String?)?.trim();
          final opacity =
              binding != null && binding.isNotEmpty
                  ? '{{$binding ? 1 : 0}}'
                  : 1;
          final duration = (args['duration'] as num?)?.toInt() ?? 300;
          final curve = (args['curve'] as String?)?.trim() ?? 'emphasized';
          final node = _resolvePath(c.currentJson, path);
          if (node == null) {
            return BuildToolResult.failure('no widget at $path');
          }
          final wrapped = <String, dynamic>{
            'type': 'animatedOpacity',
            'opacity': opacity,
            'duration': duration,
            'curve': curve,
            'child': node,
          };
          return commit(
            ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: wrapped)],
            layer: _inferLayer(path),
            summary: 'recipe wrap_with_animated_opacity @ $path',
          );
        }
      case 'wrap_with_hero':
        {
          final path = requirePath();
          if (path == null) {
            return BuildToolResult.failure('path required');
          }
          final tag = (args['tag'] as String?)?.trim();
          if (tag == null || tag.isEmpty) {
            return BuildToolResult.failure('tag required');
          }
          final node = _resolvePath(c.currentJson, path);
          if (node == null) {
            return BuildToolResult.failure('no widget at $path');
          }
          final wrapped = <String, dynamic>{
            'type': 'hero',
            'tag': tag,
            'child': node,
          };
          return commit(
            ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: wrapped)],
            layer: _inferLayer(path),
            summary: 'recipe wrap_with_hero("$tag") @ $path',
          );
        }
      case 'wrap_with_safearea':
        {
          final id = requirePageId();
          if (id == null) {
            return BuildToolResult.failure('valid pageId required');
          }
          final pageRoot = (c.currentJson['ui'] as Map)['pages'][id] as Map;
          final content = pageRoot['content'];
          if (content == null) {
            return BuildToolResult.failure('page "$id" has no content');
          }
          if (content is Map && content['type'] == 'safeArea') {
            return BuildToolResult.failure(
              'page "$id" content already wrapped in safeArea',
            );
          }
          final wrapped = <String, dynamic>{
            'type': 'safeArea',
            'child': content,
          };
          return commit(
            ops: <PatchOp>[
              PatchOp(
                op: 'replace',
                path: '/ui/pages/${_keyToPointer(id)}/content',
                value: wrapped,
              ),
            ],
            layer: LayerId.pages,
            summary: 'recipe wrap_with_safearea @ "$id"',
          );
        }
      case 'add_floating_action':
        {
          final id = requirePageId();
          if (id == null) {
            return BuildToolResult.failure('valid pageId required');
          }
          final label = (args['label'] as String?)?.trim() ?? 'Add';
          final route = (args['route'] as String?)?.trim();
          final fab = <String, dynamic>{
            'type': 'floatingActionButton',
            'label': label,
            'icon': 'add',
            if (route != null && route.isNotEmpty)
              'onPressed': <String, dynamic>{
                'type': 'navigate',
                'route': route,
              },
          };
          return commit(
            ops: <PatchOp>[
              PatchOp(
                op: 'add',
                path: '/ui/pages/${_keyToPointer(id)}/floatingActionButton',
                value: fab,
              ),
            ],
            layer: LayerId.pages,
            summary: 'recipe add_floating_action @ "$id"',
          );
        }
      case 'add_loading_state':
        {
          final id = requirePageId();
          if (id == null) {
            return BuildToolResult.failure('valid pageId required');
          }
          final key = (args['key'] as String?)?.trim() ?? 'isLoading';
          final pageRoot = (c.currentJson['ui'] as Map)['pages'][id] as Map;
          final content = pageRoot['content'];
          if (content == null) {
            return BuildToolResult.failure('page "$id" has no content');
          }
          final wrapped = <String, dynamic>{
            'type': 'conditional',
            'when': '{{state.$key}}',
            'then': <String, dynamic>{
              'type': 'center',
              'child': <String, dynamic>{'type': 'circularProgressIndicator'},
            },
            'else': content,
          };
          return commit(
            ops: <PatchOp>[
              PatchOp(
                op: 'replace',
                path: '/ui/pages/${_keyToPointer(id)}/content',
                value: wrapped,
              ),
              PatchOp(
                op: 'add',
                path: '/ui/pages/${_keyToPointer(id)}/state/$key',
                value: false,
              ),
            ],
            layer: LayerId.pages,
            summary: 'recipe add_loading_state("$key") @ "$id"',
          );
        }
      default:
        return BuildToolResult.failure(
          'unknown recipe: $name. Catalog: wrap_with_card / '
          'wrap_with_padding / wrap_with_scroll / wrap_with_expanded '
          '/ wrap_with_centered / wrap_with_aspect_ratio / '
          'wrap_with_clip_oval / wrap_with_hero / '
          'wrap_with_animated_opacity / wrap_with_safearea / '
          'add_floating_action / add_loading_state',
        );
    }
  }

  /// Rename a route path (e.g. `/old` → `/new`) keeping the same
  /// target page and updating all references — `initialRoute`,
  /// `nav.items[].route`, and any `{{routes.<oldPath>}}` bindings.
  /// Atomic. Path strings are not RFC 6901-escaped before display
  /// since route values use literal slashes (e.g. `/about`).
  Future<BuildToolResult> renameRoute({
    required String oldPath,
    required String newPath,
  }) async {
    final c = canonical;
    if (c == null || pipeline == null) {
      return BuildToolResult.failure('canonical/pipeline not wired');
    }
    final oldP = oldPath.trim();
    final newP = newPath.trim();
    if (oldP.isEmpty || newP.isEmpty) {
      return BuildToolResult.failure('oldPath / newPath required');
    }
    if (oldP == newP) {
      return BuildToolResult.failure('oldPath equals newPath');
    }
    if (!oldP.startsWith('/') || !newP.startsWith('/')) {
      return BuildToolResult.failure(
        'route paths must start with `/` (per spec)',
      );
    }
    final ui = c.currentJson['ui'];
    if (ui is! Map) {
      return BuildToolResult.failure('no /ui in canonical');
    }
    final routes = ui['routes'];
    if (routes is! Map) {
      return BuildToolResult.failure('/ui/routes is not a map');
    }
    if (!routes.containsKey(oldP)) {
      return BuildToolResult.failure('route "$oldP" not found');
    }
    if (routes.containsKey(newP)) {
      return BuildToolResult.failure('route "$newP" already exists');
    }
    final value = routes[oldP];
    final ops = <PatchOp>[
      PatchOp(
        op: 'add',
        path: '/ui/routes/${_keyToPointer(newP)}',
        value: value,
      ),
      PatchOp(op: 'remove', path: '/ui/routes/${_keyToPointer(oldP)}'),
    ];
    // initialRoute follow.
    if (ui['initialRoute'] == oldP) {
      ops.add(PatchOp(op: 'replace', path: '/ui/initialRoute', value: newP));
    }
    // navigation.items[].route follow.
    final nav = ui['navigation'];
    final navItems = nav is Map ? nav['items'] : null;
    var navUpdated = 0;
    if (navItems is List) {
      for (var i = 0; i < navItems.length; i++) {
        final item = navItems[i];
        if (item is Map && item['route'] == oldP) {
          ops.add(
            PatchOp(
              op: 'replace',
              path: '/ui/navigation/items/$i/route',
              value: newP,
            ),
          );
          navUpdated++;
        }
      }
    }
    // {{routes.<oldPath>}} binding rewrite — strings throughout.
    final pattern = RegExp(
      r'\{\{(\s*)routes\.' + RegExp.escape(oldP) + r'(\s*)\}\}',
    );
    var bindingCount = 0;
    void walk(dynamic node, String pointer) {
      if (node is String) {
        if (pattern.hasMatch(node)) {
          final next = node.replaceAllMapped(
            pattern,
            (m) => '{{${m.group(1)}routes.$newP${m.group(2)}}}',
          );
          ops.add(PatchOp(op: 'replace', path: pointer, value: next));
          bindingCount++;
        }
        return;
      }
      if (node is Map) {
        for (final entry in node.entries) {
          final key = '${entry.key}';
          final escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
          walk(entry.value, '$pointer/$escaped');
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$pointer/$i');
        }
      }
    }

    walk(ui, '/ui');
    final detail = <String>[
      if (ui['initialRoute'] == oldP) 'initialRoute',
      if (navUpdated > 0) '$navUpdated nav item${navUpdated == 1 ? '' : 's'}',
      if (bindingCount > 0)
        '$bindingCount binding${bindingCount == 1 ? '' : 's'}',
    ].join(' + ');
    return _dispatchOps(
      ops: ops,
      layer: LayerId.appStructure,
      summary:
          'rename route "$oldP" → "$newP"'
          '${detail.isEmpty ? '' : ' (+ $detail)'}',
    );
  }

  /// "Extract to template" refactor — takes a widget subtree at
  /// `widgetPath`, creates `/ui/templates/<newTemplateId>` with
  /// that subtree as its content, and replaces the original
  /// location with a `{type: use, template: <newTemplateId>}`
  /// widget. The inverse of `inline_template`.
  ///
  /// Fails if:
  ///   - widgetPath does not resolve to a widget (Map with `type`)
  ///   - newTemplateId already exists
  ///   - newTemplateId is empty / not a valid identifier
  ///
  /// All three ops (template add, original replace) dispatch as
  /// one transaction across the components + container layers.
  Future<BuildToolResult> extractToTemplate({
    required String widgetPath,
    required String newTemplateId,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final id = newTemplateId.trim();
    if (id.isEmpty) {
      return BuildToolResult.failure('newTemplateId required');
    }
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(id)) {
      return BuildToolResult.failure(
        'newTemplateId "$id" not a valid identifier '
        '(letter followed by letters/digits/underscore)',
      );
    }
    final root = c.currentJson;
    final widget = _resolvePath(root, widgetPath);
    if (widget is! Map || widget['type'] is! String) {
      return BuildToolResult.failure(
        'widgetPath "$widgetPath" did not resolve to a widget',
      );
    }
    final templates = (root['ui'] as Map?)?['templates'];
    if (templates is Map && templates.containsKey(id)) {
      return BuildToolResult.failure('template "$id" already exists');
    }
    // Capture the widget content and remove embedded id-like fields
    // we don't want leaking into the template definition (the
    // template root inherits identity from the template id itself).
    final captured = Map<String, dynamic>.from(widget);
    final ops = <PatchOp>[
      // 1. Ensure /ui/templates exists, then add the new template.
      if (templates is! Map)
        PatchOp(op: 'add', path: '/ui/templates', value: <String, dynamic>{}),
      PatchOp(
        op: 'add',
        path: '/ui/templates/${_keyToPointer(id)}',
        value: <String, dynamic>{'type': 'template', 'content': captured},
      ),
      // 2. Replace the original widget with a use:newId.
      PatchOp(
        op: 'replace',
        path: widgetPath,
        value: <String, dynamic>{'type': 'use', 'template': id},
      ),
    ];
    // Dispatch via diff_apply path (auto layer-infer per op).
    final result = await diffApply(
      ops: <Map<String, dynamic>>[
        for (final op in ops)
          <String, dynamic>{
            'op': op.op,
            'path': op.path,
            if (op.value != null) 'value': op.value,
          },
      ],
    );
    if (!result.success) return result;
    return BuildToolResult.success(
      message:
          'extract_to_template "$id" — captured ${captured['type']} '
          'from $widgetPath',
      payload: result.payload,
    );
  }

  /// Widget-shape audit — catches spec violations the upstream
  /// `validate_bundle` (mcp_bundle's `McpBundleValidator`) misses
  /// because it stops at the bundle envelope and doesn't dive into
  /// per-widget constraints. Hard-coded rules cover the cases the
  /// runtime is known to crash on (List form for fields that
  /// require a single Action object, etc).
  ///
  /// Rules currently checked:
  ///   onTap_must_be_action   widget event handlers (button /
  ///                          iconButton / floatingActionButton /
  ///                          listItem / gestureDetector / inkWell)
  ///                          require a single `{type, ...}` Action
  ///                          object. Spec ground truth: widget
  ///                          .onTap = Action; ActionOrList only
  ///                          applies to app/page lifecycle hooks.
  ///   children_must_be_list  layout containers (linear / stack /
  ///                          grid / staggeredGrid / wrap) require
  ///                          children to be a List.
  ///   button_label_required  button widgets need a label or icon.
  ///   text_content_required  text widget needs `content` or `text`.
  ///   image_src_required     image needs `src`.
  ///
  /// Optional `scope` JSON pointer narrows the walk; default `/ui`.
  Future<BuildToolResult> widgetShapeAudit({String? scope}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final root = c.currentJson;
    final scopePtr = scope == null || scope.isEmpty ? '/ui' : scope;
    final node = _resolvePath(root, scopePtr);
    if (node == null) {
      return BuildToolResult.failure('scope "$scopePtr" did not resolve');
    }
    const eventHandlerWidgets = <String>{
      'button',
      'iconButton',
      'floatingActionButton',
      'listItem',
      'gestureDetector',
      'inkWell',
    };
    const eventHandlerFields = <String>[
      'onTap',
      'onPressed',
      'onLongPress',
      'onDoubleTap',
      'onChange',
      'onSubmit',
      'onDismiss',
    ];
    const containerWidgets = <String>{
      'linear',
      'stack',
      'grid',
      'staggeredGrid',
      'wrap',
      'row',
      'column',
    };
    final findings = <Map<String, dynamic>>[];

    void walk(dynamic n, String pointer) {
      if (n is Map) {
        final type = n['type'];
        if (type is String) {
          // event handler shape
          if (eventHandlerWidgets.contains(type)) {
            for (final field in eventHandlerFields) {
              final v = n[field];
              if (v == null) continue;
              if (v is List) {
                findings.add(<String, dynamic>{
                  'rule': 'onTap_must_be_action',
                  'severity': 'fail',
                  'path': '$pointer/${_keyToPointer(field)}',
                  'widget': type,
                  'field': field,
                  'message':
                      '$type.$field is a List — spec requires a single '
                      'Action object. Wrap multiple actions in '
                      '{type:"sequence", actions:[...]} or '
                      '{type:"batch", actions:[...]}, or unwrap a '
                      '1-element list to its single Action.',
                  'fix':
                      v.length == 1 && v.first is Map
                          ? <String, dynamic>{
                            'tool': 'set_property',
                            'args': <String, dynamic>{
                              'path': '$pointer/${_keyToPointer(field)}',
                              'value': v.first,
                            },
                            'note': 'unwrap single-element list',
                          }
                          : <String, dynamic>{
                            'tool': 'set_property',
                            'args': <String, dynamic>{
                              'path': '$pointer/${_keyToPointer(field)}',
                              'value': <String, dynamic>{
                                'type': 'sequence',
                                'actions': v,
                              },
                            },
                            'note': 'wrap multi-action list in sequence',
                          },
                });
              } else if (v is! Map) {
                findings.add(<String, dynamic>{
                  'rule': 'onTap_must_be_action',
                  'severity': 'fail',
                  'path': '$pointer/${_keyToPointer(field)}',
                  'widget': type,
                  'field': field,
                  'message':
                      '$type.$field is ${v.runtimeType} — spec requires '
                      'an Action object {type, ...}.',
                });
              }
            }
          }
          // container children shape
          if (containerWidgets.contains(type)) {
            final ch = n['children'];
            if (ch != null && ch is! List) {
              findings.add(<String, dynamic>{
                'rule': 'children_must_be_list',
                'severity': 'fail',
                'path': '$pointer/children',
                'widget': type,
                'message':
                    '$type.children is ${ch.runtimeType} — spec '
                    'requires a List of widgets.',
              });
            }
          }
          // button needs label or icon
          if (type == 'button' || type == 'iconButton') {
            final hasLabel =
                (n['label'] is String && (n['label'] as String).isNotEmpty);
            final hasIcon = n['icon'] != null;
            if (!hasLabel && !hasIcon) {
              findings.add(<String, dynamic>{
                'rule':
                    type == 'iconButton'
                        ? 'iconButton_needs_icon'
                        : 'button_label_required',
                'severity': 'warn',
                'path': pointer,
                'widget': type,
                'message':
                    '$type without label or icon — invisible to users '
                    'and screen readers.',
              });
            }
          }
          // text needs content or text
          if (type == 'text' || type == 'richText') {
            if (n['content'] == null &&
                n['text'] == null &&
                n['spans'] == null) {
              findings.add(<String, dynamic>{
                'rule': 'text_content_required',
                'severity': 'warn',
                'path': pointer,
                'widget': type,
                'message':
                    '$type without content / text / spans — renders '
                    'nothing.',
              });
            }
          }
          // image needs src
          if (type == 'image') {
            if (n['src'] == null) {
              findings.add(<String, dynamic>{
                'rule': 'image_src_required',
                'severity': 'fail',
                'path': pointer,
                'widget': type,
                'message': 'image missing src.',
              });
            }
          }
        }
        for (final entry in n.entries) {
          final k = entry.key.toString();
          walk(entry.value, '$pointer/${_keyToPointer(k)}');
        }
      } else if (n is List) {
        for (var i = 0; i < n.length; i++) {
          walk(n[i], '$pointer/$i');
        }
      }
    }

    walk(node, scopePtr);
    final byRule = <String, int>{};
    final bySeverity = <String, int>{};
    for (final f in findings) {
      byRule['${f['rule']}'] = (byRule['${f['rule']}'] ?? 0) + 1;
      bySeverity['${f['severity']}'] =
          (bySeverity['${f['severity']}'] ?? 0) + 1;
    }
    final fails = bySeverity['fail'] ?? 0;
    final warns = bySeverity['warn'] ?? 0;
    return BuildToolResult.success(
      message:
          '${findings.length} shape finding'
          '${findings.length == 1 ? '' : 's'} '
          '($fails fail · $warns warn)'
          '${byRule.isEmpty ? '' : ' — ${byRule.entries.map((e) => '${e.key}:${e.value}').join(' · ')}'}',
      payload: jsonEncode(<String, dynamic>{
        'totalHits': findings.length,
        'byRule': byRule,
        'bySeverity': bySeverity,
        'findings': findings,
      }),
    );
  }

  /// Local-scope quality lint — surfaces structural issues that
  /// `health_check` misses because they aren't a11y / spec / wiring
  /// problems. Runs against the focused page (or `scope` when set)
  /// and returns findings the LLM / Inspector can act on.
  ///
  /// Rules:
  ///   deep_nesting           depth > 8 from container root
  ///   empty_container        linear/stack/grid with 0 children
  ///   long_text_leaf         text leaf > 240 chars (suggest i18n
  ///                          extraction)
  ///   list_no_item_id        listView/grid with `for` items but
  ///                          no `id`/`key` per item template
  ///   redundant_wrapper      linear with exactly 1 child + no
  ///                          decoration/padding (collapsible)
  Future<BuildToolResult> widgetLint({String? scope}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final root = c.currentJson;
    final scopePtr = scope == null || scope.isEmpty ? '/ui' : scope;
    final node = _resolvePath(root, scopePtr);
    if (node == null) {
      return BuildToolResult.failure('scope "$scopePtr" did not resolve');
    }
    final findings = <Map<String, dynamic>>[];
    void walk(dynamic n, String pointer, int depth) {
      if (n is Map) {
        final type = n['type'];
        if (type is String) {
          if (depth > 8) {
            findings.add(<String, dynamic>{
              'kind': 'deep_nesting',
              'path': pointer,
              'depth': depth,
              'message':
                  'widget at depth $depth — consider '
                  'extract_to_template to flatten',
            });
          }
          const containerTypes = <String>{
            'linear',
            'stack',
            'grid',
            'staggeredGrid',
            'wrap',
          };
          if (containerTypes.contains(type)) {
            final children = n['children'];
            if (children is List) {
              if (children.isEmpty) {
                findings.add(<String, dynamic>{
                  'kind': 'empty_container',
                  'path': pointer,
                  'type': type,
                  'message': 'empty $type — remove or seed with placeholder',
                });
              } else if (type == 'linear' &&
                  children.length == 1 &&
                  n['decoration'] == null &&
                  n['padding'] == null &&
                  n['margin'] == null &&
                  n['gap'] == null) {
                findings.add(<String, dynamic>{
                  'kind': 'redundant_wrapper',
                  'path': pointer,
                  'type': type,
                  'message':
                      'linear with single child + no styling — can '
                      'be collapsed to the inner widget',
                });
              }
            }
          }
          if (type == 'listView' || type == 'list') {
            final items = n['items'];
            final template = n['itemTemplate'];
            if (items is List &&
                items.isNotEmpty &&
                template is Map &&
                template['id'] == null &&
                template['key'] == null) {
              findings.add(<String, dynamic>{
                'kind': 'list_no_item_id',
                'path': pointer,
                'message':
                    'list itemTemplate lacks id/key — list-diff will '
                    'fall back to index, breaking reorder animations',
              });
            }
          }
          for (final field in const <String>['text', 'label', 'title']) {
            final v = n[field];
            if (v is String && v.length > 240) {
              findings.add(<String, dynamic>{
                'kind': 'long_text_leaf',
                'path':
                    '$pointer/'
                    '${field.replaceAll('~', '~0').replaceAll('/', '~1')}',
                'field': field,
                'length': v.length,
                'message':
                    '$field is ${v.length} chars — consider extracting '
                    'to state or i18n',
              });
            }
          }
        }
        for (final entry in n.entries) {
          final k = entry.key.toString();
          final v = entry.value;
          final escaped = k.replaceAll('~', '~0').replaceAll('/', '~1');
          walk(v, '$pointer/$escaped', type is String ? depth + 1 : depth);
        }
      } else if (n is List) {
        for (var i = 0; i < n.length; i++) {
          walk(n[i], '$pointer/$i', depth);
        }
      }
    }

    walk(node, scopePtr, 0);
    final byKind = <String, int>{};
    for (final f in findings) {
      byKind['${f['kind']}'] = (byKind['${f['kind']}'] ?? 0) + 1;
    }
    return BuildToolResult.success(
      message:
          '${findings.length} lint finding${findings.length == 1 ? '' : 's'}'
          '${byKind.isEmpty ? '' : ' (${byKind.entries.map((e) => '${e.key}:${e.value}').join(' · ')})'}',
      payload: jsonEncode(<String, dynamic>{
        'totalHits': findings.length,
        'byKind': byKind,
        'findings': findings,
      }),
    );
  }

  /// Find hardcoded design values (color hex, common spacing
  /// numerics) that should ideally reference theme tokens. The
  /// inverse of `token_usage` — that tool answers "where are
  /// tokens referenced?", this one answers "where should tokens
  /// have been used but weren't?".
  ///
  /// Rules:
  ///   color    — string hex matching `^#?[0-9a-fA-F]{6,8}` in any
  ///              field whose name is color-shaped (background,
  ///              color, fill, stroke, foreground, border, …) and
  ///              whose value isn't already a `tokens.color.X` ref
  ///   spacing  — number leaves under fields named padding /
  ///              margin / gap / spacing / inset where the value
  ///              matches a Material 3 spacing step (4, 8, 12, 16,
  ///              20, 24, 32, 40, 48). Smaller numerics are
  ///              treated as ad-hoc and skipped — too noisy.
  ///   radius   — number leaves under fields named borderRadius /
  ///              radius matching M3 shape steps (4, 8, 12, 16, 24,
  ///              28).
  ///
  /// Each finding includes a token suggestion when one is obvious
  /// (e.g. spacing 16 → "tokens.spacing.md").
  Future<BuildToolResult> tokenizationAudit({String? scope}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final ui = c.currentJson['ui'];
    if (ui is! Map) return BuildToolResult.failure('no /ui section');

    final root =
        scope == null || scope.isEmpty || scope == '/ui'
            ? ui
            : _resolvePath(c.currentJson, scope);
    if (root == null) {
      return BuildToolResult.failure('scope "$scope" did not resolve');
    }

    final findings = <Map<String, dynamic>>[];
    final colorFields = <String>{
      'color',
      'background',
      'backgroundColor',
      'fill',
      'foreground',
      'foregroundColor',
      'stroke',
      'border',
      'borderColor',
      'shadowColor',
      'tint',
      'overlay',
    };
    final spacingFields = <String>{
      'padding',
      'margin',
      'gap',
      'spacing',
      'inset',
      'paddingHorizontal',
      'paddingVertical',
      'paddingTop',
      'paddingBottom',
      'paddingLeft',
      'paddingRight',
      'marginHorizontal',
      'marginVertical',
    };
    final radiusFields = <String>{'borderRadius', 'radius', 'cornerRadius'};
    const spacingTokens = <int, String>{
      4: 'tokens.spacing.xs',
      8: 'tokens.spacing.sm',
      12: 'tokens.spacing.md',
      16: 'tokens.spacing.md',
      20: 'tokens.spacing.lg',
      24: 'tokens.spacing.lg',
      32: 'tokens.spacing.xl',
      40: 'tokens.spacing.xxl',
      48: 'tokens.spacing.xxl',
    };
    const radiusTokens = <int, String>{
      4: 'tokens.shape.xs',
      8: 'tokens.shape.sm',
      12: 'tokens.shape.md',
      16: 'tokens.shape.lg',
      24: 'tokens.shape.xl',
      28: 'tokens.shape.full',
    };
    final hexPattern = RegExp(r'^#?[0-9a-fA-F]{6,8}$');

    void walk(dynamic node, String pointer, String? lastKey) {
      if (node is Map) {
        for (final entry in node.entries) {
          final k = entry.key.toString();
          final v = entry.value;
          final escapedKey = k.replaceAll('~', '~0').replaceAll('/', '~1');
          walk(v, '$pointer/$escapedKey', k);
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$pointer/$i', lastKey);
        }
      } else if (node is String) {
        if (lastKey != null &&
            colorFields.contains(lastKey) &&
            hexPattern.hasMatch(node) &&
            !node.startsWith('tokens.')) {
          findings.add(<String, dynamic>{
            'kind': 'color',
            'path': pointer,
            'field': lastKey,
            'value': node,
            'suggestion':
                'consider a theme token (e.g. tokens.color.primary) — '
                'declare via theme_color_set first.',
          });
        }
      } else if (node is num) {
        if (lastKey != null && spacingFields.contains(lastKey)) {
          final n = node.toInt();
          if (n != node.toDouble()) {
            // skip non-integer
          } else if (spacingTokens.containsKey(n)) {
            findings.add(<String, dynamic>{
              'kind': 'spacing',
              'path': pointer,
              'field': lastKey,
              'value': n,
              'suggestion': spacingTokens[n],
            });
          }
        } else if (lastKey != null && radiusFields.contains(lastKey)) {
          final n = node.toInt();
          if (radiusTokens.containsKey(n)) {
            findings.add(<String, dynamic>{
              'kind': 'radius',
              'path': pointer,
              'field': lastKey,
              'value': n,
              'suggestion': radiusTokens[n],
            });
          }
        }
      }
    }

    final rootPointer = scope == null || scope.isEmpty ? '/ui' : scope;
    walk(root, rootPointer, null);

    final byKind = <String, int>{};
    for (final f in findings) {
      final k = '${f['kind']}';
      byKind[k] = (byKind[k] ?? 0) + 1;
    }
    return BuildToolResult.success(
      message:
          '${findings.length} hardcoded value${findings.length == 1 ? '' : 's'} '
          '(${byKind.entries.map((e) => '${e.key}:${e.value}').join(' · ')}'
          '${byKind.isEmpty ? 'none' : ''})',
      payload: jsonEncode(<String, dynamic>{
        'totalHits': findings.length,
        'byKind': byKind,
        'findings': findings,
      }),
    );
  }

  /// Cross-cutting dependency graph for the project — useful for
  /// marketplace pre-pack analysis ("what does this page actually
  /// need from the bundle?") and impact analysis ("if I remove
  /// template X, which pages break?").
  ///
  /// Returns a map keyed by container (page id / template id) with
  /// edges to:
  ///   routes      — route paths declared for this page
  ///   templates   — template ids referenced via `use`
  ///   assets      — asset ids referenced via `bundle://<id>` or
  ///                 image fields
  ///   stateKeys   — state keys this page declares (for pages only)
  ///   widgets     — widget type histogram (top-N by count)
  ///
  /// Plus a per-asset / per-template inverted index so callers can
  /// quickly answer "which pages use this asset?".
  Future<BuildToolResult> dependencyGraph({int topWidgets = 5}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final ui = c.currentJson['ui'];
    if (ui is! Map) {
      return BuildToolResult.failure('no /ui section');
    }
    final pages = ui['pages'];
    final templates = ui['templates'];
    final routes = ui['routes'];
    if (pages is! Map) {
      return BuildToolResult.success(
        message: 'no pages',
        payload: jsonEncode(<String, dynamic>{
          'containers': const <String, dynamic>{},
          'invertedTemplates': const <String, dynamic>{},
          'invertedAssets': const <String, dynamic>{},
        }),
      );
    }
    // Build reverse route lookup: pageId → list of routes.
    final routesByPage = <String, List<String>>{};
    if (routes is Map) {
      for (final entry in routes.entries) {
        final route = entry.key.toString();
        final target = entry.value;
        if (target is String) {
          routesByPage.putIfAbsent(target, () => <String>[]).add(route);
        }
      }
    }
    final assetPattern = RegExp(r'^bundle://([^/?#]+)');
    final containers = <String, Map<String, dynamic>>{};
    final invertedTemplates = <String, List<String>>{};
    final invertedAssets = <String, List<String>>{};

    void analyze(String containerKey, String containerKind, Map node) {
      final tplRefs = <String>{};
      final assetRefs = <String>{};
      final widgetTypes = <String, int>{};
      final stateKeys = <String>{};
      // Collect declared state keys at the container root.
      final state = node['state'];
      if (state is Map) {
        for (final k in state.keys) {
          stateKeys.add(k.toString());
        }
      }
      void walk(dynamic n) {
        if (n is Map) {
          final type = n['type'];
          if (type is String) {
            widgetTypes[type] = (widgetTypes[type] ?? 0) + 1;
            if (type == 'use') {
              final tpl = n['template'];
              if (tpl is String) tplRefs.add(tpl);
            }
          }
          for (final v in n.values) {
            if (v is String) {
              final m = assetPattern.firstMatch(v);
              if (m != null) assetRefs.add(m[1]!);
            } else {
              walk(v);
            }
          }
        } else if (n is List) {
          for (final e in n) {
            walk(e);
          }
        }
      }

      walk(node['content']);

      // Sort widget histogram by count desc, take top-N.
      final entries =
          widgetTypes.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
      final topTypes = <Map<String, dynamic>>[
        for (final e in entries.take(topWidgets))
          <String, dynamic>{'type': e.key, 'count': e.value},
      ];
      containers[containerKey] = <String, dynamic>{
        'kind': containerKind,
        'routes': routesByPage[containerKey] ?? const <String>[],
        'templates': tplRefs.toList()..sort(),
        'assets': assetRefs.toList()..sort(),
        'stateKeys': stateKeys.toList()..sort(),
        'totalWidgets': widgetTypes.values.fold<int>(0, (a, b) => a + b),
        'topTypes': topTypes,
      };
      for (final t in tplRefs) {
        invertedTemplates.putIfAbsent(t, () => <String>[]).add(containerKey);
      }
      for (final a in assetRefs) {
        invertedAssets.putIfAbsent(a, () => <String>[]).add(containerKey);
      }
    }

    for (final entry in pages.entries) {
      final id = entry.key.toString();
      final node = entry.value;
      if (node is Map) analyze(id, 'page', node);
    }
    if (templates is Map) {
      for (final entry in templates.entries) {
        final id = entry.key.toString();
        final node = entry.value;
        if (node is Map) analyze(id, 'template', node);
      }
    }
    // Sort container keys for stable output.
    final sortedKeys = containers.keys.toList()..sort();
    final sortedContainers = <String, Map<String, dynamic>>{
      for (final k in sortedKeys) k: containers[k]!,
    };
    final sortedInvertedT = <String, List<String>>{
      for (final k in (invertedTemplates.keys.toList()..sort()))
        k: invertedTemplates[k]!..sort(),
    };
    final sortedInvertedA = <String, List<String>>{
      for (final k in (invertedAssets.keys.toList()..sort()))
        k: invertedAssets[k]!..sort(),
    };
    return BuildToolResult.success(
      message:
          '${pages.length} page · ${templates is Map ? templates.length : 0} template · '
          '${invertedTemplates.length} template ref · '
          '${invertedAssets.length} asset ref',
      payload: jsonEncode(<String, dynamic>{
        'containers': sortedContainers,
        'invertedTemplates': sortedInvertedT,
        'invertedAssets': sortedInvertedA,
      }),
    );
  }

  /// Cross-cutting "find all references" — the IDE Find Usages
  /// equivalent. One tool, four kinds via the `target` form:
  ///
  ///   `template:<id>`   all `use` widgets pointing at that
  ///                      template (templates/components alike)
  ///   `state:<page>.<key>` all `{{key}}` interpolations and
  ///                      `binding` props that reference that
  ///                      state key on that page
  ///   `route:<path>`    all action/navigation widgets whose
  ///                      `route` field matches
  ///   `asset:<id>`      all string leaves equal to `bundle://<id>`
  ///                      (image / icon / contentRef forms)
  ///
  /// Returns `{kind, target, totalHits, byPage:{pageId:count},
  /// hits:[{path, container}]}` — `container` is the nearest page
  /// or template id so the caller can group results.
  Future<BuildToolResult> findReferences({required String target}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final ui = c.currentJson['ui'];
    if (ui is! Map) {
      return BuildToolResult.failure('no /ui section');
    }
    final colon = target.indexOf(':');
    if (colon <= 0) {
      return BuildToolResult.failure(
        'target must be "<kind>:<value>" — '
        'kind ∈ {template, state, route, asset}',
      );
    }
    final kind = target.substring(0, colon);
    final value = target.substring(colon + 1).trim();
    if (value.isEmpty) {
      return BuildToolResult.failure('target value empty');
    }
    final hits = <Map<String, dynamic>>[];

    String? containerOf(String pointer) {
      // Match /ui/pages/<id>/... or /ui/templates/<id>/... or
      // /ui/components/<id>/...
      final m = RegExp(
        r'^/ui/(pages|templates|components)/([^/]+)',
      ).firstMatch(pointer);
      return m == null ? null : '${m[1]}:${m[2]}';
    }

    void recordHit(String pointer, [Map<String, dynamic>? extra]) {
      final h = <String, dynamic>{
        'path': pointer,
        if (containerOf(pointer) != null) 'container': containerOf(pointer),
      };
      if (extra != null) h.addAll(extra);
      hits.add(h);
    }

    switch (kind) {
      case 'template':
        _walkAll(ui, '/ui', (n, path) {
          if (n is Map && n['type'] == 'use' && n['template'] == value) {
            recordHit(path, <String, dynamic>{
              if (n['props'] is Map) 'hasProps': true,
            });
          }
        });
        break;
      case 'state':
        final dot = value.indexOf('.');
        if (dot <= 0) {
          return BuildToolResult.failure(
            'state target must be "<pageId>.<key>"',
          );
        }
        final pageId = value.substring(0, dot);
        final key = value.substring(dot + 1);
        final pageRoot = '/ui/pages/${_keyToPointer(pageId)}';
        final pageNode = (ui['pages'] is Map ? ui['pages'][pageId] : null);
        if (pageNode is! Map) {
          return BuildToolResult.failure('page "$pageId" not found');
        }
        // {{key}} interpolation in any string leaf, plus binding
        // shorthand strings and explicit binding maps.
        final mustache = RegExp(r'\{\{\s*([a-zA-Z0-9_.]+)');
        void walkStr(dynamic n, String path) {
          if (n is String) {
            for (final m in mustache.allMatches(n)) {
              final ref = m.group(1)!;
              if (ref == key || ref.startsWith('$key.')) {
                recordHit(path, <String, dynamic>{
                  'preview': n.length > 60 ? '${n.substring(0, 57)}…' : n,
                });
                break;
              }
            }
          } else if (n is Map) {
            // explicit binding map: {binding:'state.key'} or
            // {binding:'key'}
            final b = n['binding'];
            if (b is String) {
              final clean =
                  b.startsWith('state.') ? b.substring('state.'.length) : b;
              if (clean == key || clean.startsWith('$key.')) {
                recordHit(path, <String, dynamic>{'binding': b});
              }
            }
            for (final entry in n.entries) {
              walkStr(entry.value, '$path/${_keyToPointer('${entry.key}')}');
            }
          } else if (n is List) {
            for (var i = 0; i < n.length; i++) {
              walkStr(n[i], '$path/$i');
            }
          }
        }

        walkStr(pageNode, pageRoot);
        break;
      case 'route':
        // Match action.navigate / type:'navigate' widgets whose
        // route field equals the value, plus navigation.items.route.
        _walkAll(ui, '/ui', (n, path) {
          if (n is! Map) return;
          // navigation.items[*].route
          if (n['route'] == value &&
              (n['label'] != null || n['icon'] != null)) {
            recordHit(path, <String, dynamic>{
              if (n['label'] is String) 'label': n['label'],
            });
            return;
          }
          // action: {type:'navigate', route:value}
          if (n['type'] == 'navigate' && n['route'] == value) {
            recordHit(path);
            return;
          }
          // onTap / onPressed: {action:'navigate', route:value}
          if (n['action'] == 'navigate' && n['route'] == value) {
            recordHit(path);
          }
        });
        // also: /ui/routes pointer at this key? that's the
        // *declaration*, not a reference — skip.
        break;
      case 'asset':
        final wanted = 'bundle://$value';
        void walkStr(dynamic n, String path) {
          if (n is String) {
            if (n == wanted) {
              recordHit(path);
            }
          } else if (n is Map) {
            for (final entry in n.entries) {
              walkStr(entry.value, '$path/${_keyToPointer('${entry.key}')}');
            }
          } else if (n is List) {
            for (var i = 0; i < n.length; i++) {
              walkStr(n[i], '$path/$i');
            }
          }
        }

        walkStr(ui, '/ui');
        break;
      default:
        return BuildToolResult.failure(
          'target kind "$kind" not supported. Use template:<id>, '
          'state:<page>.<key>, route:<path>, asset:<id>.',
        );
    }

    final byPage = <String, int>{};
    for (final h in hits) {
      final container = h['container'];
      if (container is String) {
        byPage[container] = (byPage[container] ?? 0) + 1;
      }
    }
    return BuildToolResult.success(
      message:
          '${hits.length} reference'
          '${hits.length == 1 ? '' : 's'} to $target',
      payload: jsonEncode(<String, dynamic>{
        'kind': kind,
        'target': value,
        'totalHits': hits.length,
        'byContainer': byPage,
        'hits': hits,
      }),
    );
  }

  /// Recent canonical mutations from `<projectPath>/history.jsonl`.
  /// Each entry shows when, what kind (patch / open / saveAs /
  /// revert), which JSON pointer paths changed, and which actor
  /// (chat / gui / mcp / etc) triggered it. Mostly useful for the
  /// LLM to answer "what just happened?" without dumping diffs.
  ///
  /// Args:
  ///   limit       max entries to return (default 50, capped 500).
  ///   originator  filter to a specific originator kind
  ///               ("chat", "gui", "mcp", ...). null = all.
  ///   pathPrefix  filter to entries whose changedPaths include any
  ///               path starting with this prefix (e.g. "/ui/theme"
  ///               to scope to theme edits).
  Future<BuildToolResult> undoHistory({
    int limit = 50,
    String? originator,
    String? pathPrefix,
  }) async {
    final entries = await project.historyLog.readAll();
    if (entries.isEmpty) {
      return BuildToolResult.success(
        message: 'history is empty',
        payload: jsonEncode(<String, dynamic>{
          'entries': const <Map<String, dynamic>>[],
          'totalRecorded': 0,
        }),
      );
    }
    Iterable<HistoryEntry> filtered = entries;
    if (originator != null && originator.isNotEmpty) {
      filtered = filtered.where((e) => e.originatorKind == originator);
    }
    if (pathPrefix != null && pathPrefix.isNotEmpty) {
      filtered = filtered.where(
        (e) => e.changedPaths.any((p) => p.startsWith(pathPrefix)),
      );
    }
    // Newest first — list as recorded, then reverse + cap.
    final list = filtered.toList().reversed.toList();
    final capped = math.min(math.max(1, limit), 500);
    final shown = list.take(capped).toList();
    return BuildToolResult.success(
      message:
          '${shown.length} of ${list.length} entr${list.length == 1 ? "y" : "ies"} '
          '(${entries.length} total recorded)',
      payload: jsonEncode(<String, dynamic>{
        'totalRecorded': entries.length,
        'totalMatching': list.length,
        'entries': <Map<String, dynamic>>[
          for (final e in shown)
            <String, dynamic>{
              'at': e.at.toIso8601String(),
              'kind': e.kind.name,
              if (e.originatorKind != null) 'originator': e.originatorKind,
              if (e.originatorId != null) 'originatorId': e.originatorId,
              'changedPaths':
                  e.changedPaths.length > 8
                      ? <dynamic>[
                        ...e.changedPaths.take(8),
                        '… (+${e.changedPaths.length - 8} more)',
                      ]
                      : e.changedPaths,
              'beforeHash':
                  e.beforeHash.isEmpty
                      ? null
                      : e.beforeHash.substring(
                        0,
                        math.min(8, e.beforeHash.length),
                      ),
              'afterHash':
                  e.afterHash.isEmpty
                      ? null
                      : e.afterHash.substring(
                        0,
                        math.min(8, e.afterHash.length),
                      ),
            },
        ],
      }),
    );
  }

  /// Routing-only audit. Walks `/ui/pages` × `/ui/routes` ×
  /// `/ui/initialRoute` and produces a dedicated report with
  /// suggested fix tool calls per finding. Narrower and more
  /// actionable than `health_check.wiringIssues` (which mixes in
  /// template / state / asset wiring). Returns:
  ///
  ///   pages       full page id list
  ///   routes      [{route, target, ok}] table
  ///   initialRoute current value + ok flag + resolved page id
  ///   findings    [{kind, ..., message, fix:{tool, args}}]
  ///
  /// Finding kinds:
  ///   missing_route_target   route → page that doesn't exist
  ///   orphan_page            page exists but no route points to it
  ///   missing_initial_route  initialRoute not in /ui/routes
  ///   duplicate_route_target two routes pointing at same page
  ///   no_routes              pages exist but routes table missing
  ///   no_initial_route       routes exist but initialRoute unset
  Future<BuildToolResult> routeAudit() async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final ui = c.currentJson['ui'];
    if (ui is! Map) {
      return BuildToolResult.success(
        message: 'no /ui section',
        payload: jsonEncode(<String, dynamic>{
          'pages': const <String>[],
          'routes': const <Map<String, dynamic>>[],
          'findings': const <Map<String, dynamic>>[],
        }),
      );
    }
    final pagesNode = ui['pages'];
    final routesNode = ui['routes'];
    final initial = ui['initialRoute'];

    final pageIds =
        pagesNode is Map
            ? pagesNode.keys.map((e) => e.toString()).toList()
            : <String>[];
    pageIds.sort();

    final routeTable = <Map<String, dynamic>>[];
    final findings = <Map<String, dynamic>>[];
    final routedTargets = <String, List<String>>{};

    if (routesNode is Map) {
      final keys = routesNode.keys.map((e) => e.toString()).toList()..sort();
      for (final route in keys) {
        final target = routesNode[route];
        final targetStr = target is String ? target : null;
        final ok = targetStr != null && pageIds.contains(targetStr);
        routeTable.add(<String, dynamic>{
          'route': route,
          'target': targetStr ?? target,
          'ok': ok,
        });
        if (targetStr != null) {
          routedTargets.putIfAbsent(targetStr, () => <String>[]).add(route);
          if (!pageIds.contains(targetStr)) {
            findings.add(<String, dynamic>{
              'kind': 'missing_route_target',
              'route': route,
              'target': targetStr,
              'message': 'route "$route" → "$targetStr" but no such page',
              'fix': <String, dynamic>{
                'tool': 'page_create',
                'args': <String, dynamic>{'id': targetStr, 'route': route},
                'note':
                    'creates the missing page (route already exists '
                    '— page_create will fail; remove the route '
                    'first or use set_property)',
              },
            });
          }
        }
      }
      for (final pid in pageIds) {
        if (!routedTargets.containsKey(pid)) {
          findings.add(<String, dynamic>{
            'kind': 'orphan_page',
            'page': pid,
            'message': 'page "$pid" is unreachable — no route',
            'fix': <String, dynamic>{
              'tool': 'set_property',
              'args': <String, dynamic>{
                'path': '/ui/routes/${_keyToPointer('/$pid')}',
                'value': pid,
              },
              'note': 'wires /$pid → "$pid"',
            },
          });
        }
      }
      // duplicate target detection
      for (final entry in routedTargets.entries) {
        if (entry.value.length > 1) {
          findings.add(<String, dynamic>{
            'kind': 'duplicate_route_target',
            'page': entry.key,
            'routes': entry.value,
            'message':
                '${entry.value.length} routes point at "${entry.key}" '
                '— ${entry.value.join(", ")}',
            'fix': <String, dynamic>{
              'tool': 'manual',
              'note':
                  'pick one canonical route, redirect or remove the '
                  'others (set_property remove on /ui/routes/<dup>)',
            },
          });
        }
      }
    } else if (pageIds.isNotEmpty) {
      findings.add(<String, dynamic>{
        'kind': 'no_routes',
        'message': '${pageIds.length} pages exist but /ui/routes is unset',
        'fix': <String, dynamic>{
          'tool': 'set_property',
          'args': <String, dynamic>{
            'path': '/ui/routes',
            'value': <String, dynamic>{for (final pid in pageIds) '/$pid': pid},
          },
          'note': 'seeds one route per page',
        },
      });
    }

    Map<String, dynamic>? initialReport;
    final hasRoutes = routeTable.isNotEmpty;
    if (initial is String && initial.isNotEmpty) {
      final hit = routeTable.firstWhere(
        (e) => e['route'] == initial,
        orElse: () => <String, dynamic>{},
      );
      final ok = hit.isNotEmpty && hit['ok'] == true;
      initialReport = <String, dynamic>{
        'value': initial,
        'ok': ok,
        if (hit.isNotEmpty) 'resolvesTo': hit['target'],
      };
      if (!ok) {
        findings.add(<String, dynamic>{
          'kind': 'missing_initial_route',
          'initialRoute': initial,
          'message': 'initialRoute "$initial" is not a valid route key',
          'fix': <String, dynamic>{
            'tool': 'set_property',
            'args': <String, dynamic>{
              'path': '/ui/initialRoute',
              'value': hasRoutes ? routeTable.first['route'] : null,
            },
            'note':
                hasRoutes
                    ? 'pick the first valid route (${routeTable.first['route']})'
                    : 'remove the initialRoute or add a route first',
          },
        });
      }
    } else if (hasRoutes) {
      findings.add(<String, dynamic>{
        'kind': 'no_initial_route',
        'message':
            '${routeTable.length} routes defined but initialRoute is unset',
        'fix': <String, dynamic>{
          'tool': 'set_property',
          'args': <String, dynamic>{
            'path': '/ui/initialRoute',
            'value': routeTable.first['route'],
          },
          'note':
              'pick the first route (${routeTable.first['route']}) '
              'or any other entry from the table',
        },
      });
    }

    final summary =
        StringBuffer()
          ..write(pageIds.length)
          ..write(' page · ')
          ..write(routeTable.length)
          ..write(' route · ')
          ..write(findings.length)
          ..write(' finding');
    return BuildToolResult.success(
      message: summary.toString(),
      payload: jsonEncode(<String, dynamic>{
        'pages': pageIds,
        'routes': routeTable,
        if (initialReport != null) 'initialRoute': initialReport,
        'findings': findings,
      }),
    );
  }

  /// Apply an external RFC 6902 patch array with per-op layer
  /// auto-inference. Complements `vibe_layer_patch` (which requires
  /// the caller to pick the layer up front) — useful when an
  /// external LLM produces a multi-op JSON Patch that touches
  /// pages / theme / assets in one transaction.
  ///
  /// Op paths drive layer choice: /ui/pages/* → pages,
  /// /ui/theme/* → theme, /ui/components|templates → components,
  /// /manifest/assets/* → assets, etc. Ops sharing a layer are
  /// dispatched as one group (preserves order within a layer);
  /// the layer order itself is the natural canonical order
  /// (appStructure → pages → components → theme → navigation →
  /// dashboard → assets → whole).
  ///
  /// Each group runs through the same PatchPipeline as direct
  /// edits — validation / projection / autosave all apply. If any
  /// group fails, prior groups are NOT rolled back (the canonical
  /// is mutable across dispatches), so callers should treat a
  /// partial failure like a partially applied transaction and
  /// inspect the returned per-group summary.
  Future<BuildToolResult> diffApply({required List<dynamic> ops}) async {
    if (ops.isEmpty) return BuildToolResult.failure('ops required');
    final groups = <LayerId, List<PatchOp>>{};
    final order = <LayerId>[];
    for (var i = 0; i < ops.length; i++) {
      final raw = ops[i];
      if (raw is! Map) {
        return BuildToolResult.failure('ops[$i] must be an object');
      }
      final op = (raw['op'] as String?)?.trim();
      final path = (raw['path'] as String?)?.trim();
      if (op == null || op.isEmpty) {
        return BuildToolResult.failure('ops[$i].op required');
      }
      if (path == null || path.isEmpty) {
        return BuildToolResult.failure('ops[$i].path required');
      }
      // PatchOp shape currently does not carry `from` (move/copy
      // are uncommon in vibe diffs). Reject these explicitly so
      // callers know to split into remove + add.
      if (op == 'move' || op == 'copy') {
        return BuildToolResult.failure(
          'ops[$i] op="$op" not supported by diff_apply — express '
          'as remove + add instead',
        );
      }
      // Destructive-write guard — same threshold as set_property.
      // Catches the bypass route where an LLM wraps a destructive
      // single-path overwrite inside a diff_apply transaction.
      if (op == 'replace' || op == 'add') {
        final destructive = _destructiveCheck(path, raw['value']);
        if (destructive != null) {
          return BuildToolResult.failure(
            'ops[$i] destructive write blocked — $destructive. '
            'Replace incrementally with delete_widget + add_child, '
            'or scope the diff to leaf-level edits.',
          );
        }
      }
      final patchOp = PatchOp(op: op, path: path, value: raw['value']);
      final layer = _inferLayer(path);
      groups
          .putIfAbsent(layer, () {
            order.add(layer);
            return <PatchOp>[];
          })
          .add(patchOp);
    }
    final summaries = <String>[];
    BuildToolResult? lastFail;
    var applied = 0;
    for (final layer in order) {
      final list = groups[layer]!;
      final r = await _dispatchOps(
        ops: list,
        layer: layer,
        summary: 'diff_apply ${layer.name} (${list.length} op)',
      );
      if (r.success) {
        applied += list.length;
        summaries.add('${layer.name}:${list.length} ok');
      } else {
        summaries.add('${layer.name}:${list.length} FAIL — ${r.message}');
        lastFail = r;
        break;
      }
    }
    final summary = summaries.join(' · ');
    if (lastFail != null) {
      return BuildToolResult.failure(
        'diff_apply partial — applied $applied / ${ops.length} · '
        '$summary',
      );
    }
    return BuildToolResult.success(
      message:
          'diff_apply ${ops.length} op across ${order.length} '
          'layer · $summary',
    );
  }

  /// Atomic "create a fully wired page" — creates the page entry,
  /// wires a route, and optionally seeds the content with a layout
  /// preset, in one dispatch. Avoids the LLM having to chain
  /// set_property + set_property + apply_layout_preset by hand.
  ///
  /// Args:
  ///   id           page id (required, non-empty, unique)
  ///   title        page title (default: id)
  ///   route        route path (default: `/<id>`). `null` = no
  ///                route entry. Already-existing route → fail.
  ///   kind         layout preset (hero / cardList / form /
  ///                settings / gallery / magazine / carousel /
  ///                playlist / landing). `null` = empty linear.
  ///   home         when true and no `initialRoute` set yet, also
  ///                writes `/ui/initialRoute` to the new route.
  Future<BuildToolResult> pageCreate({
    required String id,
    String? title,
    String? route,
    String? kind,
    bool home = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final pid = id.trim();
    if (pid.isEmpty) return BuildToolResult.failure('id required');
    final ui = c.currentJson['ui'];
    if (ui is! Map) return BuildToolResult.failure('no /ui in canonical');
    final pages = ui['pages'];
    if (pages is Map && pages.containsKey(pid)) {
      return BuildToolResult.failure('page "$pid" already exists');
    }
    final routePath = route ?? '/$pid'; // default to `/<id>`
    if (routePath.isNotEmpty && !routePath.startsWith('/')) {
      return BuildToolResult.failure('route must start with `/` (per spec)');
    }
    final routes = ui['routes'];
    if (routePath.isNotEmpty &&
        routes is Map &&
        routes.containsKey(routePath)) {
      return BuildToolResult.failure('route "$routePath" already exists');
    }
    Map<String, dynamic>? content;
    if (kind == null || kind.isEmpty) {
      content = <String, dynamic>{
        'type': 'linear',
        'direction': 'vertical',
        'children': const <Map<String, dynamic>>[],
      };
    } else {
      // Reuse applyLayoutPreset's content builder via a dryRun call
      // so the catalog stays single-source.
      final preview = await applyLayoutPreset(
        pageId: pid,
        kind: kind,
        dryRun: true,
      );
      // applyLayoutPreset's dryRun checks page exists — we'll seed
      // a placeholder first, then run the preset's commit path.
      // Simpler: create the page, then run apply_layout_preset for
      // real after the page exists.
      if (preview.message.startsWith('unknown kind')) {
        return BuildToolResult.failure(preview.message);
      }
      // First-pass content: empty linear; preset apply step
      // fills it.
      content = <String, dynamic>{
        'type': 'linear',
        'direction': 'vertical',
        'children': const <Map<String, dynamic>>[],
      };
    }
    final ops = <PatchOp>[
      PatchOp(
        op: 'add',
        path: '/ui/pages/${_keyToPointer(pid)}',
        value: <String, dynamic>{
          'type': 'page',
          'title': title ?? pid,
          'content': content,
        },
      ),
    ];
    if (routePath.isNotEmpty) {
      ops.add(
        PatchOp(
          op: 'add',
          path: '/ui/routes/${_keyToPointer(routePath)}',
          value: pid,
        ),
      );
      if (home && (ui['initialRoute'] == null)) {
        ops.add(PatchOp(op: 'add', path: '/ui/initialRoute', value: routePath));
      }
    }
    final detail = <String>[
      'page "$pid"',
      if (routePath.isNotEmpty) 'route "$routePath"',
      if (home) 'initialRoute',
      if (kind != null && kind.isNotEmpty) 'preset(pending)',
    ].join(' + ');
    final create = await _dispatchOps(
      ops: ops,
      layer: LayerId.appStructure,
      summary: 'page_create $detail',
    );
    if (!create.success) return create;
    if (kind != null && kind.isNotEmpty) {
      // Page now exists — apply the preset for real.
      return applyLayoutPreset(pageId: pid, kind: kind);
    }
    return create;
  }

  /// Global text search across the canonical. Walks string leaves
  /// and surface ids — matches the query as a case-insensitive
  /// substring. Each hit carries `{path, kind, preview}` where:
  ///   - kind ∈ pageId / templateId / routePath / widgetType /
  ///     widgetLabel / textContent / binding / asset
  ///   - preview is a short snippet of the matching string
  /// Ranking: exact-id matches first, then prefix matches, then
  /// substring matches; `cap` (default 50) limits result count.
  Future<BuildToolResult> search({required String query, int cap = 50}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final q = query.trim();
    if (q.isEmpty) return BuildToolResult.failure('query required');
    final ql = q.toLowerCase();
    final hits = <Map<String, dynamic>>[];
    final ui = c.currentJson['ui'];
    if (ui is! Map) {
      return BuildToolResult.success(
        message: '0 hits (no /ui)',
        payload: jsonEncode(<String, dynamic>{'hits': const <dynamic>[]}),
      );
    }
    int rankFor(String value) {
      final v = value.toLowerCase();
      if (v == ql) return 0; // exact
      if (v.startsWith(ql)) return 1; // prefix
      return 2; // substring
    }

    void emit({
      required String path,
      required String kind,
      required String preview,
      required int rank,
    }) {
      hits.add(<String, dynamic>{
        'path': path,
        'kind': kind,
        'preview':
            preview.length > 80 ? '${preview.substring(0, 80)}…' : preview,
        'rank': rank,
      });
    }

    // Page ids.
    final pages = ui['pages'];
    if (pages is Map) {
      for (final id in pages.keys) {
        final s = '$id';
        if (s.toLowerCase().contains(ql)) {
          emit(
            path: '/ui/pages/${_keyToPointer(s)}',
            kind: 'pageId',
            preview: s,
            rank: rankFor(s),
          );
        }
      }
    }
    // Template ids.
    final templates = ui['templates'];
    if (templates is Map) {
      for (final id in templates.keys) {
        final s = '$id';
        if (s.toLowerCase().contains(ql)) {
          emit(
            path: '/ui/templates/${_keyToPointer(s)}',
            kind: 'templateId',
            preview: s,
            rank: rankFor(s),
          );
        }
      }
    }
    // Route paths.
    final routes = ui['routes'];
    if (routes is Map) {
      for (final entry in routes.entries) {
        final s = '${entry.key}';
        if (s.toLowerCase().contains(ql)) {
          emit(
            path: '/ui/routes/${_keyToPointer(s)}',
            kind: 'routePath',
            preview: '$s → ${entry.value}',
            rank: rankFor(s),
          );
        }
      }
    }
    // Asset ids (manifest.assets[].id).
    final assets = (c.currentJson['manifest'] as Map?)?['assets'];
    if (assets is Map) {
      final list = assets['assets'];
      if (list is List) {
        for (var i = 0; i < list.length; i++) {
          final entry = list[i];
          if (entry is Map) {
            final id = '${entry['id'] ?? ''}';
            if (id.isNotEmpty && id.toLowerCase().contains(ql)) {
              emit(
                path: '/manifest/assets/assets/$i',
                kind: 'asset',
                preview: '$id (${entry['type'] ?? 'asset'})',
                rank: rankFor(id),
              );
            }
          }
        }
      }
    }
    // Widget walk — string leaves at owning widget pointer.
    final bindingPattern = RegExp(r'\{\{[^}]+\}\}');
    void walk(dynamic node, String pointer, {String? owningWidgetPath}) {
      if (node is String) {
        if (node.toLowerCase().contains(ql)) {
          final isBinding = bindingPattern.hasMatch(node);
          emit(
            path: pointer,
            kind: isBinding ? 'binding' : 'textContent',
            preview: node,
            rank: rankFor(node),
          );
        }
        return;
      }
      if (node is Map) {
        final isWidget = node['type'] is String;
        if (isWidget) {
          final t = '${node['type']}';
          if (t.toLowerCase().contains(ql)) {
            emit(
              path: pointer,
              kind: 'widgetType',
              preview: t,
              rank: rankFor(t),
            );
          }
          final lbl = node['label'];
          if (lbl is String && lbl.toLowerCase().contains(ql)) {
            emit(
              path: '$pointer/label',
              kind: 'widgetLabel',
              preview: lbl,
              rank: rankFor(lbl),
            );
          }
        }
        for (final entry in node.entries) {
          final key = '${entry.key}';
          final escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
          walk(
            entry.value,
            '$pointer/$escaped',
            owningWidgetPath: isWidget ? pointer : owningWidgetPath,
          );
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$pointer/$i', owningWidgetPath: owningWidgetPath);
        }
      }
    }

    walk(ui, '/ui');
    // Stable sort by rank ascending.
    hits.sort((a, b) => (a['rank'] as int).compareTo(b['rank'] as int));
    final capped = hits.take(cap).toList();
    return BuildToolResult.success(
      message:
          '${hits.length} hit'
          '${hits.length == 1 ? '' : 's'}'
          '${hits.length > cap ? ' (showing $cap)' : ''}',
      payload: jsonEncode(<String, dynamic>{
        'query': q,
        'totalHits': hits.length,
        'hits': capped,
      }),
    );
  }

  /// Walk a page's widget tree, collect every `{{state.<key>}}`
  /// reference, and propose seed entries for keys that aren't yet
  /// declared in `/ui/state` or `/ui/pages/<id>/state`. Default
  /// shape is null — author can edit afterwards. Pass `apply:true`
  /// to seed the missing keys at the page level. Existing keys are
  /// left alone — the tool never overwrites authored data.
  Future<BuildToolResult> stateProposeForPage({
    required String pageId,
    bool apply = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final id = pageId.trim();
    if (id.isEmpty) return BuildToolResult.failure('pageId required');
    final ui = c.currentJson['ui'];
    if (ui is! Map) return BuildToolResult.failure('no /ui in canonical');
    final pages = ui['pages'];
    if (pages is! Map || !pages.containsKey(id)) {
      return BuildToolResult.failure('page "$id" not found');
    }
    final pageRoot = pages[id];
    final pattern = RegExp(r'\{\{\s*state\.(\w+)');
    final referenced = <String>{};
    void walk(dynamic node) {
      if (node is String) {
        for (final m in pattern.allMatches(node)) {
          referenced.add(m.group(1)!);
        }
        return;
      }
      if (node is Map) {
        for (final v in node.values) {
          walk(v);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      }
    }

    walk(pageRoot);
    final appState = ui['state'];
    final declaredApp =
        appState is Map ? appState.keys.cast<String>().toSet() : <String>{};
    final pageState = pageRoot is Map ? pageRoot['state'] : null;
    final declaredPage =
        pageState is Map ? pageState.keys.cast<String>().toSet() : <String>{};
    final missing =
        referenced
            .where((k) => !declaredApp.contains(k) && !declaredPage.contains(k))
            .toList()
          ..sort();
    if (missing.isEmpty) {
      return BuildToolResult.success(
        message: 'no missing state keys on "$id"',
        payload: jsonEncode(<String, dynamic>{
          'referenced': referenced.toList()..sort(),
          'missing': <String>[],
        }),
      );
    }
    final proposals = <Map<String, dynamic>>[
      for (final k in missing) <String, dynamic>{'key': k, 'value': null},
    ];
    if (!apply) {
      return BuildToolResult.success(
        message:
            '${missing.length} missing state key'
            '${missing.length == 1 ? '' : 's'} on "$id"',
        payload: jsonEncode(<String, dynamic>{
          'pageId': id,
          'referenced': referenced.toList()..sort(),
          'missing': missing,
          'proposals': proposals,
        }),
      );
    }
    final ops = <PatchOp>[
      for (final k in missing)
        PatchOp(
          op: 'add',
          path: '/ui/pages/${_keyToPointer(id)}/state/${_keyToPointer(k)}',
          value: null,
        ),
    ];
    return _dispatchOps(
      ops: ops,
      layer: LayerId.pages,
      summary:
          'state_propose · seed ${missing.length} key'
          '${missing.length == 1 ? '' : 's'} on "$id"',
    );
  }

  /// Find every widget matching the filter and apply the same
  /// property change to each. Composes `findWidgets` semantics with
  /// the `setProperty` mutation:
  ///
  ///   apply_to_each({type: 'button', set: {variant: 'filled'}})
  ///   apply_to_each({type: 'text', refersTo: 'theme.color.primary',
  ///                  set: {style.fontWeight: 'bold'}})
  ///
  /// Filter args mirror `findWidgets` (type / label / hasProp /
  /// refersTo / scope). `set` is a flat map of property name → new
  /// value. `setDeep` is the same shape but the keys may be
  /// dot-paths (turned into nested set_property calls).
  /// `dryRun:true` previews the per-widget patch list without
  /// committing. `cap` limits the affected count (default 50).
  Future<BuildToolResult> applyToEach({
    String? type,
    String? label,
    String? hasProp,
    String? refersTo,
    String? scope,
    Map<String, dynamic>? set,
    Map<String, dynamic>? setDeep,
    int cap = 50,
    bool dryRun = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    if ((set == null || set.isEmpty) && (setDeep == null || setDeep.isEmpty)) {
      return BuildToolResult.failure(
        'provide `set` or `setDeep` (property → value).',
      );
    }
    if (type == null && label == null && hasProp == null && refersTo == null) {
      return BuildToolResult.failure(
        'provide at least one filter (type / label / hasProp / '
        'refersTo).',
      );
    }
    final find = await findWidgets(
      type: type,
      label: label,
      hasProp: hasProp,
      refersTo: refersTo,
      scope: scope,
    );
    if (!find.success || find.payload == null) {
      return BuildToolResult.failure('find_widgets failed: ${find.message}');
    }
    final paths = <String>[];
    try {
      final p = jsonDecode(find.payload!) as Map<String, dynamic>;
      final matches = p['matches'] as List? ?? const <dynamic>[];
      for (final m in matches) {
        if (m is Map && m['path'] is String) {
          paths.add(m['path'] as String);
        }
      }
    } catch (_) {
      return BuildToolResult.failure('could not parse find_widgets payload');
    }
    if (paths.isEmpty) {
      return BuildToolResult.success(
        message: 'no matches — nothing to apply',
        payload: jsonEncode(<String, dynamic>{'count': 0}),
      );
    }
    if (paths.length > cap) {
      return BuildToolResult.failure(
        '${paths.length} matches exceed cap=$cap. Tighten the '
        'filter or raise the cap explicitly.',
      );
    }
    final ops = <PatchOp>[];
    final preview = <Map<String, dynamic>>[];
    void emit(String widgetPath, String prop, dynamic value) {
      final pointer = '$widgetPath/${_keyToPointer(prop)}';
      ops.add(PatchOp(op: 'add', path: pointer, value: value));
      preview.add(<String, dynamic>{'path': pointer, 'value': value});
    }

    for (final widgetPath in paths) {
      if (set != null) {
        for (final entry in set.entries) {
          emit(widgetPath, entry.key, entry.value);
        }
      }
      if (setDeep != null) {
        for (final entry in setDeep.entries) {
          emit(widgetPath, entry.key, entry.value);
        }
      }
    }
    if (dryRun) {
      return BuildToolResult.success(
        message:
            'apply_to_each dryRun · ${paths.length} match'
            '${paths.length == 1 ? '' : 'es'} · '
            '${ops.length} op${ops.length == 1 ? '' : 's'}',
        payload: jsonEncode(<String, dynamic>{
          'matches': paths.length,
          'opCount': ops.length,
          'preview': preview,
        }),
      );
    }
    return _dispatchOps(
      ops: ops,
      // Bulk edits typically span multiple layers; default to pages.
      // The pipeline's spec validator runs against the merged
      // canonical so layer choice mostly drives undo bucket / hint.
      layer: LayerId.pages,
      summary:
          'apply_to_each · ${paths.length} match'
          '${paths.length == 1 ? '' : 'es'} · '
          '${ops.length} op${ops.length == 1 ? '' : 's'}',
    );
  }

  /// Self-describing help index. Returns a grouped catalog of vibe
  /// tools so the LLM can answer "what can vibe do?" with structure
  /// instead of grep'ing through tool descriptions. Groups mirror
  /// vibe's authoring vocabulary — discovery, mutation, audit /
  /// repair, presets, refactor, transitions, multimodal, governance.
  Future<BuildToolResult> help() async {
    const catalog = <String, List<String>>{
      'discovery': <String>[
        'bundle_outline — manifest + app + theme + page list summary.',
        'tree_outline — flat widget tree under a scope.',
        'get_widget — full subtree of one widget.',
        'get_section — read a typed section by id.',
        'find_widgets — search by type / label / hasProp / refersTo.',
        'spec_card — focused 1.3.4 reference card per topic.',
        'help — this list.',
      ],
      'mutation': <String>[
        'set_property — UPSERT one field at a JSON pointer.',
        'add_child — insert into a parent slot.',
        'move_widget — atomic remove + add.',
        'delete_widget — remove any node.',
        'replace_subtree — swap a whole subtree.',
        'apply_patch — RFC 6902 ops batch.',
        'widget_diff — preview a candidate widget.',
        'pending_diff — what `Save` would commit.',
      ],
      'audit_repair': <String>[
        'check_wiring — orphans, missing targets, undefined refs.',
        'validate_bundle — full spec + wiring validation.',
        'a11y_audit — WCAG 2.1 AA + Material findings.',
        'a11y_quick_fix — auto-fix unambiguous a11y issues.',
        'asset_audit — invalid contentRef migration.',
        'state_usage — declared vs referenced state per page.',
        'binding_dependencies — what depends on this widget.',
        'health_check — single-call aggregator.',
        'grade — letter A–F + 5-axis rubric.',
        'release_check — multi-stage graduation verdict.',
      ],
      'presets_recipes': <String>[
        'apply_theme_preset — M3 seed-color theme.',
        'apply_layout_preset — page scaffold (hero / form / '
            'gallery / playlist / etc.). dryRun:true to preview.',
        'apply_recipe — structural transforms (wrap_with_*, '
            'add_floating_action, add_loading_state).',
        'theme_preset_set — 1.3.4 curated presets (warm / cool '
            '/ sepia / mono / highContrast).',
        'animation_preset — M3 motion uniform on a page.',
      ],
      'refactor': <String>[
        'rename_page — rename + auto-update routes.',
        'rename_template — rename + auto-update `use` widgets.',
        'rename_state_key — rename + auto-update bindings.',
        'rename_route — rename path + nav / initialRoute / '
            'bindings.',
        'extract_template — lift a subtree to /ui/templates.',
        'inline_template — fold a `use` back inline.',
        'duplicate_page — clone with route.',
        'swap_widget — change type + transfer compatible props.',
        'extract_i18n — lift literal strings to /ui/i18n.',
      ],
      'authoring_surfaces': <String>[
        'i18n_locale_add / remove / text_set / pluralization_set '
            '/ text_direction_set.',
        'service_set / remove.',
        'template_library_add / remove.',
        'theme_font_set / remove · theme_preset_set.',
        'navigation_style_set · navigation_item_style_set.',
        'token_usage — find every use of a theme role.',
      ],
      'multimodal': <String>[
        'vibe_design_critique — capture preview + LLM critique '
            'brief (focus: layout / typography / color / spacing '
            '/ motion / a11y / consistency / all).',
        'vibe_preview_capture / app_capture — snapshot bytes.',
        'vibe_layout_snapshot — render-tree introspection.',
      ],
    };
    return BuildToolResult.success(
      message:
          'help · ${catalog.values.fold<int>(0, (n, l) => n + l.length)} '
          'tools across ${catalog.length} groups',
      payload: jsonEncode(catalog),
    );
  }

  /// Diff the active channel's canonical JSON against the version
  /// last persisted to disk — i.e. what `Save` would commit. Returns
  /// the RFC-6902 ops + a per-pointer summary tree (added / removed
  /// / modified). When the canonical and disk match, `opCount` is 0
  /// and the bundle is clean.
  Future<BuildToolResult> pendingDiff() async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final ws = c.workspacePath;
    if (ws == null) {
      return BuildToolResult.failure('no active workspace path');
    }
    final fsPort = FileWorkspaceFsPort();
    final committed = await fsPort.readJson(ws);
    if (committed == null) {
      return BuildToolResult.failure('committed bundle not on disk yet');
    }
    final ops = <Map<String, dynamic>>[];
    final summary = <Map<String, dynamic>>[];
    void diff(dynamic a, dynamic b, String pointer) {
      if (a == null && b != null) {
        ops.add(<String, dynamic>{'op': 'add', 'path': pointer, 'value': b});
        summary.add(<String, dynamic>{'pointer': pointer, 'kind': 'added'});
        return;
      }
      if (a != null && b == null) {
        ops.add(<String, dynamic>{'op': 'remove', 'path': pointer});
        summary.add(<String, dynamic>{'pointer': pointer, 'kind': 'removed'});
        return;
      }
      if (a is Map && b is Map) {
        final keys = <String>{
          ...a.keys.cast<String>(),
          ...b.keys.cast<String>(),
        };
        for (final k in keys) {
          final escaped = k.replaceAll('~', '~0').replaceAll('/', '~1');
          diff(a[k], b[k], '$pointer/$escaped');
        }
        return;
      }
      if (a is List && b is List) {
        final maxLen = a.length > b.length ? a.length : b.length;
        for (var i = 0; i < maxLen; i++) {
          diff(
            i < a.length ? a[i] : null,
            i < b.length ? b[i] : null,
            '$pointer/$i',
          );
        }
        return;
      }
      if (jsonEncode(a) == jsonEncode(b)) return;
      ops.add(<String, dynamic>{'op': 'replace', 'path': pointer, 'value': b});
      summary.add(<String, dynamic>{'pointer': pointer, 'kind': 'modified'});
    }

    diff(committed, c.currentJson, '');
    final added = summary.where((s) => s['kind'] == 'added').length;
    final removed = summary.where((s) => s['kind'] == 'removed').length;
    final modified = summary.where((s) => s['kind'] == 'modified').length;
    return BuildToolResult.success(
      message:
          ops.isEmpty
              ? 'no pending changes — canonical matches disk'
              : 'pending · $added added · $removed removed · '
                  '$modified modified',
      payload: jsonEncode(<String, dynamic>{
        'opCount': ops.length,
        'added': added,
        'removed': removed,
        'modified': modified,
        'ops': ops,
        'summary': summary,
      }),
    );
  }

  /// Letter-grade summary of bundle quality. Aggregates health
  /// metrics, content density, and motion / token coherence into a
  /// single A–F letter so the LLM can answer "how is this bundle
  /// doing?" at a glance. Rubric (each scored 0–20):
  ///   - validity     spec issues / wiring issues (0 = best)
  ///   - a11y         a11y fails / warns
  ///   - assets       invalid contentRefs
  ///   - state        undefined / unused state keys
  ///   - tokens       dead theme tokens
  /// Total /100. A ≥90, B ≥80, C ≥70, D ≥60, F < 60. Empty bundles
  /// (no pages) score N/A. Returns rubric breakdown so authors see
  /// which axes drag the grade down.
  Future<BuildToolResult> grade() async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final h = await healthCheck();
    if (!h.success || h.payload == null) {
      return BuildToolResult.failure('health_check failed');
    }
    final hp = jsonDecode(h.payload!) as Map<String, dynamic>;
    final summary = (hp['summary'] as Map?) ?? const <String, dynamic>{};
    final pages = (c.currentJson['ui'] as Map?)?['pages'];
    final pageCount = pages is Map ? pages.length : 0;
    if (pageCount == 0) {
      return BuildToolResult.success(
        message: 'grade · N/A (empty bundle — add a page first)',
        payload: jsonEncode(<String, dynamic>{
          'grade': 'N/A',
          'reason': 'no pages',
        }),
      );
    }
    int penalty(num issues, {num cap = 20, num perIssue = 4}) {
      final p = (issues * perIssue).clamp(0, cap).toInt();
      return 20 - p;
    }

    final validity = penalty(
      ((summary['specIssues'] ?? 0) as int) +
          ((summary['wiringIssues'] ?? 0) as int),
    );
    final a11y = penalty(
      ((summary['a11yFails'] ?? 0) as int) * 2 +
          ((summary['a11yWarns'] ?? 0) as int),
    );
    final assets = penalty((summary['invalidAssets'] ?? 0) as int, perIssue: 5);
    final state = penalty(
      ((summary['undefinedState'] ?? 0) as int) * 2 +
          ((summary['unusedState'] ?? 0) as int),
    );
    final tokens = penalty((summary['deadTokens'] ?? 0) as int, perIssue: 3);
    final total = validity + a11y + assets + state + tokens;
    final letter =
        total >= 90
            ? 'A'
            : total >= 80
            ? 'B'
            : total >= 70
            ? 'C'
            : total >= 60
            ? 'D'
            : 'F';
    return BuildToolResult.success(
      message: 'grade · $letter ($total/100)',
      payload: jsonEncode(<String, dynamic>{
        'grade': letter,
        'total': total,
        'rubric': <String, int>{
          'validity': validity,
          'a11y': a11y,
          'assets': assets,
          'state': state,
          'tokens': tokens,
        },
        'pageCount': pageCount,
        'summary': summary,
      }),
    );
  }

  /// Multi-stage release check. Walks the bundle through every
  /// auto-repair vibe knows about, reports what changed, and ends
  /// with a clean / not-clean verdict so the LLM can answer
  /// "ship it?" in one call. Stages:
  ///   1. health_check (initial snapshot)
  ///   2. asset_audit(apply) when invalid contentRefs exist
  ///   3. a11y_quick_fix when fixable findings exist
  ///   4. health_check (final snapshot, for diff)
  ///   5. validate_bundle (spec + wiring)
  /// Returns `{ready, before, after, steps[], remaining: {fails,
  /// warns}}`. `ready` is true when after.blocking is 0. Pass
  /// `dryRun:true` to see what stages WOULD apply without mutating.
  Future<BuildToolResult> releaseCheck({bool dryRun = false}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final steps = <Map<String, dynamic>>[];
    Map<String, dynamic>? parseHealth(BuildToolResult r) {
      if (!r.success || r.payload == null) return null;
      try {
        return jsonDecode(r.payload!) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }

    // 1. Initial health.
    final initialResult = await healthCheck();
    final before = parseHealth(initialResult) ?? const <String, dynamic>{};
    steps.add(<String, dynamic>{
      'stage': 'health_check.initial',
      'status': before['status'],
      'summary': before['summary'],
    });

    // 2. Asset audit when invalid entries exist.
    final invalidAssets = (before['summary']?['invalidAssets'] ?? 0) as int;
    if (invalidAssets > 0) {
      if (dryRun) {
        steps.add(<String, dynamic>{
          'stage': 'asset_audit.would_apply',
          'count': invalidAssets,
        });
      } else {
        final r = await assetAudit(apply: true);
        steps.add(<String, dynamic>{
          'stage': 'asset_audit.apply',
          'message': r.message,
          'success': r.success,
        });
      }
    }

    // 3. a11y quick-fix when fixable findings exist.
    final a11y = before['details']?['a11y'];
    int fixable = 0;
    if (a11y is Map) {
      final findings = a11y['findings'];
      if (findings is List) {
        for (final f in findings) {
          if (f is! Map) continue;
          final rule = f['rule'];
          if (rule == 'text.minFontSize' || rule == 'touchTarget.minSize') {
            fixable++;
          }
        }
      }
    }
    if (fixable > 0) {
      if (dryRun) {
        steps.add(<String, dynamic>{
          'stage': 'a11y_quick_fix.would_apply',
          'count': fixable,
        });
      } else {
        final r = await a11yQuickFix();
        steps.add(<String, dynamic>{
          'stage': 'a11y_quick_fix.apply',
          'message': r.message,
          'success': r.success,
        });
      }
    }

    // 4. Final health (post-repair).
    Map<String, dynamic> after;
    if (dryRun) {
      after = before; // No mutations applied — final == initial.
    } else {
      final finalResult = await healthCheck();
      after = parseHealth(finalResult) ?? const <String, dynamic>{};
      steps.add(<String, dynamic>{
        'stage': 'health_check.final',
        'status': after['status'],
        'summary': after['summary'],
      });
    }

    // 5. Verdict.
    final summary =
        after['summary'] is Map
            ? after['summary'] as Map
            : const <String, dynamic>{};
    final blocking =
        ((summary['specIssues'] ?? 0) as int) +
        ((summary['wiringIssues'] ?? 0) as int) +
        ((summary['a11yFails'] ?? 0) as int) +
        ((summary['invalidAssets'] ?? 0) as int) +
        ((summary['undefinedState'] ?? 0) as int);
    final advisory =
        ((summary['a11yWarns'] ?? 0) as int) +
        ((summary['unusedState'] ?? 0) as int) +
        ((summary['deadTokens'] ?? 0) as int);
    final ready = blocking == 0;
    final headline =
        dryRun
            ? 'release · dryRun · ${steps.length} stage'
                '${steps.length == 1 ? '' : 's'} planned'
            : ready
            ? 'release · ✓ ready · $advisory advisory'
            : 'release · ✗ blocked · $blocking blocking · '
                '$advisory advisory';
    return BuildToolResult.success(
      message: headline,
      payload: jsonEncode(<String, dynamic>{
        'ready': ready,
        'dryRun': dryRun,
        'before': before['summary'] ?? const <String, dynamic>{},
        'after': summary,
        'remaining': <String, dynamic>{
          'blocking': blocking,
          'advisory': advisory,
        },
        'steps': steps,
      }),
    );
  }

  /// Apply auto-fixable a11y findings. Walks `a11yAudit` output and
  /// applies the unambiguous repairs:
  ///   - `text.minFontSize`   → set `style.fontSize` (or `fontSize`)
  ///                            to 12 when current < 12.
  ///   - `touchTarget.minSize` → set `width` and `height` to 48 on
  ///                            buttons / iconButton when missing or
  ///                            below 48. Drops the `size: 'small'`
  ///                            shorthand when present.
  /// Ambiguous repairs (button without label, input without label,
  /// etc.) are NOT auto-applied — they need author content.
  /// Set [markDecorative] to also flag missing-semanticLabel image
  /// / icon findings as `decorative: true` — only do this when you
  /// know the asset really is purely visual (the runtime then
  /// hides it from screen readers).
  /// Pass `dryRun:true` to preview, `pageId` to scope.
  Future<BuildToolResult> a11yQuickFix({
    String? pageId,
    bool dryRun = false,
    bool markDecorative = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final audit = await a11yAudit(pageId: pageId);
    if (!audit.success || audit.payload == null) {
      return BuildToolResult.failure('a11y audit failed');
    }
    final findings =
        jsonDecode(audit.payload!)['findings'] as List? ?? const <dynamic>[];
    final ops = <PatchOp>[];
    final repaired = <Map<String, dynamic>>[];
    for (final f in findings) {
      if (f is! Map) continue;
      final rule = f['rule'];
      final path = f['path'] as String?;
      if (path == null) continue;
      if (rule == 'text.minFontSize') {
        // Set fontSize=12. Prefer style.fontSize when style is a Map.
        final node = _resolvePath(c.currentJson, path);
        if (node is Map) {
          final style = node['style'];
          if (style is Map) {
            ops.add(
              PatchOp(op: 'replace', path: '$path/style/fontSize', value: 12),
            );
          } else {
            ops.add(PatchOp(op: 'add', path: '$path/fontSize', value: 12));
          }
          repaired.add(<String, dynamic>{
            'path': path,
            'rule': rule,
            'fix': 'fontSize → 12',
          });
        }
      } else if (rule == 'touchTarget.minSize') {
        ops.add(PatchOp(op: 'add', path: '$path/width', value: 48));
        ops.add(PatchOp(op: 'add', path: '$path/height', value: 48));
        // Drop size: 'small' if present — replace with regular size.
        final node = _resolvePath(c.currentJson, path);
        if (node is Map && node['size'] == 'small') {
          ops.add(PatchOp(op: 'remove', path: '$path/size', value: null));
        }
        repaired.add(<String, dynamic>{
          'path': path,
          'rule': rule,
          'fix': 'width/height → 48',
        });
      } else if (markDecorative &&
          (rule == 'icon.accessibleName' || rule == 'image.accessibleName')) {
        ops.add(PatchOp(op: 'add', path: '$path/decorative', value: true));
        repaired.add(<String, dynamic>{
          'path': path,
          'rule': rule,
          'fix': 'decorative: true',
        });
      }
    }
    if (repaired.isEmpty) {
      return BuildToolResult.success(
        message: 'no auto-fixable a11y findings',
        payload: jsonEncode(<String, dynamic>{'repaired': []}),
      );
    }
    final summary =
        '${repaired.length} a11y fix'
        '${repaired.length == 1 ? '' : 'es'} '
        '${dryRun ? 'would apply' : 'applied'}';
    if (dryRun) {
      return BuildToolResult.success(
        message: summary,
        payload: jsonEncode(<String, dynamic>{
          'repaired': repaired,
          'opCount': ops.length,
        }),
      );
    }
    return _dispatchOps(
      ops: ops,
      layer: pageId != null ? LayerId.pages : LayerId.appStructure,
      summary: summary,
    );
  }

  /// Single-shot health check. Runs spec + wiring validation, the
  /// a11y audit, the asset registry audit, per-page state-usage
  /// summary, and a "dead theme tokens" pass (tokens defined under
  /// /ui/theme but referenced 0 times in the bundle). Returns the
  /// aggregated counts + the most actionable findings so the LLM
  /// can answer "is this bundle ready to ship?" in one call.
  Future<BuildToolResult> healthCheck() async {
    final c = canonical;
    final v = validator;
    if (c == null || v == null) {
      return BuildToolResult.failure('canonical/validator not wired');
    }

    final results = <String, dynamic>{};
    final summary = <String, int>{
      'specIssues': 0,
      'wiringIssues': 0,
      'a11yFails': 0,
      'a11yWarns': 0,
      'invalidAssets': 0,
      'undefinedState': 0,
      'unusedState': 0,
      'deadTokens': 0,
    };

    // 1. Spec + wiring validation.
    final validation = await validateBundle();
    if (validation.success) {
      final p = validation.payload;
      if (p != null) {
        try {
          final j = jsonDecode(p) as Map<String, dynamic>;
          summary['specIssues'] = (j['specIssues'] as List?)?.length ?? 0;
          summary['wiringIssues'] = (j['wiringIssues'] as List?)?.length ?? 0;
          results['validation'] = j;
        } catch (_) {}
      }
    }

    // 2. Accessibility audit (app scope).
    final a11y = await a11yAudit();
    if (a11y.success) {
      final p = a11y.payload;
      if (p != null) {
        try {
          final j = jsonDecode(p) as Map<String, dynamic>;
          summary['a11yFails'] = (j['fails'] as int?) ?? 0;
          summary['a11yWarns'] = (j['warns'] as int?) ?? 0;
          results['a11y'] = j;
        } catch (_) {}
      }
    }

    // 3. Asset registry audit (dry-run).
    final assets = await assetAudit();
    if (assets.success) {
      final p = assets.payload;
      if (p != null) {
        try {
          final j = jsonDecode(p) as Map<String, dynamic>;
          summary['invalidAssets'] = (j['invalid'] as List?)?.length ?? 0;
          results['assets'] = j;
        } catch (_) {}
      }
    }

    // 4. Per-page state usage roll-up.
    final pages = (c.currentJson['ui'] as Map?)?['pages'];
    final stateRollup = <String, dynamic>{};
    var totalUndefined = 0;
    var totalUnused = 0;
    if (pages is Map) {
      for (final entry in pages.entries) {
        final id = '${entry.key}';
        final r = await stateUsage(pageId: id);
        if (!r.success) continue;
        final p = r.payload;
        if (p == null) continue;
        try {
          final j = jsonDecode(p) as Map<String, dynamic>;
          final undefined = (j['undefined'] as List?)?.length ?? 0;
          final unused = (j['unused'] as List?)?.length ?? 0;
          totalUndefined += undefined;
          totalUnused += unused;
          if (undefined > 0 || unused > 0) {
            stateRollup[id] = <String, dynamic>{
              'undefined': undefined,
              'unused': unused,
            };
          }
        } catch (_) {}
      }
    }
    summary['undefinedState'] = totalUndefined;
    summary['unusedState'] = totalUnused;
    results['stateByPage'] = stateRollup;

    // 5. Dead theme tokens — defined under /ui/theme/color but no
    // {{theme.color.<role>}} reference anywhere in the canonical.
    final theme = (c.currentJson['ui'] as Map?)?['theme'];
    final colorMap = (theme is Map ? theme['color'] : null);
    final definedColors =
        colorMap is Map ? colorMap.keys.cast<String>().toList() : <String>[];
    final pattern = RegExp(r'\{\{\s*theme\.color\.(\w+)\s*\}\}');
    final usedColors = <String>{};
    void scan(dynamic node) {
      if (node is String) {
        for (final m in pattern.allMatches(node)) {
          usedColors.add(m.group(1)!);
        }
        return;
      }
      if (node is Map) {
        for (final v in node.values) {
          scan(v);
        }
      } else if (node is List) {
        for (final v in node) {
          scan(v);
        }
      }
    }

    scan(c.currentJson['ui']);
    final dead = definedColors.where((r) => !usedColors.contains(r)).toList();
    summary['deadTokens'] = dead.length;
    results['deadColorTokens'] = dead;

    // Roll-up severity. Anything in `fails / specIssues / wiring /
    // invalidAssets / undefinedState` blocks ship; warnings + dead
    // tokens are advisory.
    final blocking =
        (summary['specIssues'] ?? 0) +
        (summary['wiringIssues'] ?? 0) +
        (summary['a11yFails'] ?? 0) +
        (summary['invalidAssets'] ?? 0) +
        (summary['undefinedState'] ?? 0);
    final advisory =
        (summary['a11yWarns'] ?? 0) +
        (summary['unusedState'] ?? 0) +
        (summary['deadTokens'] ?? 0);
    final status = blocking > 0 ? 'fail' : (advisory > 0 ? 'warn' : 'pass');
    return BuildToolResult.success(
      message:
          'health · $status · '
          '${blocking > 0 ? '$blocking blocking · ' : ''}'
          '${advisory > 0 ? '$advisory advisory' : 'all green'}',
      payload: jsonEncode(<String, dynamic>{
        'status': status,
        'summary': summary,
        'details': results,
      }),
    );
  }

  /// Structural diff between the current widget at [path] and a
  /// `candidate` widget map. Returns the RFC-6902 patch ops the
  /// author would need to apply to reach the candidate state, plus
  /// a summary tree (kind ∈ added / removed / modified) keyed by
  /// child pointer for human consumption. Pass `apply:true` to commit
  /// the diff (overwrites the subtree). Pass `relativeToHash` if the
  /// caller wants to assert the comparison anchor.
  Future<BuildToolResult> widgetDiff({
    required String path,
    required Map<String, dynamic> candidate,
    bool apply = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final norm = _normalizePath(path);
    if (norm == null) return BuildToolResult.failure('invalid path: $path');
    final current = _resolvePath(c.currentJson, norm);
    if (current == null && !apply) {
      return BuildToolResult.failure('no current value at $norm');
    }
    final ops = <Map<String, dynamic>>[];
    final summary = <Map<String, dynamic>>[];
    void diff(dynamic a, dynamic b, String pointer) {
      // Treat null current as "all candidate added".
      if (a == null && b != null) {
        ops.add(<String, dynamic>{'op': 'add', 'path': pointer, 'value': b});
        summary.add(<String, dynamic>{'pointer': pointer, 'kind': 'added'});
        return;
      }
      if (a != null && b == null) {
        ops.add(<String, dynamic>{'op': 'remove', 'path': pointer});
        summary.add(<String, dynamic>{'pointer': pointer, 'kind': 'removed'});
        return;
      }
      if (a is Map && b is Map) {
        final keys = <String>{
          ...a.keys.cast<String>(),
          ...b.keys.cast<String>(),
        };
        for (final k in keys) {
          final escaped = k.replaceAll('~', '~0').replaceAll('/', '~1');
          diff(a[k], b[k], '$pointer/$escaped');
        }
        return;
      }
      if (a is List && b is List) {
        final maxLen = a.length > b.length ? a.length : b.length;
        for (var i = 0; i < maxLen; i++) {
          diff(
            i < a.length ? a[i] : null,
            i < b.length ? b[i] : null,
            '$pointer/$i',
          );
        }
        return;
      }
      // Primitive or shape mismatch — replace at this pointer.
      if (jsonEncode(a) == jsonEncode(b)) return;
      ops.add(<String, dynamic>{'op': 'replace', 'path': pointer, 'value': b});
      summary.add(<String, dynamic>{
        'pointer': pointer,
        'kind': 'modified',
        'before': a,
        'after': b,
      });
    }

    diff(current, candidate, norm);
    final added = summary.where((s) => s['kind'] == 'added').length;
    final removed = summary.where((s) => s['kind'] == 'removed').length;
    final modified = summary.where((s) => s['kind'] == 'modified').length;
    final payload = <String, dynamic>{
      'path': norm,
      'opCount': ops.length,
      'added': added,
      'removed': removed,
      'modified': modified,
      'ops': ops,
      'summary': summary,
    };
    if (!apply) {
      return BuildToolResult.success(
        message: '$added added · $removed removed · $modified modified',
        payload: jsonEncode(payload),
      );
    }
    if (ops.isEmpty) {
      return BuildToolResult.success(
        message: 'no changes',
        payload: jsonEncode(payload),
      );
    }
    return _dispatchOps(
      ops: <PatchOp>[
        for (final op in ops)
          PatchOp(
            op: op['op'] as String,
            path: op['path'] as String,
            value: op['value'],
          ),
      ],
      layer: _inferLayer(norm),
      summary:
          'apply diff at $norm '
          '($added/$removed/$modified)',
    );
  }

  /// Lazy-load a topic-focused spec card. Slims the agent prompt by
  /// pulling the heavyweight sections only when the LLM actually
  /// needs them for the task at hand. Topics are stable strings —
  /// the catalog is intentionally short so authors can scan.
  Future<BuildToolResult> specCard({required String topic}) async {
    const cards = <String, String>{
      'phase1_decoration': '''
1.3.4 Phase 1 — Decoration substrate.

Primitives (configs/_primitive/):
  BoxDecoration { color, gradient, image, border, borderRadius,
                  boxShadow, shape, backdropBlur }
  TextStyle    { fontFamily, fontSize, fontWeight, fontStyle,
                  letterSpacing, wordSpacing, height, color,
                  backgroundColor, decoration, decorationColor,
                  shadows, shader, fontFeatures, leadingDistribution,
                  textBaseline, locale }
  BorderRadius { all? · topStart, topEnd, bottomStart, bottomEnd }
  Alignment    'topStart' | 'center' | …  OR  {x, y}
  Gradient     {type: linear|radial|sweep, colors[], stops?, …}
  BoxBorder    {color, width, style} | per-side (top/start/end/bottom)
  BoxShadow    {color, offset:{x,y}, blurRadius, spreadRadius}
  BackgroundImage {src:AssetRef, fit, alignment, opacity,
                  colorFilter, repeat}

Widgets:
  box.decoration:BoxDecoration
  decoration   widget — `decoration:BoxDecoration` OR flat shorthand
                       on every constituent field, child:Widget
  text         style:TextStyle, dropCap:DropCap{lines, glyph?, style?}
  richText     spans:[{text, style, onTap, children?} | {widget,
                       alignment, baseline}]; style:TextStyle, dropCap
  icon         5 forms (bare / codepoint / URL / assets/...svg /
                       data:); shader:Gradient (mutually exclusive
                       with color)
''',
      'phase2_gallery': '''
1.3.4 Phase 2 — Gallery layouts.

  staggeredGrid (since v1.3) — Pinterest masonry. crossAxisCount,
                  mainAxisSpacing, crossAxisSpacing, padding, children
  carousel      (since v1.3) — partial-viewport browser.
                  viewportFraction, loop, autoPlay, autoPlayInterval,
                  transition: slide|fade|coverflow|depth,
                  indicatorPosition: top|bottom|none, children
  pageView      initialPage, loop, scrollPhysics, children,
                  allowImplicitScrolling
  scrollView    children OR slivers (mutually exclusive). slivers
                  ∈ sliverAppBar / sliverPersistentHeader /
                  sliverList / sliverGrid / sliverFixedExtentList
''',
      'phase3_motion': '''
1.3.4 Phase 3 — Motion.

Widgets:
  hero                       (since v1.3) — shared-element wrapper.
                                    tag, child, [flightShuttleBuilder]
  animatedOpacity            opacity, duration, curve, child
  animatedAlign              alignment, duration, curve, child
  animatedPositioned         left/top/right/bottom/width/height,
                                    duration, curve, child
  animatedDefaultTextStyle   style:TextStyle, duration, curve, child
  scrollAnimated             scroll-position-driven; effect, range,
                                    child
  rive                       src:AssetRef, artboard, stateMachines,
                                    fit
  animatedContainer          decoration:BoxDecoration, alignment,
                                    duration, curve:AnimationCurve,
                                    child

Curves (12 named): linear / easeIn / easeOut / easeInOut /
  standard / standardAccelerate / standardDecelerate /
  emphasized / emphasizedAccelerate / emphasizedDecelerate /
  bounceIn / bounceOut

Routes:
  RouteValue { page, transition?:RouteTransition }
  RouteTransition { style: slide|fade|scale|cube|sharedAxis|
                          fadeThrough, duration, curve, axis }
''',
      'phase4_media': '''
1.3.4 Phase 4 — Media.

  kenBurnsImage   (since v1.3) — slow zoom-pan. src:AssetRef,
                                    duration, scaleStart, scaleEnd
  imageFilter     (since v1.3) — color/blur filter on a subtree.
                                    filter ∈ sepia / grayscale /
                                    blur / saturation / brightness /
                                    contrast / invert. amount, child
  lightbox        (since v1.3) — full-screen pinch-zoom modal.
                                    src:AssetRef, child (thumb)
  mediaPlayer     source:AssetRef, poster:AssetRef?,
                                    autoPlay, controls, waveform
                                    (audio mode only), loop
''',
      'phase5_theme_nav': '''
1.3.4 Phase 5 — Theme & nav polish.

Theme:
  /ui/theme/preset  ∈ warm / cool / sepia / mono / highContrast
                       (curated content-app base; other theme.*
                        layered as overrides)
  /ui/theme/fonts   { <family>: { weights:{<value>:AssetRef},
                                  variableAxes:[{tag, min, max,
                                                 default}],
                                  fallbacks:[<family>] } }

Navigation:
  /ui/navigation/style       NavigationStyle (whole surface)
  /ui/navigation/items[i]/style  NavigationStyle (per-item override)

NavigationStyle slots:
  backgroundColor, backgroundImage, indicatorColor, indicatorShape:
  BorderRadius, dividerColor, dividerThickness, dividerIndent,
  labelStyle:TextStyle, iconStyle:{color, size}, selectedColor,
  unselectedColor, elevation
''',
      'primitives': '''
17 cross-cutting primitives (configs/_primitive/) embedded in every
output schema's \$defs:

  AssetRef        Reference: bundle:// / http(s):// / data: /
                  assets/ / client://. NOT material:.
  TextStyle       16 fields — see phase1_decoration.
  BorderRadius    4 directional + all shorthand.
  Alignment       9 directional + numeric {x,y}.
  Dimension       number OR {value, unit}.
  Gradient        linear / radial / sweep discriminator.
  BoxBorder + BorderSide.
  BoxShadow.
  BackgroundImage — see phase1_decoration.
  BoxDecoration — composition.
  Binding         "{{...}}" pattern accepted as alt branch on every
                  primitive — any value may be a binding expression.
  AnimationCurve  12 named (CSS 4 + M3 std 3 + M3 emph 3 + bounce 2).
  RouteTransition  style + duration + curve + axis + reverse.
  NavigationStyle — see phase5_theme_nav.
  Span            TextSpan {text, style, onTap, children} OR
                  WidgetSpan {widget, alignment, baseline}.
  DropCap         lines + glyph override + style.
  Sliver          5 sliver shapes for scrollView.slivers.
''',
      'm3_motion': '''
M3 motion durations + curves (use animation_preset):

  emphasized (hero / page)         500ms · `emphasized`
  standard   (everyday)            300ms · `standard`
  decelerate (incoming elements)   250ms · `emphasizedDecelerate`
  accelerate (outgoing elements)   200ms · `emphasizedAccelerate`

Apply uniformly to a page so motion reads as a single language:
  animation_preset(pageId, kind: emphasized|standard|decelerate|
                                accelerate)

Kinds set duration + curve on every animatedOpacity / animatedAlign
/ animatedPositioned / animatedDefaultTextStyle / animatedContainer
/ scrollAnimated / hero on the page.
''',
    };
    final card = cards[topic];
    if (card == null) {
      return BuildToolResult.failure(
        'unknown topic: $topic. Known: ${cards.keys.join(' / ')}',
      );
    }
    return BuildToolResult.success(
      message: 'spec card · $topic',
      payload: jsonEncode(<String, dynamic>{'topic': topic, 'card': card}),
    );
  }

  /// Apply a Material 3 motion preset to every implicit-animation
  /// widget on a page. Sets `duration` (ms) + `curve` uniformly so
  /// the page reads as one coherent motion language. Kinds (per
  /// M3 motion spec):
  ///   - `emphasized`  500ms · emphasized              (hero / page)
  ///   - `standard`    300ms · standard                (everyday)
  ///   - `decelerate`  250ms · emphasizedDecelerate    (incoming)
  ///   - `accelerate`  200ms · emphasizedAccelerate    (outgoing)
  /// Affected types: animatedOpacity / animatedAlign / animatedPositioned
  /// / animatedDefaultTextStyle / animatedContainer / scrollAnimated /
  /// hero. Pass `dryRun:true` to preview.
  Future<BuildToolResult> animationPreset({
    required String pageId,
    required String kind,
    bool dryRun = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    const presets = <String, Map<String, dynamic>>{
      'emphasized': <String, dynamic>{'duration': 500, 'curve': 'emphasized'},
      'standard': <String, dynamic>{'duration': 300, 'curve': 'standard'},
      'decelerate': <String, dynamic>{
        'duration': 250,
        'curve': 'emphasizedDecelerate',
      },
      'accelerate': <String, dynamic>{
        'duration': 200,
        'curve': 'emphasizedAccelerate',
      },
    };
    final preset = presets[kind];
    if (preset == null) {
      return BuildToolResult.failure(
        'kind must be one of ${presets.keys.join(' / ')}',
      );
    }
    const animatedTypes = <String>{
      'animatedOpacity',
      'animatedAlign',
      'animatedPositioned',
      'animatedDefaultTextStyle',
      'animatedContainer',
      'scrollAnimated',
      'hero',
    };
    final pages = (c.currentJson['ui'] as Map?)?['pages'];
    if (pages is! Map || !pages.containsKey(pageId)) {
      return BuildToolResult.failure('page "$pageId" not found');
    }
    final base = '/ui/pages/$pageId';
    final root = pages[pageId];
    final affected = <Map<String, dynamic>>[];
    final ops = <PatchOp>[];
    void visit(dynamic node, String pointer) {
      if (node is Map && node['type'] is String) {
        final t = node['type'] as String;
        if (animatedTypes.contains(t)) {
          affected.add(<String, dynamic>{'path': pointer, 'type': t});
          for (final entry in preset.entries) {
            ops.add(
              PatchOp(
                op: 'add',
                path: '$pointer/${entry.key}',
                value: entry.value,
              ),
            );
          }
        }
      }
      if (node is Map) {
        for (final entry in node.entries) {
          final key = '${entry.key}';
          final escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
          visit(entry.value, '$pointer/$escaped');
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          visit(node[i], '$pointer/$i');
        }
      }
    }

    visit(root, base);
    if (affected.isEmpty) {
      return BuildToolResult.success(
        message: 'no animated* widgets on page "$pageId"',
        payload: jsonEncode(<String, dynamic>{'affected': []}),
      );
    }
    final summary =
        'animation preset "$kind" applied to '
        '${affected.length} widget'
        '${affected.length == 1 ? '' : 's'} on "$pageId"';
    if (dryRun) {
      return BuildToolResult.success(
        message: 'would apply · $summary',
        payload: jsonEncode(<String, dynamic>{
          'preset': preset,
          'affected': affected,
        }),
      );
    }
    return _dispatchOps(ops: ops, layer: LayerId.pages, summary: summary);
  }

  /// List every reference to a single theme token role. Walks the
  /// canonical, finds string leaves matching `{{theme.<domain>.<role>}}`
  /// (or the bare role inside a `style` map) and returns
  /// `{path, property, expr}` for each. Also returns the role's
  /// current definition (where it's set in `/ui/theme/<domain>/<role>`)
  /// so the LLM can present a "swap & replace" diff. Domain defaults
  /// to `color` — pass `domain: 'spacing'` etc. for non-color tokens.
  Future<BuildToolResult> tokenUsage({
    required String role,
    String domain = 'color',
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final r = role.trim();
    if (r.isEmpty) return BuildToolResult.failure('role required');
    final def = _resolvePath(c.currentJson, '/ui/theme/$domain/$r');
    final exprPattern = RegExp(
      r'\{\{\s*theme\.' + domain + r'\.' + RegExp.escape(r) + r'\s*\}\}',
    );
    final usages = <Map<String, dynamic>>[];
    void walk(
      dynamic node,
      String pointer,
      String? owningWidgetPath,
      String? owningProperty,
    ) {
      if (node is String) {
        if (exprPattern.hasMatch(node)) {
          usages.add(<String, dynamic>{
            'path': pointer,
            if (owningWidgetPath != null) 'widgetPath': owningWidgetPath,
            if (owningProperty != null) 'property': owningProperty,
            'expr': node,
          });
        }
        return;
      }
      if (node is Map) {
        final isWidget = node['type'] is String;
        for (final entry in node.entries) {
          final key = '${entry.key}';
          final escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
          final childPointer = '$pointer/$escaped';
          walk(
            entry.value,
            childPointer,
            isWidget ? pointer : owningWidgetPath,
            isWidget ? key : owningProperty,
          );
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$pointer/$i', owningWidgetPath, owningProperty);
        }
      }
    }

    walk(c.currentJson['ui'], '/ui', null, null);
    return BuildToolResult.success(
      message:
          '${usages.length} usage'
          '${usages.length == 1 ? '' : 's'} of `theme.$domain.$r`',
      payload: jsonEncode(<String, dynamic>{
        'domain': domain,
        'role': r,
        'definition': <String, dynamic>{
          'path': '/ui/theme/$domain/$r',
          'value': def,
        },
        'usages': usages,
      }),
    );
  }

  /// Swap a widget's `type` and transfer compatible properties. Reads
  /// the runtime widget catalog (core's widgets_schema) for the
  /// destination's property keys; only props with matching keys are
  /// kept. Returns `{kept, dropped}` so the LLM can advise the author
  /// on lost data. Pass `dryRun:true` to inspect without mutating.
  Future<BuildToolResult> swapWidget({
    required String path,
    required String newType,
    bool dryRun = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final norm = _normalizePath(path);
    if (norm == null) return BuildToolResult.failure('invalid path: $path');
    final node = _resolvePath(c.currentJson, norm);
    if (node is! Map) {
      return BuildToolResult.failure('no widget at $norm');
    }
    final oldType = node['type'];
    if (oldType is! String) {
      return BuildToolResult.failure('node has no `type`');
    }
    if (oldType == newType) {
      return BuildToolResult.failure('already type "$newType"');
    }
    // Pull target widget's allowed properties from the catalog.
    final cat = WidgetSchemaCatalog.instance;
    if (!cat.knows(newType)) {
      return BuildToolResult.failure('unknown target type: "$newType"');
    }
    final descriptors = cat.propertiesFor(newType);
    final targetProps = descriptors.map((d) => d.name).toSet();
    final source = Map<String, dynamic>.from(node);
    final kept = <String>[];
    final dropped = <Map<String, dynamic>>[];
    final next = <String, dynamic>{'type': newType};
    for (final entry in source.entries) {
      final key = entry.key.toString();
      if (key == 'type') continue;
      if (targetProps.contains(key)) {
        next[key] = entry.value;
        kept.add(key);
      } else {
        dropped.add(<String, dynamic>{'key': key, 'value': entry.value});
      }
    }
    final summaryPayload = <String, dynamic>{
      'path': norm,
      'from': oldType,
      'to': newType,
      'kept': kept,
      'dropped': dropped,
    };
    if (dryRun) {
      return BuildToolResult.success(
        message:
            'swap "$oldType" → "$newType" — '
            '${kept.length} kept · ${dropped.length} dropped',
        payload: jsonEncode(summaryPayload),
      );
    }
    return _dispatchOps(
      ops: <PatchOp>[PatchOp(op: 'replace', path: norm, value: next)],
      layer: _inferLayer(norm),
      summary:
          'swap "$oldType" → "$newType" '
          '(${kept.length} kept, ${dropped.length} dropped)',
    );
  }

  /// Accessibility audit (1.3 §13_Accessibility). Walks the widget
  /// tree and flags issues against WCAG 2.1 AA + Material guidance:
  ///   - touch target < 48dp (button / iconButton without explicit
  ///     constraints meeting min size)
  ///   - text fontSize < 12 (very small body)
  ///   - button without `label` and without `tooltip` (no
  ///     accessible name)
  ///   - icon / iconButton without `semanticLabel` and not inside
  ///     button (no accessible name)
  ///   - image without `semanticLabel` and not decorative
  ///   - linear actionable rows lacking unique labels
  ///   - inputs (textfield / dropdown / checkbox / switch) without
  ///     `label` or `semanticLabel`
  ///   - color contrast not checked here — handled when the runtime
  ///     resolves theme tokens; vibe surfaces a hint instead.
  /// Each finding: `{path, type, severity:warn|fail, rule, message}`.
  /// Read-only; pass `pageId` to scope to one page or omit for app
  /// scope (`/ui`).
  Future<BuildToolResult> a11yAudit({String? pageId}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final json = c.currentJson;
    final ui = json['ui'];
    if (ui is! Map) return BuildToolResult.failure('no /ui in canonical');
    String basePath;
    dynamic root;
    if (pageId != null && pageId.trim().isNotEmpty) {
      final pages = ui['pages'];
      if (pages is! Map || !pages.containsKey(pageId)) {
        return BuildToolResult.failure('page "$pageId" not found');
      }
      basePath = '/ui/pages/$pageId';
      root = pages[pageId];
    } else {
      basePath = '/ui';
      root = ui;
    }
    final findings = <Map<String, dynamic>>[];
    void flag({
      required String path,
      required String type,
      required String severity,
      required String rule,
      required String message,
    }) {
      findings.add(<String, dynamic>{
        'path': path,
        'type': type,
        'severity': severity,
        'rule': rule,
        'message': message,
      });
    }

    bool isBindingOrNonEmpty(dynamic v) => v is String && v.trim().isNotEmpty;

    void visit(dynamic node, String pointer, {bool insideButton = false}) {
      if (node is List) {
        for (var i = 0; i < node.length; i++) {
          visit(node[i], '$pointer/$i', insideButton: insideButton);
        }
        return;
      }
      if (node is! Map) return;
      final t = node['type'];
      if (t is! String) {
        for (final entry in node.entries) {
          final key = entry.key;
          final childPointer =
              '$pointer/'
              '${'$key'.replaceAll('~', '~0').replaceAll('/', '~1')}';
          visit(entry.value, childPointer, insideButton: insideButton);
        }
        return;
      }
      switch (t) {
        case 'button':
        case 'elevatedButton':
        case 'textButton':
        case 'outlinedButton':
        case 'filledButton':
        case 'iconButton':
        case 'floatingActionButton':
          final hasLabel = isBindingOrNonEmpty(node['label']);
          final hasChild = node['child'] is Map;
          final hasTooltip = isBindingOrNonEmpty(node['tooltip']);
          final hasSemantic = isBindingOrNonEmpty(node['semanticLabel']);
          if (!hasLabel &&
              !hasChild &&
              !hasTooltip &&
              !hasSemantic &&
              t != 'iconButton') {
            flag(
              path: pointer,
              type: t,
              severity: 'fail',
              rule: 'button.accessibleName',
              message:
                  'button has no `label` / `tooltip` / `semanticLabel` — '
                  'screen readers will announce the type only.',
            );
          }
          if (t == 'iconButton' && !hasTooltip && !hasSemantic) {
            flag(
              path: pointer,
              type: t,
              severity: 'fail',
              rule: 'iconButton.accessibleName',
              message:
                  'iconButton needs `tooltip` or `semanticLabel` to be '
                  'accessible.',
            );
          }
          // Touch target: explicit width/height or padding ≥ 48dp.
          final w = node['width'];
          final h = node['height'];
          final size = node['size'];
          final small = (w is num && w < 48) || (h is num && h < 48);
          if (small || size == 'small') {
            flag(
              path: pointer,
              type: t,
              severity: 'warn',
              rule: 'touchTarget.minSize',
              message:
                  'touch target appears < 48dp — recommend '
                  'width/height ≥ 48 (M3 §interaction).',
            );
          }
          // Recurse children with the "insideButton" hint.
          for (final entry in node.entries) {
            if (entry.key == 'child' || entry.key == 'children') {
              final childPointer = '$pointer/${entry.key}';
              visit(entry.value, childPointer, insideButton: true);
            }
          }
          break;
        case 'text':
          final style = node['style'];
          final fontSize =
              (style is Map ? style['fontSize'] : null) ?? node['fontSize'];
          if (fontSize is num && fontSize < 12) {
            flag(
              path: pointer,
              type: t,
              severity: 'warn',
              rule: 'text.minFontSize',
              message:
                  'fontSize $fontSize < 12 — body text below 12dp '
                  'fails WCAG 2.1 AA readability for many users.',
            );
          }
          break;
        case 'icon':
          if (!insideButton &&
              !isBindingOrNonEmpty(node['semanticLabel']) &&
              node['decorative'] != true) {
            flag(
              path: pointer,
              type: t,
              severity: 'warn',
              rule: 'icon.accessibleName',
              message:
                  'icon outside an accessible parent has no '
                  '`semanticLabel` — set one or mark `decorative: '
                  'true` if purely visual.',
            );
          }
          break;
        case 'image':
        case 'kenBurnsImage':
          if (!isBindingOrNonEmpty(node['semanticLabel']) &&
              node['decorative'] != true) {
            flag(
              path: pointer,
              type: t,
              severity: 'warn',
              rule: 'image.accessibleName',
              message:
                  'image has no `semanticLabel` — set one (alt text) '
                  'or mark `decorative: true`.',
            );
          }
          break;
        case 'textfield':
        case 'dropdown':
        case 'dropdownButton':
        case 'datePicker':
        case 'dateRangePicker':
          if (!isBindingOrNonEmpty(node['label']) &&
              !isBindingOrNonEmpty(node['hint']) &&
              !isBindingOrNonEmpty(node['semanticLabel'])) {
            flag(
              path: pointer,
              type: t,
              severity: 'fail',
              rule: 'input.accessibleName',
              message:
                  'input has no `label` / `hint` / `semanticLabel` '
                  '— users cannot identify its purpose.',
            );
          }
          break;
        case 'checkbox':
        case 'switch':
        case 'radio':
          if (!isBindingOrNonEmpty(node['label']) &&
              !isBindingOrNonEmpty(node['semanticLabel'])) {
            flag(
              path: pointer,
              type: t,
              severity: 'fail',
              rule: 'toggle.accessibleName',
              message:
                  'toggle has no `label` / `semanticLabel` — users '
                  'cannot tell what it controls.',
            );
          }
          break;
      }
      // Generic recursion.
      for (final entry in node.entries) {
        final key = entry.key;
        if (key == 'type') continue;
        final childPointer =
            '$pointer/'
            '${'$key'.replaceAll('~', '~0').replaceAll('/', '~1')}';
        visit(entry.value, childPointer, insideButton: insideButton);
      }
    }

    visit(root, basePath);
    final fails = findings.where((f) => f['severity'] == 'fail').length;
    final warns = findings.where((f) => f['severity'] == 'warn').length;
    return BuildToolResult.success(
      message: 'a11y · $fails fail · $warns warn',
      payload: jsonEncode(<String, dynamic>{
        'scope': basePath,
        'fails': fails,
        'warns': warns,
        'findings': findings,
      }),
    );
  }

  /// Walk a page's widget tree, lift every literal `text` widget
  /// `content` (and `richText` plain spans) into `/ui/i18n/text/
  /// [locale]` as a key, and rewrite the widget property to a
  /// `{{i18n.text.[key]}}` binding. Returns the synthesized key list;
  /// pass `dryRun:true` to preview without applying. Author can also
  /// pass an explicit `keyPrefix` (default = pageId).
  ///
  /// Bindings in the original content are left untouched — only
  /// literal strings are extracted. Identical strings collapse to
  /// the same key (deduplication).
  Future<BuildToolResult> extractI18n({
    required String pageId,
    String? locale,
    String? keyPrefix,
    bool dryRun = false,
  }) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final json = c.currentJson;
    final ui = json['ui'];
    if (ui is! Map) return BuildToolResult.failure('no /ui in canonical');
    final pages = ui['pages'];
    if (pages is! Map || !pages.containsKey(pageId)) {
      return BuildToolResult.failure('page "$pageId" not found');
    }
    final loc =
        locale?.trim().isNotEmpty == true
            ? locale!.trim()
            : (ui['i18n']?['defaultLocale'] as String?) ?? 'en';
    if (!RegExp(r'^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$').hasMatch(loc)) {
      return BuildToolResult.failure(
        'locale must be BCP-47 (resolved: "$loc")',
      );
    }
    final prefix = (keyPrefix?.trim().isNotEmpty == true
            ? keyPrefix!.trim()
            : pageId)
        .replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
    final pagePath = '/ui/pages/$pageId';
    final pageRoot = pages[pageId];
    final extractions = <Map<String, dynamic>>[];
    // Map literal value → i18n key (dedup).
    final byValue = <String, String>{};
    int counter = 0;
    String nextKey() {
      counter++;
      return '$prefix.text$counter';
    }

    bool isBinding(String s) => s.contains(RegExp(r'\{\{.*?\}\}'));

    void walk(dynamic node, String pointer) {
      if (node is Map) {
        if (node['type'] == 'text' && node['content'] is String) {
          final raw = node['content'] as String;
          if (raw.trim().isNotEmpty && !isBinding(raw)) {
            final key = byValue.putIfAbsent(raw, nextKey);
            extractions.add(<String, dynamic>{
              'pointer': '$pointer/content',
              'key': key,
              'value': raw,
            });
          }
        } else if (node['type'] == 'button' && node['label'] is String) {
          final raw = node['label'] as String;
          if (raw.trim().isNotEmpty && !isBinding(raw)) {
            final key = byValue.putIfAbsent(raw, nextKey);
            extractions.add(<String, dynamic>{
              'pointer': '$pointer/label',
              'key': key,
              'value': raw,
            });
          }
        }
        for (final entry in node.entries) {
          final key = entry.key;
          final v = entry.value;
          final childPointer =
              '$pointer/'
              '${'$key'.replaceAll('~', '~0').replaceAll('/', '~1')}';
          walk(v, childPointer);
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$pointer/$i');
        }
      }
    }

    walk(pageRoot, pagePath);

    if (extractions.isEmpty) {
      return BuildToolResult.success(
        message: 'no extractable strings on page "$pageId"',
        payload: jsonEncode(<String, dynamic>{'extractions': []}),
      );
    }
    final payload = <String, dynamic>{
      'pageId': pageId,
      'locale': loc,
      'keyPrefix': prefix,
      'extractions': extractions,
      'uniqueKeys': byValue.length,
    };
    if (dryRun) {
      return BuildToolResult.success(
        message:
            '${extractions.length} string'
            '${extractions.length == 1 ? '' : 's'} would extract '
            '(${byValue.length} unique key'
            '${byValue.length == 1 ? '' : 's'})',
        payload: jsonEncode(payload),
      );
    }
    final ops = <PatchOp>[];
    // Add i18n.text.<locale>.<key> entries (escape RFC 6901).
    String escape(String s) => s.replaceAll('~', '~0').replaceAll('/', '~1');
    for (final entry in byValue.entries) {
      ops.add(
        PatchOp(
          op: 'add',
          path: '/ui/i18n/text/$loc/${escape(entry.value)}',
          value: entry.key,
        ),
      );
    }
    // Replace widget content with binding. extractions list may have
    // duplicates collapsing to same key — dispatch each anyway, the
    // patch pipeline tolerates idempotent set.
    for (final ext in extractions) {
      final key = ext['key'] as String;
      ops.add(
        PatchOp(
          op: 'replace',
          path: ext['pointer'] as String,
          value: '{{i18n.text.$key}}',
        ),
      );
    }
    return _dispatchOps(
      ops: ops,
      layer: LayerId.pages,
      summary:
          'extract i18n on "$pageId" — '
          '${byValue.length} key'
          '${byValue.length == 1 ? '' : 's'} '
          '+ ${extractions.length} ref'
          '${extractions.length == 1 ? '' : 's'}',
    );
  }

  /// Audit `/manifest/assets` for entries whose `contentRef` does not
  /// match the AssetRef spec (configs/_primitive/AssetRef.yaml — five
  /// schemes: `bundle://`, `https?://`, `data:`, `assets/`,
  /// `client://`). Pre-1.3.4 projects sometimes carry `material:<name>`
  /// entries (treated as informational icon hints). Returns a list of
  /// findings; pass `apply:true` to migrate — invalid entries become
  /// the bare ref where derivable (Material name extracted) or get
  /// removed, and widget `bundle://<id>` references that resolved to
  /// such entries are rewritten to the resolved value.
  Future<BuildToolResult> assetAudit({bool apply = false}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final json = c.currentJson;
    final assets = (json['manifest'] as Map?)?['assets'];
    final list = assets is Map ? assets['assets'] : null;
    final entries =
        list is List
            ? list
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList()
            : <Map<String, dynamic>>[];
    final pattern = RegExp(r'^(bundle://|https?://|data:|assets/|client://)');
    final invalid = <Map<String, dynamic>>[];
    final replacements = <String, String>{}; // bundle://id → resolved ref
    for (final e in entries) {
      final id = '${e['id'] ?? ''}';
      final ref = e['contentRef'];
      final path = e['path'];
      if (path is String && path.isNotEmpty) continue; // file-backed OK
      if (ref is String && pattern.hasMatch(ref)) continue; // valid scheme
      // Invalid contentRef. If material:<name>, derive bare name.
      String? resolved;
      if (ref is String && ref.startsWith('material:')) {
        resolved = ref.substring('material:'.length);
      }
      invalid.add(<String, dynamic>{
        'id': id,
        'contentRef': ref,
        'resolvedAs': resolved,
        'reason':
            resolved != null
                ? 'material: prefix is informational, not an AssetRef'
                : 'contentRef does not match AssetRef pattern',
      });
      if (id.isNotEmpty && resolved != null) {
        replacements['bundle://$id'] = resolved;
      }
    }
    if (!apply) {
      return BuildToolResult.success(
        message:
            '${invalid.length} invalid asset entr'
            '${invalid.length == 1 ? 'y' : 'ies'}',
        payload: jsonEncode(<String, dynamic>{
          'invalid': invalid,
          'wouldRemoveCount': invalid.length,
          'wouldRewriteWidgetRefs': replacements,
        }),
      );
    }
    if (invalid.isEmpty) {
      return BuildToolResult.success(
        message: 'no invalid entries — nothing to migrate',
        payload: jsonEncode(<String, dynamic>{'invalid': []}),
      );
    }
    // Build new asset list (drop invalid).
    final invalidIds =
        invalid.map((e) => '${e['id']}').where((id) => id.isNotEmpty).toSet();
    final newAssets =
        entries.where((e) => !invalidIds.contains('${e['id'] ?? ''}')).toList();
    // Walk widgets, rewrite bundle://<id> → resolved.
    final ops = <PatchOp>[];
    void walk(dynamic node, String pointer) {
      if (node is Map) {
        for (final entry in node.entries) {
          final key = entry.key;
          final v = entry.value;
          final childPointer =
              '$pointer/'
              '${'$key'.replaceAll('~', '~0').replaceAll('/', '~1')}';
          if (v is String && replacements.containsKey(v)) {
            ops.add(
              PatchOp(
                op: 'replace',
                path: childPointer,
                value: replacements[v],
              ),
            );
          } else {
            walk(v, childPointer);
          }
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          final v = node[i];
          final childPointer = '$pointer/$i';
          if (v is String && replacements.containsKey(v)) {
            ops.add(
              PatchOp(
                op: 'replace',
                path: childPointer,
                value: replacements[v],
              ),
            );
          } else {
            walk(v, childPointer);
          }
        }
      }
    }

    walk(json['ui'], '/ui');
    ops.add(
      PatchOp(op: 'replace', path: '/manifest/assets/assets', value: newAssets),
    );
    return _dispatchOps(
      ops: ops,
      layer: LayerId.assets,
      summary:
          'asset audit · '
          '${invalidIds.length} entries removed, '
          '${ops.length - 1} widget refs rewritten',
    );
  }

  /// Set NavigationStyle slots under `/ui/navigation/style`. Pass
  /// either `slot`+`value` to upsert one field, or `style` to fully
  /// replace the style object. Slot must be a known
  /// NavigationStyle key (1.3.4 §05_Theme.md).
  Future<BuildToolResult> navigationStyleSet({
    String? slot,
    dynamic value,
    Map<String, dynamic>? style,
  }) async {
    const knownSlots = <String>{
      'backgroundColor',
      'backgroundImage',
      'indicatorColor',
      'indicatorShape',
      'dividerColor',
      'dividerThickness',
      'dividerIndent',
      'labelStyle',
      'iconStyle',
      'selectedColor',
      'unselectedColor',
      'elevation',
    };
    if (style != null) {
      return _applySingleOp(
        op: 'add',
        path: '/ui/navigation/style',
        value: style,
        summary: 'replace navigation style',
      );
    }
    final slotName = (slot ?? '').trim();
    if (slotName.isEmpty) {
      return BuildToolResult.failure('provide `slot`+`value` or `style`');
    }
    // Allow nested keys via dotted form (e.g. `iconStyle.color`).
    final head = slotName.split('.').first;
    if (!knownSlots.contains(head)) {
      return BuildToolResult.failure(
        'unknown slot "$slotName". Known: ${knownSlots.join(', ')}',
      );
    }
    final pointer = slotName.split('.').join('/');
    return _applySingleOp(
      op: value == null ? 'remove' : 'add',
      path: '/ui/navigation/style/$pointer',
      value: value,
      summary:
          value == null
              ? 'clear navigation style "$slotName"'
              : 'set navigation style "$slotName"',
    );
  }

  /// Full bundle validation. Runs the SpecValidator (manifest / app /
  /// theme / pages / templates JSON-Schema) and the `check_wiring`
  /// pass in one call. Aggregates issues by category — `specIssues`
  /// (schema violations) and `wiringIssues` (orphans / undefined refs
  /// / unused templates / undefined state). Run before save / build.
  Future<BuildToolResult> validateBundle() async {
    final c = canonical;
    final v = validator;
    if (c == null || v == null) {
      return BuildToolResult.failure('canonical/validator not wired');
    }
    final specIssues = v.validateFull(c.current);
    final wiringRes = await checkWiring();
    List<dynamic> wiringIssues = const <dynamic>[];
    if (wiringRes.success && wiringRes.payload != null) {
      try {
        final decoded = jsonDecode(wiringRes.payload!);
        if (decoded is Map && decoded['issues'] is List) {
          wiringIssues = decoded['issues'] as List;
        }
      } catch (_) {
        /* ignore — fall through with empty list */
      }
    }
    return BuildToolResult.success(
      message: 'spec=${specIssues.length} wiring=${wiringIssues.length}',
      payload: jsonEncode(<String, dynamic>{
        'specIssues': specIssues
            .map(
              (i) => <String, dynamic>{
                'level': i.severity.name,
                'code': i.code,
                'path': i.pointer ?? '',
                'message': i.message,
              },
            )
            .toList(growable: false),
        'wiringIssues': wiringIssues,
      }),
    );
  }

  /// Per-page state audit. Returns a key-by-key breakdown:
  /// - which state keys are declared (in `/ui/pages/<id>/state`)
  /// - which widgets bind each one (path + form of reference)
  /// - resulting `unused` (declared but never referenced) and
  ///   `undefined` (referenced but not declared) lists.
  /// Complements `check_wiring` (which surfaces only `undefined` at
  /// the bundle level).
  Future<BuildToolResult> stateUsage({required String pageId}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final id = pageId.trim();
    if (id.isEmpty) return BuildToolResult.failure('pageId required');
    final root = c.currentJson;
    final ui = root['ui'];
    final pages = ui is Map ? ui['pages'] : null;
    if (pages is! Map || !pages.containsKey(id)) {
      return BuildToolResult.failure('page "$id" not found');
    }
    final page = pages[id];
    if (page is! Map) {
      return BuildToolResult.failure('page "$id" malformed');
    }

    final declared = <String>{};
    final state = page['state'];
    if (state is Map) {
      for (final k in state.keys) {
        declared.add(k.toString());
      }
    }

    final refsByKey = <String, List<Map<String, dynamic>>>{};
    void addRef(String key, String path, String kind, String expr) {
      if (key.isEmpty) return;
      refsByKey.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(
        <String, dynamic>{'path': path, 'kind': kind, 'expr': expr},
      );
    }

    final atRe = RegExp(r'@\{\s*state\.([\w.]+)\s*\}');
    final muRe = RegExp(r'\{\{\s*state\.([\w.]+)\s*\}\}');
    _walkAll(page, '/ui/pages/$id', (n, path) {
      if (n is String) {
        for (final m in atRe.allMatches(n)) {
          addRef(m.group(1)!.split('.').first, path, 'binding', m.group(0)!);
        }
        for (final m in muRe.allMatches(n)) {
          addRef(m.group(1)!.split('.').first, path, 'binding', m.group(0)!);
        }
      }
      if (n is Map && n['type'] == 'state') {
        final binding = n['binding'];
        if (binding is String && binding.isNotEmpty) {
          addRef(binding.split('.').first, path, 'action', 'binding=$binding');
        }
      }
    });

    final allKeys = <String>{...declared, ...refsByKey.keys}.toList()..sort();
    final keys = allKeys
        .map(
          (k) => <String, dynamic>{
            'key': k,
            'declared': declared.contains(k),
            'refs': refsByKey[k] ?? const <Object?>[],
          },
        )
        .toList(growable: false);

    final unused =
        declared.where((k) => !refsByKey.containsKey(k)).toList()..sort();
    final undefined =
        refsByKey.keys.where((k) => !declared.contains(k)).toList()..sort();

    return BuildToolResult.success(
      message:
          'state usage for "$id" '
          '(${declared.length} declared, ${refsByKey.length} referenced)',
      payload: jsonEncode(<String, dynamic>{
        'page': id,
        'keys': keys,
        'summary': <String, dynamic>{
          'totalDeclared': declared.length,
          'totalReferenced': refsByKey.length,
          'unused': unused,
          'undefined': undefined,
        },
      }),
    );
  }

  /// What does a widget subtree depend on? Returns:
  ///   - `stateKeys`     state.X bindings the subtree reads / writes
  ///   - `templateUses`  template ids referenced via `use`
  ///   - `routes`        navigate / route action targets
  ///   - `externalRefs`  any other `@{...}` references not under
  ///                     `state.` / `props.` (theme tokens, custom
  ///                     extension namespaces, …)
  /// Run before deleting or moving a widget to spot what would
  /// break.
  Future<BuildToolResult> bindingDependencies({required String path}) async {
    final c = canonical;
    if (c == null) return BuildToolResult.failure('canonical not wired');
    final norm = _normalizePath(path);
    if (norm == null) return BuildToolResult.failure('invalid path');
    final widget = _resolvePath(c.currentJson, norm);
    if (widget is! Map) {
      return BuildToolResult.failure('widget not found at $norm');
    }

    final stateKeys = <String>{};
    final templateUses = <String>{};
    final routes = <String>{};
    final externalRefs = <String>{};

    final atRe = RegExp(r'@\{\s*([\w.]+)\s*\}');
    final muRe = RegExp(r'\{\{\s*([\w.]+)\s*\}\}');
    void scanString(String s) {
      for (final m in atRe.allMatches(s)) {
        final ref = m.group(1)!;
        if (ref.startsWith('state.')) {
          stateKeys.add(ref.substring(6).split('.').first);
        } else if (!ref.startsWith('props.')) {
          externalRefs.add(ref);
        }
      }
      for (final m in muRe.allMatches(s)) {
        final ref = m.group(1)!;
        if (ref.startsWith('state.')) {
          stateKeys.add(ref.substring(6).split('.').first);
        } else if (!ref.startsWith('props.')) {
          externalRefs.add(ref);
        }
      }
    }

    _walkAll(widget, norm, (n, _) {
      if (n is String) scanString(n);
      if (n is Map) {
        if (n['type'] == 'use' && n['template'] is String) {
          templateUses.add(n['template'] as String);
        }
        if (n['type'] == 'navigate' || n['type'] == 'route') {
          final r = n['route'] ?? n['to'] ?? n['target'];
          if (r is String && r.isNotEmpty) routes.add(r);
        }
        if (n['type'] == 'state' && n['binding'] is String) {
          stateKeys.add((n['binding'] as String).split('.').first);
        }
      }
    });

    return BuildToolResult.success(
      message: 'dependencies of $norm',
      payload: jsonEncode(<String, dynamic>{
        'path': norm,
        'stateKeys': (stateKeys.toList()..sort()),
        'templateUses': (templateUses.toList()..sort()),
        'routes': (routes.toList()..sort()),
        'externalRefs': (externalRefs.toList()..sort()),
      }),
    );
  }

  /// Pick a widget subtree, define it as a `/ui/templates/<id>`, and
  /// replace the original location with a `use` widget pointing at the
  /// new template — atomically. Lets the LLM DRY a repeated card /
  /// row / form snippet without juggling three separate patches.
  Future<BuildToolResult> extractTemplate({
    required String widgetPath,
    required String templateId,
  }) async {
    final c = canonical;
    if (c == null || pipeline == null) {
      return BuildToolResult.failure('canonical/pipeline not wired');
    }
    final norm = _normalizePath(widgetPath);
    if (norm == null) return BuildToolResult.failure('invalid widgetPath');
    final tplId = templateId.trim();
    if (tplId.isEmpty) return BuildToolResult.failure('templateId required');

    final root = c.currentJson;
    final widget = _resolvePath(root, norm);
    if (widget is! Map) {
      return BuildToolResult.failure('widget not found at $norm');
    }
    final ui = root['ui'];
    final templates = ui is Map ? ui['templates'] : null;
    if (templates is Map && templates.containsKey(tplId)) {
      return BuildToolResult.failure('template "$tplId" already exists');
    }
    // Deep-copy the subtree so the new template doesn't alias the
    // original tree (the canonical _deepCopyMap during applyAtomic
    // takes care of the apply side, but we want to be defensive
    // about local mutation of `widget`).
    final widgetCopy = jsonDecode(jsonEncode(widget));
    final ops = <PatchOp>[
      PatchOp(
        op: 'add',
        path: '/ui/templates/${_keyToPointer(tplId)}',
        value: <String, dynamic>{'content': widgetCopy},
      ),
      PatchOp(
        op: 'replace',
        path: norm,
        value: <String, dynamic>{'type': 'use', 'template': tplId},
      ),
    ];
    return _dispatchOps(
      ops: ops,
      layer: LayerId.appStructure,
      summary: 'extract template "$tplId" from $norm',
    );
  }

  /// Inverse of `extract_template` — expand a `use` widget back into
  /// its template content at the same location. When the use widget
  /// has `props`, `@{props.X}` bindings inside the template content
  /// are substituted with the literal prop values during inlining.
  Future<BuildToolResult> inlineTemplate({required String usePath}) async {
    final c = canonical;
    if (c == null || pipeline == null) {
      return BuildToolResult.failure('canonical/pipeline not wired');
    }
    final norm = _normalizePath(usePath);
    if (norm == null) return BuildToolResult.failure('invalid usePath');

    final root = c.currentJson;
    final useWidget = _resolvePath(root, norm);
    if (useWidget is! Map) {
      return BuildToolResult.failure('not found at $norm');
    }
    if (useWidget['type'] != 'use') {
      return BuildToolResult.failure(
        'not a use widget at $norm: type=${useWidget['type']}',
      );
    }
    final tplId = useWidget['template'];
    if (tplId is! String || tplId.isEmpty) {
      return BuildToolResult.failure('use widget missing template id');
    }
    final ui = root['ui'];
    final templates = ui is Map ? ui['templates'] : null;
    if (templates is! Map || !templates.containsKey(tplId)) {
      return BuildToolResult.failure('template "$tplId" not found');
    }
    final tplDef = templates[tplId];
    if (tplDef is! Map) {
      return BuildToolResult.failure('template "$tplId" malformed');
    }
    final content = tplDef['content'];
    if (content == null) {
      return BuildToolResult.failure('template "$tplId" has no content');
    }
    final props = useWidget['props'];
    final inlined =
        props is Map
            ? _substituteProps(jsonDecode(jsonEncode(content)), props)
            : jsonDecode(jsonEncode(content));
    return _applySingleOp(
      op: 'replace',
      path: norm,
      value: inlined,
      summary: 'inline template "$tplId" at $norm',
    );
  }

  /// Walk [node] and replace every `@{props.X}` token in any string
  /// with the literal value from [props] (dot-path resolved). Tokens
  /// whose key is not in [props] are left as-is.
  static dynamic _substituteProps(dynamic node, Map props) {
    if (node is String) {
      return node.replaceAllMapped(RegExp(r'@\{\s*props\.([\w.]+)\s*\}'), (m) {
        final key = m.group(1)!;
        dynamic v = props;
        for (final seg in key.split('.')) {
          if (v is Map && v.containsKey(seg)) {
            v = v[seg];
          } else {
            return m.group(0)!;
          }
        }
        return v.toString();
      });
    }
    if (node is Map) {
      return node.map(
        (k, v) => MapEntry(k.toString(), _substituteProps(v, props)),
      );
    }
    if (node is List) {
      return node.map((e) => _substituteProps(e, props)).toList();
    }
    return node;
  }

  /// Deep-copy a page and (optionally) wire a new route to it. Atomic
  /// — both the new page entry and the route addition land in one
  /// patch so a failure rolls back cleanly.
  Future<BuildToolResult> duplicatePage({
    required String srcId,
    required String newId,
    String? route,
  }) async {
    final c = canonical;
    if (c == null || pipeline == null) {
      return BuildToolResult.failure('canonical/pipeline not wired');
    }
    final src = srcId.trim();
    final dst = newId.trim();
    if (src.isEmpty || dst.isEmpty) {
      return BuildToolResult.failure('srcId / newId required');
    }
    if (src == dst) return BuildToolResult.failure('srcId equals newId');
    final root = c.currentJson;
    final ui = root['ui'];
    final pages = ui is Map ? ui['pages'] : null;
    if (pages is! Map) {
      return BuildToolResult.failure('/ui/pages is not a map');
    }
    if (!pages.containsKey(src)) {
      return BuildToolResult.failure('page "$src" not found');
    }
    if (pages.containsKey(dst)) {
      return BuildToolResult.failure('page "$dst" already exists');
    }
    final routes = ui['routes'];
    final routeKey = route?.trim() ?? '';
    if (routeKey.isNotEmpty && routes is Map && routes.containsKey(routeKey)) {
      return BuildToolResult.failure(
        'route "$routeKey" already exists; pick a different path '
        'or omit the `route` arg to add the page without wiring',
      );
    }
    final copy = jsonDecode(jsonEncode(pages[src]));
    final ops = <PatchOp>[
      PatchOp(op: 'add', path: '/ui/pages/${_keyToPointer(dst)}', value: copy),
    ];
    if (routeKey.isNotEmpty) {
      ops.add(
        PatchOp(
          op: 'add',
          path: '/ui/routes/${_keyToPointer(routeKey)}',
          value: dst,
        ),
      );
    }
    return _dispatchOps(
      ops: ops,
      layer: LayerId.appStructure,
      summary:
          'duplicate page "$src" → "$dst"'
          '${routeKey.isEmpty ? '' : ' wired to $routeKey'}',
    );
  }

  /// True when [needle] appears in any string value reachable from
  /// [widget]'s direct properties — but stopping at widget
  /// boundaries (descendants with a `type` String). Lets find_widgets
  /// emit only the leaf widget that actually carries the reference,
  /// not every ancestor in its chain.
  static bool _refersInOwnProps(Map widget, String needle) {
    var found = false;
    void scan(dynamic node, {bool atRoot = false}) {
      if (found) return;
      if (node is String) {
        if (node.contains(needle)) found = true;
        return;
      }
      if (node is Map) {
        if (!atRoot && node['type'] is String) return; // hit another widget
        for (final v in node.values) {
          scan(v);
          if (found) return;
        }
      } else if (node is List) {
        for (final el in node) {
          scan(el);
          if (found) return;
        }
      }
    }

    scan(widget, atRoot: true);
    return found;
  }

  /// Recursive Map / List walk visiting every node (not just widgets).
  /// Path is RFC 6901-escaped per segment so callers can hand the
  /// emitted path back to mutation tools without a re-encode step.
  static void _walkAll(
    dynamic node,
    String path,
    void Function(dynamic node, String path) visit,
  ) {
    visit(node, path);
    if (node is Map) {
      for (final entry in node.entries) {
        final keyStr = entry.key.toString();
        final escaped = keyStr.replaceAll('~', '~0').replaceAll('/', '~1');
        _walkAll(entry.value, '$path/$escaped', visit);
      }
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        _walkAll(node[i], '$path/$i', visit);
      }
    }
  }

  /// Replace an entire widget subtree with a new widget. Use this
  /// when the structural change is too big for set_property (changing
  /// the root widget type, swapping a card for a linear, etc.).
  Future<BuildToolResult> replaceSubtree({
    required String path,
    required Map<String, dynamic> widget,
  }) async {
    final norm = _normalizePath(path);
    if (norm == null) return BuildToolResult.failure('invalid path: $path');
    final destructive = _destructiveCheck(norm, widget);
    if (destructive != null) {
      return BuildToolResult.failure(
        'destructive replace blocked — $destructive. The new '
        'subtree must preserve at least most of the existing '
        'widget count. To genuinely shrink a subtree, '
        'delete_widget the obsolete branches first, then '
        'add_child the new ones.',
        path: norm,
      );
    }
    return _applySingleOp(
      op: 'replace',
      path: norm,
      value: widget,
      summary: 'replace subtree at $norm',
    );
  }

  Future<BuildToolResult> _applySingleOp({
    required String op,
    required String path,
    required dynamic value,
    required String summary,
  }) async {
    return _dispatchOps(
      ops: <PatchOp>[
        PatchOp(op: op, path: path, value: op == 'remove' ? null : value),
      ],
      layer: _inferLayer(path),
      summary: summary,
    );
  }

  Future<BuildToolResult> _dispatchOps({
    required List<PatchOp> ops,
    required LayerId layer,
    required String summary,
  }) async {
    final pl = pipeline;
    if (pl == null) return BuildToolResult.failure('pipeline not wired');
    try {
      final result = await pl.apply(
        CanonicalPatch(
          layer: layer,
          ops: ops,
          originator: const LlmOriginator(turnId: 'semantic'),
        ),
      );
      if (result is! PatchApplied) {
        final rejected = result as PatchRejected;
        final reason =
            rejected.report.errors.isNotEmpty
                ? rejected.report.errors.first.message
                : 'pipeline rejected';
        return BuildToolResult.failure('rejected: $reason');
      }
      return BuildToolResult.success(
        message: summary,
        payload: jsonEncode(<String, dynamic>{
          'layer': layer.name,
          'ops': ops.length,
          'hash': result.afterHash,
        }),
      );
    } catch (e) {
      return BuildToolResult.failure('apply failed: $e');
    }
  }

  /// Coerce LLM-supplied paths to a canonical leading-slash form.
  /// Returns null when the path is empty or contains a `..` segment.
  static String? _normalizePath(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final withSlash = trimmed.startsWith('/') ? trimmed : '/$trimmed';
    if (withSlash.contains('/../') || withSlash.endsWith('/..')) return null;
    // Strip trailing slash unless root.
    return withSlash.length > 1 && withSlash.endsWith('/')
        ? withSlash.substring(0, withSlash.length - 1)
        : withSlash;
  }

  static dynamic _resolvePath(Map<String, dynamic> root, String path) {
    if (path == '/' || path.isEmpty) return root;
    final segs = (path.startsWith('/')
            ? path.substring(1).split('/')
            : path.split('/'))
        .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
        .toList(growable: false);
    dynamic node = root;
    for (final seg in segs) {
      if (node is Map) {
        if (!node.containsKey(seg)) return null;
        node = node[seg];
      } else if (node is List) {
        final i = int.tryParse(seg);
        if (i == null || i < 0 || i >= node.length) return null;
        node = node[i];
      } else {
        return null;
      }
    }
    return node;
  }

  static LayerId _inferLayer(String path) {
    if (path.startsWith('/manifest/assets')) return LayerId.assets;
    if (path.startsWith('/ui/pages')) return LayerId.pages;
    if (path.startsWith('/ui/theme')) return LayerId.theme;
    if (path.startsWith('/ui/components') || path.startsWith('/ui/templates')) {
      return LayerId.components;
    }
    if (path.startsWith('/ui/dashboard')) return LayerId.dashboard;
    if (path.startsWith('/ui/navigation')) return LayerId.navigation;
    if (path.startsWith('/ui')) return LayerId.appStructure;
    return LayerId.whole;
  }

  /// Pick the most user-readable label out of a widget node.
  static String? _label(Map node) {
    for (final k in const <String>[
      'id',
      'key',
      'text',
      'label',
      'title',
      'name',
    ]) {
      final v = node[k];
      if (v is String && v.trim().isNotEmpty) {
        return v.length > 60 ? '${v.substring(0, 57)}…' : v;
      }
    }
    return null;
  }

  /// Recursive widget walk. Descends only into Maps that look like
  /// widgets (have a String `type` field) and Lists whose elements
  /// look like widgets — skips style/state/data/binding maps.
  static void _walkWidgets(
    dynamic node,
    String path,
    int depth,
    List<Map<String, dynamic>> out, {
    int limit = 300,
  }) {
    if (out.length >= limit) return;
    if (node is Map) {
      final type = node['type'];
      if (type is String) {
        final entry = <String, dynamic>{
          'path': path,
          'type': type,
          'depth': depth,
        };
        final label = _label(node);
        if (label != null) entry['label'] = label;
        // Cheap children probe — lets the LLM skip getWidget when the
        // outline already shows the slot is empty.
        final hasChildren =
            node['children'] is List ||
            node['child'] is Map ||
            node['content'] is Map ||
            node['body'] is Map;
        if (hasChildren) entry['hasChildren'] = true;
        out.add(entry);
      }
      for (final entry in node.entries) {
        if (out.length >= limit) return;
        final v = entry.value;
        final childPath = '$path/${entry.key}';
        if (v is Map && v['type'] is String) {
          _walkWidgets(v, childPath, depth + 1, out, limit: limit);
        } else if (v is List) {
          for (var i = 0; i < v.length; i++) {
            final el = v[i];
            if (el is Map && el['type'] is String) {
              _walkWidgets(el, '$childPath/$i', depth + 1, out, limit: limit);
            }
          }
        } else if (v is Map) {
          // The map is a non-widget container (theme, state, …) that
          // may still nest widgets — descend without emitting an entry
          // for the container itself. Keeps the outline scoped to
          // real widgets while still surfacing pages → page widgets.
          _walkWidgets(v, childPath, depth, out, limit: limit);
        }
      }
    }
  }

  /// Dispatch the named call. Returns null when the name is not one
  /// of the build tools so the LLM router can fall through.
  Future<BuildToolResult?> dispatch(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'pack_bundle':
        return packBundle(
          channel: args['channel'] as String? ?? '',
          outPath: args['outPath'] as String? ?? '',
        );
      case 'run_shell':
        return runShell(
          command: args['command'] as String? ?? '',
          args: ((args['args'] as List?) ?? const <String>[])
              .map((e) => e.toString())
              .toList(growable: false),
          cwd: args['cwd'] as String? ?? '',
        );
      case 'read_build_guide':
        return readBuildGuide();
      case 'project_info':
        return projectInfo();
      case 'get_build_config':
        return getBuildConfig();
      case 'run_build':
        return runBuild(
          target: args['target'] as String?,
          channel: args['channel'] as String?,
          outDir: args['outDir'] as String?,
        );
      case 'preview_capture':
        return capturePreview(
          pixelRatio: (args['pixelRatio'] as num?)?.toDouble() ?? 2.0,
          outPath: args['outPath'] as String?,
        );
      case 'layout_snapshot':
        return layoutSnapshot();
      case 'bundle_outline':
        return bundleOutline();
      case 'get_section':
        return getSection(
          section: (args['section'] as String?) ?? '',
          id: args['id'] as String?,
        );
      case 'tree_outline':
        return treeOutline(scope: args['scope'] as String?);
      case 'get_widget':
        return getWidget(path: (args['path'] as String?) ?? '');
      case 'set_property':
        // Note — `force` is intentionally NOT exposed via the MCP
        // dispatch path. The destructive-write guard exists
        // precisely because LLM callers will mechanically pass
        // force:true after reading a guarded error. The flag is
        // reserved for the human-driven Inspector override path
        // (which calls setProperty directly, not via this
        // dispatcher).
        return setProperty(
          path: (args['path'] as String?) ?? '',
          key: (args['key'] as String?) ?? '',
          value: args['value'],
        );
      case 'add_child':
        final w = args['widget'];
        if (w is! Map) {
          return BuildToolResult.failure('widget must be an object');
        }
        final widgetType = w['type'];
        if (widgetType is! String || widgetType.isEmpty) {
          return BuildToolResult.failure(
            'widget.type required (string) — see vibe_widget_list for the catalog',
          );
        }
        return addChild(
          parentPath: (args['parentPath'] as String?) ?? '',
          widget: Map<String, dynamic>.from(w),
          slot: (args['slot'] as String?) ?? 'children',
          index: (args['index'] as num?)?.toInt(),
        );
      case 'move_widget':
        return moveWidget(
          path: (args['path'] as String?) ?? '',
          newParentPath: (args['newParentPath'] as String?) ?? '',
          slot: (args['slot'] as String?) ?? 'children',
          index: (args['index'] as num?)?.toInt(),
        );
      case 'delete_widget':
        return deleteWidget(path: (args['path'] as String?) ?? '');
      case 'replace_subtree':
        final w = args['widget'];
        if (w is! Map) {
          return BuildToolResult.failure('widget must be an object');
        }
        return replaceSubtree(
          path: (args['path'] as String?) ?? '',
          widget: Map<String, dynamic>.from(w),
        );
      case 'find_widgets':
        return findWidgets(
          type: args['type'] as String?,
          label: args['label'] as String?,
          hasProp: args['hasProp'] as String?,
          refersTo: args['refersTo'] as String?,
          scope: args['scope'] as String?,
        );
      case 'check_wiring':
        return checkWiring();
      case 'rename_page':
        return renamePage(
          oldId: (args['oldId'] as String?) ?? '',
          newId: (args['newId'] as String?) ?? '',
        );
      case 'extract_template':
        return extractTemplate(
          widgetPath: (args['widgetPath'] as String?) ?? '',
          templateId: (args['templateId'] as String?) ?? '',
        );
      case 'inline_template':
        return inlineTemplate(usePath: (args['usePath'] as String?) ?? '');
      case 'duplicate_page':
        return duplicatePage(
          srcId: (args['srcId'] as String?) ?? '',
          newId: (args['newId'] as String?) ?? '',
          route: args['route'] as String?,
        );
      case 'state_usage':
        return stateUsage(pageId: (args['pageId'] as String?) ?? '');
      case 'binding_dependencies':
        return bindingDependencies(path: (args['path'] as String?) ?? '');
      case 'apply_theme_preset':
        return applyThemePreset(
          seedColor: (args['seedColor'] as String?) ?? '',
          mode: (args['mode'] as String?) ?? 'system',
        );
      case 'apply_layout_preset':
        return applyLayoutPreset(
          pageId: (args['pageId'] as String?) ?? '',
          kind: (args['kind'] as String?) ?? '',
          dryRun: args['dryRun'] == true,
        );
      case 'validate_bundle':
        return validateBundle();
      // 1.3.4 surfaces.
      case 'i18n_locale_add':
        return i18nLocaleAdd(
          tag: (args['tag'] as String?) ?? '',
          setAsDefault: args['setAsDefault'] == true,
        );
      case 'i18n_locale_remove':
        return i18nLocaleRemove(tag: (args['tag'] as String?) ?? '');
      case 'service_set':
        final params = args['params'];
        final entry = args['entry'];
        return serviceSet(
          name: (args['name'] as String?) ?? '',
          kind: args['kind'] as String?,
          interval: args['interval'] as num?,
          tool: args['tool'] as String?,
          params: params is Map ? Map<String, dynamic>.from(params) : null,
          binding: args['binding'] as String?,
          onMessage: args['onMessage'],
          onError: args['onError'],
          autoStart: args['autoStart'] as bool?,
          entry: entry is Map ? Map<String, dynamic>.from(entry) : null,
        );
      case 'service_remove':
        return serviceRemove(name: (args['name'] as String?) ?? '');
      case 'template_library_add':
        return templateLibraryAdd(
          uri: (args['uri'] as String?) ?? '',
          version: args['version'] as String?,
          integrity: args['integrity'] as String?,
        );
      case 'template_library_remove':
        return templateLibraryRemove(uri: (args['uri'] as String?) ?? '');
      case 'theme_preset_set':
        return themePresetSet(preset: (args['preset'] as String?) ?? '');
      case 'theme_font_set':
        final weights = args['weights'];
        final fallbacks = args['fallbacks'];
        final variableAxes = args['variableAxes'];
        return themeFontSet(
          family: (args['family'] as String?) ?? '',
          weights: weights is Map ? Map<String, dynamic>.from(weights) : null,
          variableAxes:
              variableAxes is List ? List<dynamic>.from(variableAxes) : null,
          fallbacks:
              fallbacks is List
                  ? fallbacks.whereType<String>().toList(growable: false)
                  : null,
        );
      case 'theme_font_remove':
        return themeFontRemove(family: (args['family'] as String?) ?? '');
      case 'navigation_style_set':
        final style = args['style'];
        return navigationStyleSet(
          slot: args['slot'] as String?,
          value: args['value'],
          style: style is Map ? Map<String, dynamic>.from(style) : null,
        );
      case 'i18n_text_set':
        return i18nTextSet(
          locale: (args['locale'] as String?) ?? '',
          key: (args['key'] as String?) ?? '',
          value: (args['value'] as String?) ?? '',
        );
      case 'i18n_pluralization_set':
        final forms = args['forms'];
        return i18nPluralizationSet(
          locale: (args['locale'] as String?) ?? '',
          key: (args['key'] as String?) ?? '',
          forms:
              forms is Map
                  ? Map<String, dynamic>.from(forms)
                  : const <String, dynamic>{},
        );
      case 'i18n_text_direction_set':
        return i18nTextDirectionSet(
          locale: (args['locale'] as String?) ?? '',
          direction: (args['direction'] as String?) ?? '',
        );
      case 'navigation_item_style_set':
        final navStyle = args['style'];
        return navigationItemStyleSet(
          index: (args['index'] as num?)?.toInt() ?? -1,
          slot: args['slot'] as String?,
          value: args['value'],
          style: navStyle is Map ? Map<String, dynamic>.from(navStyle) : null,
        );
      case 'asset_audit':
        return assetAudit(apply: args['apply'] == true);
      case 'extract_i18n':
        return extractI18n(
          pageId: (args['pageId'] as String?) ?? '',
          locale: args['locale'] as String?,
          keyPrefix: args['keyPrefix'] as String?,
          dryRun: args['dryRun'] == true,
        );
      case 'a11y_audit':
        return a11yAudit(pageId: args['pageId'] as String?);
      case 'token_usage':
        return tokenUsage(
          role: (args['role'] as String?) ?? '',
          domain: (args['domain'] as String?) ?? 'color',
        );
      case 'swap_widget':
        return swapWidget(
          path: (args['path'] as String?) ?? '',
          newType: (args['newType'] as String?) ?? '',
          dryRun: args['dryRun'] == true,
        );
      case 'animation_preset':
        return animationPreset(
          pageId: (args['pageId'] as String?) ?? '',
          kind: (args['kind'] as String?) ?? '',
          dryRun: args['dryRun'] == true,
        );
      case 'widget_diff':
        final cand = args['candidate'];
        return widgetDiff(
          path: (args['path'] as String?) ?? '',
          candidate:
              cand is Map
                  ? Map<String, dynamic>.from(cand)
                  : const <String, dynamic>{},
          apply: args['apply'] == true,
        );
      case 'spec_card':
        return specCard(topic: (args['topic'] as String?) ?? '');
      case 'health_check':
        return healthCheck();
      case 'a11y_quick_fix':
        return a11yQuickFix(
          pageId: args['pageId'] as String?,
          dryRun: args['dryRun'] == true,
          markDecorative: args['markDecorative'] == true,
        );
      case 'rename_template':
        return renameTemplate(
          oldId: (args['oldId'] as String?) ?? '',
          newId: (args['newId'] as String?) ?? '',
        );
      case 'rename_state_key':
        return renameStateKey(
          oldKey: (args['oldKey'] as String?) ?? '',
          newKey: (args['newKey'] as String?) ?? '',
          scope: (args['scope'] as String?) ?? 'app',
        );
      case 'release_check':
        return releaseCheck(dryRun: args['dryRun'] == true);
      case 'grade':
        return grade();
      case 'pending_diff':
        return pendingDiff();
      case 'help':
        return help();
      case 'search':
        return search(
          query: (args['query'] as String?) ?? '',
          cap: (args['cap'] as num?)?.toInt() ?? 50,
        );
      case 'route_audit':
        return routeAudit();
      case 'widget_shape_audit':
        return widgetShapeAudit(scope: args['scope'] as String?);
      case 'extract_to_template':
        return extractToTemplate(
          widgetPath: (args['widgetPath'] as String?) ?? '',
          newTemplateId: (args['newTemplateId'] as String?) ?? '',
        );
      case 'widget_lint':
        return widgetLint(scope: args['scope'] as String?);
      case 'tokenization_audit':
        return tokenizationAudit(scope: args['scope'] as String?);
      case 'dependency_graph':
        return dependencyGraph(
          topWidgets: (args['topWidgets'] as num?)?.toInt() ?? 5,
        );
      case 'find_references':
        return findReferences(target: (args['target'] as String?) ?? '');
      case 'undo_history':
        return undoHistory(
          limit: (args['limit'] as num?)?.toInt() ?? 50,
          originator: args['originator'] as String?,
          pathPrefix: args['pathPrefix'] as String?,
        );
      case 'diff_apply':
        return diffApply(ops: (args['ops'] as List?) ?? const <dynamic>[]);
      case 'page_create':
        return pageCreate(
          id: (args['id'] as String?) ?? '',
          title: args['title'] as String?,
          route: args['route'] as String?,
          kind: args['kind'] as String?,
          home: args['home'] == true,
        );
      case 'state_propose':
        return stateProposeForPage(
          pageId: (args['pageId'] as String?) ?? '',
          apply: args['apply'] == true,
        );
      case 'apply_to_each':
        final s = args['set'];
        final sd = args['setDeep'];
        return applyToEach(
          type: args['type'] as String?,
          label: args['label'] as String?,
          hasProp: args['hasProp'] as String?,
          refersTo: args['refersTo'] as String?,
          scope: args['scope'] as String?,
          set: s is Map ? Map<String, dynamic>.from(s) : null,
          setDeep: sd is Map ? Map<String, dynamic>.from(sd) : null,
          cap: (args['cap'] as num?)?.toInt() ?? 50,
          dryRun: args['dryRun'] == true,
        );
      case 'rename_route':
        return renameRoute(
          oldPath: (args['oldPath'] as String?) ?? '',
          newPath: (args['newPath'] as String?) ?? '',
        );
      case 'apply_recipe':
        final recipeArgs = args['args'];
        return applyRecipe(
          name: (args['name'] as String?) ?? '',
          args:
              recipeArgs is Map
                  ? Map<String, dynamic>.from(recipeArgs)
                  : const <String, dynamic>{},
          dryRun: args['dryRun'] == true,
        );
      default:
        return null;
    }
  }

  /// Capture the live preview surface as PNG, save under
  /// `<projectPath>/.capture/<ts>.png` (or [outPath]), return the
  /// absolute path. The LLM can then `read_file` to inspect bytes if
  /// it has multimodal capability, or compare the path across turns.
  Future<BuildToolResult> capturePreview({
    double pixelRatio = 2.0,
    String? outPath,
  }) async {
    final cb = onCapturePreview;
    if (cb == null) {
      return BuildToolResult.failure('preview capture not wired');
    }
    final captured = await cb(pixelRatio: pixelRatio);
    if (captured == null) {
      return BuildToolResult.failure(
        'no preview mounted — open a project + page first',
      );
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final rel =
        (outPath?.trim().isNotEmpty ?? false)
            ? outPath!.trim()
            : p.join('.capture', '$stamp.png');
    final abs = _resolveRel(rel) ?? p.join(_projectRoot, rel);
    final file = File(abs);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(captured.bytes, flush: true);
    return BuildToolResult.success(
      message: 'captured ${captured.width}x${captured.height}',
      path: abs,
      payload: jsonEncode(<String, dynamic>{
        'path': abs,
        'width': captured.width,
        'height': captured.height,
        'pixelRatio': pixelRatio,
        'sizeBytes': captured.bytes.length,
      }),
    );
  }

  /// Walk the live preview's render tree, return per-widget rect /
  /// font / decoration / padding so the LLM can reason about the
  /// rendered result without a vision model.
  Future<BuildToolResult> layoutSnapshot() async {
    final cb = onLayoutSnapshot;
    if (cb == null) {
      return BuildToolResult.failure('layout snapshot not wired');
    }
    final nodes = await cb();
    if (nodes == null) {
      return BuildToolResult.failure(
        'no preview mounted — open a project + page first',
      );
    }
    return BuildToolResult.success(
      message:
          'snapshot has ${nodes.length} node${nodes.length == 1 ? '' : 's'}',
      payload: jsonEncode(<String, dynamic>{'nodes': nodes}),
    );
  }

  /// Read the project's saved build preset (target / channel / outDir
  /// / runFlutterCreate). Returns an empty payload when nothing's
  /// saved yet so the LLM can recognise that case and ask the user.
  BuildToolResult getBuildConfig() {
    final cfg = project.prefs.buildConfig;
    return BuildToolResult.success(
      message: cfg == null ? 'no preset saved' : 'preset loaded',
      payload: jsonEncode(<String, dynamic>{
        if (cfg != null) 'target': cfg.target,
        if (cfg != null) 'channel': cfg.channel,
        if (cfg != null) 'outDir': cfg.outDir,
        if (cfg != null) 'runFlutterCreate': cfg.runFlutterCreate,
      }),
    );
  }

  /// Trigger the same pipeline the GUI Build button runs — auto-save
  /// the canonical, then build per the saved preset (or per-call
  /// overrides). Throws via [BuildToolResult.failure] when the host
  /// hasn't wired [onRunBuild].
  Future<BuildToolResult> runBuild({
    String? target,
    String? channel,
    String? outDir,
  }) async {
    final cb = onRunBuild;
    if (cb == null) {
      return BuildToolResult.failure(
        'build pipeline not wired in chat dispatcher — '
        'use the GUI Build button instead',
      );
    }
    try {
      final result = await cb(target: target, channel: channel, outDir: outDir);
      return BuildToolResult.success(
        message: 'build complete',
        payload: jsonEncode(result),
      );
    } catch (e) {
      return BuildToolResult.failure('build failed: $e');
    }
  }

  /// Tool schemas for the LLM. Mirror the dispatch switch.
  static const List<Map<String, dynamic>>
  toolDefinitions = <Map<String, dynamic>>[
    <String, dynamic>{
      'name': 'pack_bundle',
      'description':
          'Pack one of the project\'s channel `.mbd/` directories into a '
          'single `.mcpb` archive. Use this to produce a deployable '
          'bundle file (the deterministic step you would otherwise '
          'replicate by hand).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'channel': <String, dynamic>{
            'type': 'string',
            'enum': <String>['serving', 'native'],
            'description': 'Channel id whose bundle should be packed.',
          },
          'outPath': <String, dynamic>{
            'type': 'string',
            'description':
                'Project-relative output file path. Typical: '
                '`build/mcpb/bundle.mcpb`.',
          },
        },
        'required': <String>['channel', 'outPath'],
      },
    },
    <String, dynamic>{
      'name': 'run_shell',
      'description':
          'Run a shell command (e.g. `dart pub get`, `dart compile`, '
          '`dart run`) inside the project. `cwd` is project-relative '
          'and cannot escape the project root.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'command': <String, dynamic>{
            'type': 'string',
            'description': 'Executable name. Typical: `dart`, `git`, `sh`.',
          },
          'args': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
            'description': 'Argument list (will not be shell-interpreted).',
          },
          'cwd': <String, dynamic>{
            'type': 'string',
            'description':
                'Working directory, project-relative. Empty = project root.',
          },
        },
        'required': <String>['command', 'args'],
      },
    },
    <String, dynamic>{
      'name': 'read_build_guide',
      'description':
          'Return the canonical Dart MCP server pattern guide. Use this '
          'before generating server source so the output stays '
          'spec-truthful (hosted pub deps, page registration, '
          'inline-vs-bundle differences, …).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'project_info',
      'description':
          'Return a small JSON describing the project: name, path, '
          'channel registry, active channel. Cheap; call it whenever '
          'you need to resolve a channel id to a `.mbd` path.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'get_build_config',
      'description':
          'Read the project\'s saved Build preset (target / channel / '
          'outDir / runFlutterCreate) — the values the user last '
          'saved via the GUI Build dialog. Empty payload means no '
          'preset yet (then the LLM should ask). Call this BEFORE '
          '`run_build` when the user requests a build / app.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'preview_capture',
      'description':
          'Capture the live preview surface as a PNG, write it under '
          '`<projectPath>/.capture/<ts>.png` (or `outPath`), return '
          'the absolute path + dimensions. Use this AFTER applying '
          'patches when the user asks "did it work?" or reports a '
          'visual issue — read the file to inspect the actual '
          'render. Without this, you only see the JSON tree.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pixelRatio': <String, dynamic>{
            'type': 'number',
            'description':
                'Render-pixel-to-logical ratio (default 2.0). 1.0 = '
                'on-screen size; higher = sharper.',
          },
          'outPath': <String, dynamic>{
            'type': 'string',
            'description':
                'Project-relative output path. Default: '
                '`.capture/<ts>.png`. Parent dirs are created.',
          },
        },
      },
    },
    <String, dynamic>{
      'name': 'layout_snapshot',
      'description':
          'Walk the live preview\'s render tree and return one entry '
          'per metadata-tagged widget: `type`, `depth`, `rect` '
          '([x, y, w, h]), `font` (size/weight/family/color), '
          '`box` (color/radius/border), `padding`. Pure render-tree '
          'introspection — numbers reflect what is on screen, not '
          'the spec. Cheaper than `preview_capture` for layout / '
          'sizing / color verification (no image bytes, no vision '
          'model).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'bundle_outline',
      'description':
          'Top-level overview of every section in the canonical bundle '
          '— manifest, app metadata, theme summary, page list, '
          'template list, dashboard. Cheap (~few hundred bytes). '
          'Call this FIRST when the user asks "what\'s in this '
          'project?", "what pages exist?", or before working on '
          'a section you don\'t already know. Returns paths the '
          'other tools can use directly.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'get_section',
      'description':
          'Read an entire named section. `section` ∈ '
          '{manifest, app, theme, dashboard, pages, templates}. '
          'For pages/templates pass `id` to read one entry; omit '
          'to read the full map. Use for theme tokens / app '
          'metadata / template definitions; for widget trees '
          'inside a page prefer `tree_outline` (smaller payload).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'section': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'manifest',
              'app',
              'theme',
              'dashboard',
              'navigation',
              'assets',
              'pages',
              'templates',
            ],
          },
          'id': <String, dynamic>{
            'type': 'string',
            'description':
                'For `pages` / `templates`: the entry id. Omit to '
                'read the full map.',
          },
        },
        'required': <String>['section'],
      },
    },
    <String, dynamic>{
      'name': 'tree_outline',
      'description':
          'Walk the canonical bundle (or a subtree under `scope`) and '
          'return one flat entry per widget — `{path, type, label, '
          'depth, hasChildren?}`. THE PRIMARY UI INSPECTION TOOL: '
          'call this BEFORE `read_file` whenever the user asks about '
          'a widget — it returns ~5% the tokens of the raw JSON. '
          '`path` is an RFC 6901 JSON Pointer (e.g. '
          '`/ui/pages/home/content/children/2`); reuse it as the '
          '`path` argument to `get_widget` / `set_property` / '
          '`delete_widget`. Default `scope` is `/ui` (covers app + '
          'all pages); pass `/ui/pages/<id>/content` to drill in.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'scope': <String, dynamic>{
            'type': 'string',
            'description':
                'Subtree pointer. Default `/ui`. Examples: `/ui/pages`, '
                '`/ui/pages/home/content`, `/ui/theme`.',
          },
        },
      },
    },
    <String, dynamic>{
      'name': 'get_widget',
      'description':
          'Read one widget subtree by JSON Pointer path. Returns the '
          'full widget JSON. Use after `tree_outline` to inspect a '
          'specific widget without re-reading the whole file.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description':
                'RFC 6901 JSON Pointer obtained from `tree_outline`.',
          },
        },
        'required': <String>['path'],
      },
    },
    <String, dynamic>{
      'name': 'set_property',
      'description':
          'Upsert ONE property on any node — widget, theme token, '
          'app metadata, page-as-map entry, template, manifest. '
          '`key` is dot-pathed inside `path` (creates new keys, '
          'replaces existing). Atomic — pipeline validates against '
          'the spec. Examples:\n'
          '  widget color: path=`/ui/pages/home/content/children/0`, '
          'key=`style.color`, value=`"#FF0000"`\n'
          '  theme token:  path=`/ui/theme/color`, key=`primary`, '
          'value=`"#0000FF"`\n'
          '  app title:    path=`/ui`, key=`title`, value=`"My App"`\n'
          '  add new page: path=`/ui/pages`, key=`about`, '
          'value=`{type:"page", title:"About", content:{...}}`\n'
          '  wire route:   path=`/ui/routes`, key=`/about`, '
          'value=`"about"`  (slashes / tildes inside `key` are '
          'auto-escaped per RFC 6901, so route paths "just work")\n'
          'For array slot replacement (e.g. `children/0`) use '
          '`replace_subtree` instead — `add` op semantics insert '
          'at array indices rather than overwriting.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description':
                'JSON Pointer to the parent node. Empty `key` writes '
                'directly at this path.',
          },
          'key': <String, dynamic>{
            'type': 'string',
            'description':
                'Dot-pathed field inside `path`. Empty string writes '
                'directly at `path`.',
          },
          'value': <String, dynamic>{
            'description':
                'New value. Any JSON type the spec accepts for this key.',
          },
        },
        'required': <String>['path', 'key', 'value'],
      },
    },
    <String, dynamic>{
      'name': 'add_child',
      'description':
          'Add a child widget under a parent. Default slot is '
          '`children` (list); pass `slot: "child"` for single-child '
          'containers (`card`, `padding`, …). For lists, `index` '
          'inserts at that position; null appends.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'parentPath': <String, dynamic>{
            'type': 'string',
            'description': 'JSON Pointer to the parent widget.',
          },
          'widget': <String, dynamic>{
            'type': 'object',
            'description':
                'Widget object to insert (must include `type` field).',
          },
          'slot': <String, dynamic>{
            'type': 'string',
            'description':
                '`children` (default), `child`, `content`, `body`, '
                '`leading`, `trailing`, …',
          },
          'index': <String, dynamic>{
            'type': 'integer',
            'description': 'Position inside a `children` list. Null = append.',
          },
        },
        'required': <String>['parentPath', 'widget'],
      },
    },
    <String, dynamic>{
      'name': 'move_widget',
      'description':
          'Move a widget under a different parent (or to a different '
          'index in the same parent). Atomic remove + add.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string'},
          'newParentPath': <String, dynamic>{'type': 'string'},
          'slot': <String, dynamic>{
            'type': 'string',
            'description': 'Default `children`.',
          },
          'index': <String, dynamic>{'type': 'integer'},
        },
        'required': <String>['path', 'newParentPath'],
      },
    },
    <String, dynamic>{
      'name': 'delete_widget',
      'description':
          'Remove any node by path — widget, page entry, template '
          'entry, theme token, app field. Path = JSON Pointer.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description':
                'JSON Pointer to the node to delete. Examples: '
                '`/ui/pages/home/content/children/0` (widget), '
                '`/ui/pages/about` (whole page), '
                '`/ui/theme/color/secondary` (theme token).',
          },
        },
        'required': <String>['path'],
      },
    },
    <String, dynamic>{
      'name': 'find_widgets',
      'description':
          'Search for widgets across the bundle. Combine filters '
          '(any subset is accepted, but at least one is required):\n'
          '  type:      exact widget type (e.g. `button`, `text`)\n'
          '  label:     case-insensitive substring of label/text/'
          'title/id\n'
          '  hasProp:   widget contains this top-level property '
          'name (e.g. `onTap`, `style`)\n'
          '  refersTo:  any string inside the widget contains this '
          'substring — useful for finding all `@{state.x}` '
          'references, all uses of color `#FF0000`, all `use` '
          'widgets pointing to a template id, …\n'
          '  scope:     subtree to search (default `/ui`)\n'
          'Returns up to 200 matches with `{path, type, label?}`.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'type': <String, dynamic>{'type': 'string'},
          'label': <String, dynamic>{'type': 'string'},
          'hasProp': <String, dynamic>{'type': 'string'},
          'refersTo': <String, dynamic>{'type': 'string'},
          'scope': <String, dynamic>{'type': 'string'},
        },
      },
    },
    <String, dynamic>{
      'name': 'check_wiring',
      'description':
          'Bundle-wide wiring lint. Detects orphan pages (declared but '
          'no route), missing route targets, missing initialRoute, '
          'undefined / unused templates, undefined state references '
          '(widget binds `state.X` but X not in page state). Run '
          'before `run_build` / `project_save` to catch authoring '
          'drift the spec validator alone cannot detect.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'apply_theme_preset',
      'description':
          'Bootstrap a Material 3 theme from a seed color. Sets '
          '`color.seed` (runtime auto-derives the full color '
          'scheme), the 15-role typography scale, M3 spacing '
          'tokens, and shape defaults. Use ONCE on a fresh '
          'project; further tweaks via set_property(/ui/theme/...).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'seedColor': <String, dynamic>{
            'type': 'string',
            'description': '`#RRGGBB` or `#RRGGBBAA`.',
          },
          'mode': <String, dynamic>{
            'type': 'string',
            'enum': <String>['light', 'dark', 'system'],
            'description': 'Default `system`.',
          },
        },
        'required': <String>['seedColor'],
      },
    },
    <String, dynamic>{
      'name': 'apply_layout_preset',
      'description':
          'Replace a page\'s `content` (and seed `state` when '
          'relevant) with a verified mcp_ui DSL 1.3 layout '
          'skeleton. Utility kinds: `hero` (display + subtitle '
          '+ CTA), `cardList` (3 placeholder cards), `form` '
          '(titled + 2 textfields + submit, state seeded), '
          '`settings` (3 option rows). 1.3.4 content-app '
          'kinds: `gallery` (staggeredGrid of cards), `magazine` '
          '(kenBurnsImage cover + body w/ dropCap), `carousel` '
          '(featured slide strip), `playlist` (album row list), '
          '`landing` (kenBurns hero + animated headline).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pageId': <String, dynamic>{
            'type': 'string',
            'description': 'Existing page id under /ui/pages/.',
          },
          'kind': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'hero',
              'cardList',
              'form',
              'settings',
              'gallery',
              'magazine',
              'carousel',
              'playlist',
              'landing',
            ],
          },
          'dryRun': <String, dynamic>{
            'type': 'boolean',
            'default': false,
            'description':
                'When true, returns the candidate '
                '`content` (and seeded `state`) without mutating '
                'the canonical — pair with widget_diff or chat-side '
                'preview before committing.',
          },
        },
        'required': <String>['pageId', 'kind'],
      },
    },
    <String, dynamic>{
      'name': 'validate_bundle',
      'description':
          'Full bundle validation. Runs the SpecValidator (manifest / '
          'app / theme / pages / templates JSON-Schema) AND the '
          '`check_wiring` pass in one call. Returns aggregated '
          'issues split into `specIssues` and `wiringIssues`. '
          'Recommended right before `run_build`.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'state_usage',
      'description':
          'Per-page state audit. For one page, returns a key-by-key '
          'breakdown of declared state vs widget-bound references. '
          'Each key entry: `{key, declared, refs:[{path, kind, '
          'expr}]}`. Summary lists `unused` (declared but never '
          'referenced) and `undefined` (referenced but not '
          'declared). Use to diagnose stale state keys or missing '
          'declarations before save.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pageId': <String, dynamic>{
            'type': 'string',
            'description': 'Page id under /ui/pages/.',
          },
        },
        'required': <String>['pageId'],
      },
    },
    <String, dynamic>{
      'name': 'binding_dependencies',
      'description':
          'What does this widget subtree depend on? Returns the state '
          'keys it reads/writes, the templates it uses, the routes '
          'it navigates to, and any other binding references (theme '
          'tokens, extension namespaces). Run before deleting / '
          'moving a widget to assess impact.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description': 'JSON Pointer to the widget subtree.',
          },
        },
        'required': <String>['path'],
      },
    },
    <String, dynamic>{
      'name': 'extract_template',
      'description':
          'DRY refactor: pick a widget subtree, register it as a new '
          'template at /ui/templates/<templateId>, and replace the '
          'original location with a `use` widget pointing at it. '
          'One atomic patch. Use after `find_widgets` identifies '
          'repeated structure (e.g. three identical card subtrees).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'widgetPath': <String, dynamic>{
            'type': 'string',
            'description': 'JSON Pointer to the widget subtree to extract.',
          },
          'templateId': <String, dynamic>{
            'type': 'string',
            'description':
                'New template id (must be unique under /ui/templates).',
          },
        },
        'required': <String>['widgetPath', 'templateId'],
      },
    },
    <String, dynamic>{
      'name': 'inline_template',
      'description':
          'Inverse of `extract_template`: expand a `use` widget back '
          'into the template content at the same location. When '
          'the `use` carries `props`, `@{props.X}` bindings inside '
          'the template content are substituted with the literal '
          'prop values during inlining. Useful when a template is '
          'used in only one place and the indirection is no '
          'longer worth it.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'usePath': <String, dynamic>{
            'type': 'string',
            'description': 'JSON Pointer to the `use` widget to inline.',
          },
        },
        'required': <String>['usePath'],
      },
    },
    <String, dynamic>{
      'name': 'duplicate_page',
      'description':
          'Deep-copy a page and (optionally) wire a new route to it '
          'in one atomic patch. Useful for "make a settings page '
          'like the profile page" / "create T&C and Privacy from '
          'the same About template" flows.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'srcId': <String, dynamic>{
            'type': 'string',
            'description': 'Existing page id to copy.',
          },
          'newId': <String, dynamic>{
            'type': 'string',
            'description': 'New page id.',
          },
          'route': <String, dynamic>{
            'type': 'string',
            'description':
                'Optional URL path to wire to the new page (e.g. '
                '`/settings`). Omit to copy without routing.',
          },
        },
        'required': <String>['srcId', 'newId'],
      },
    },
    <String, dynamic>{
      'name': 'rename_page',
      'description':
          'Atomically rename a page. Updates the /ui/pages map key '
          'AND every /ui/routes entry pointing at the old id, in '
          'one patch. Without this, a manual rename via '
          'set_property + delete_widget can leave routes dangling.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'oldId': <String, dynamic>{'type': 'string'},
          'newId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['oldId', 'newId'],
      },
    },
    <String, dynamic>{
      'name': 'replace_subtree',
      'description':
          'Replace an entire widget subtree with a new widget. Use ONLY '
          'for structural rewrites (changing root widget type, '
          'swapping a card for a linear, …). For single-field '
          'changes use `set_property` instead — `replace_subtree` '
          'erases sibling fields and is harder to validate.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string'},
          'widget': <String, dynamic>{
            'type': 'object',
            'description': 'New widget object (must include `type`).',
          },
        },
        'required': <String>['path', 'widget'],
      },
    },
    <String, dynamic>{
      'name': 'run_build',
      'description':
          'Run the project\'s build pipeline. With no args, reuses the '
          'saved preset (set via the GUI Build dialog). Per-call '
          '`target` / `channel` / `outDir` override one slot for '
          'this run only — they are NOT persisted. Auto-saves the '
          'canonical first (same as the GUI Build button) so any '
          '`apply_patch` from this session lands in the artifact. '
          'Targets: `mcpb` (.mcpb pack), `bundle` (Dart server with '
          'on-disk UI), `inline` (Dart server with baked UI), '
          '`native_inline` / `native_bundle` (Flutter desktop app).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'target': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'mcpb',
              'bundle',
              'inline',
              'native_bundle',
              'native_inline',
            ],
            'description': 'Override the saved target for this run.',
          },
          'channel': <String, dynamic>{
            'type': 'string',
            'enum': <String>['serving', 'native'],
            'description': 'Override the saved channel for this run.',
          },
          'outDir': <String, dynamic>{
            'type': 'string',
            'description':
                'Override the saved outDir for this run. '
                'Project-relative or absolute.',
          },
        },
      },
    },
    // ─── 1.3.4 surfaces ─────────────────────────────────────────
    <String, dynamic>{
      'name': 'i18n_locale_add',
      'description':
          'Add a BCP-47 locale tag to /ui/i18n/locales (idempotent). '
          'Pass setAsDefault=true to also pin /ui/i18n/'
          'defaultLocale.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'tag': <String, dynamic>{
            'type': 'string',
            'description': 'BCP-47 (`en`, `en-US`, `zh-Hant-TW`).',
          },
          'setAsDefault': <String, dynamic>{
            'type': 'boolean',
            'default': false,
          },
        },
        'required': <String>['tag'],
      },
    },
    <String, dynamic>{
      'name': 'i18n_locale_remove',
      'description':
          'Remove a locale tag from /ui/i18n/locales. Clears '
          'defaultLocale when it pointed at the removed tag.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'tag': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['tag'],
      },
    },
    <String, dynamic>{
      'name': 'service_set',
      'description':
          'Upsert a background service under /ui/services/<name>. '
          'Pass any subset of typed fields (kind / interval / '
          'tool / params / binding / onMessage / onError / '
          'autoStart) to merge, or `entry` to fully replace.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'name': <String, dynamic>{'type': 'string'},
          'kind': <String, dynamic>{
            'type': 'string',
            'enum': <String>['polling', 'subscription'],
          },
          'interval': <String, dynamic>{'type': 'number'},
          'tool': <String, dynamic>{'type': 'string'},
          'params': <String, dynamic>{'type': 'object'},
          'binding': <String, dynamic>{'type': 'string'},
          'onMessage': <String, dynamic>{},
          'onError': <String, dynamic>{},
          'autoStart': <String, dynamic>{'type': 'boolean'},
          'entry': <String, dynamic>{'type': 'object'},
        },
        'required': <String>['name'],
      },
    },
    <String, dynamic>{
      'name': 'service_remove',
      'description': 'Remove a service entry from /ui/services.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'name': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['name'],
      },
    },
    <String, dynamic>{
      'name': 'template_library_add',
      'description':
          'Append (or update by uri) a TemplateLibraryRef under /ui/'
          'templateLibraries.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'uri': <String, dynamic>{'type': 'string'},
          'version': <String, dynamic>{'type': 'string'},
          'integrity': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['uri'],
      },
    },
    <String, dynamic>{
      'name': 'template_library_remove',
      'description':
          'Remove a TemplateLibraryRef by `uri` from '
          '/ui/templateLibraries.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'uri': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['uri'],
      },
    },
    <String, dynamic>{
      'name': 'theme_preset_set',
      'description':
          'Set the curated content-app theme preset (1.3.4 Phase 5). '
          'Five values; other theme.* fields layer overrides.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'preset': <String, dynamic>{
            'type': 'string',
            'enum': <String>['warm', 'cool', 'sepia', 'mono', 'highContrast'],
          },
        },
        'required': <String>['preset'],
      },
    },
    <String, dynamic>{
      'name': 'theme_font_set',
      'description':
          'Upsert a font family under /ui/theme/fonts/<family>. At '
          'least one of weights / variableAxes / fallbacks '
          'required.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'family': <String, dynamic>{'type': 'string'},
          'weights': <String, dynamic>{
            'type': 'object',
            'description':
                'Map of weight (100..900 or `regular` / '
                '`bold`) to AssetRef.',
          },
          'variableAxes': <String, dynamic>{
            'type': 'array',
            'description': '[{tag,min,max,default}] entries.',
          },
          'fallbacks': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
          },
        },
        'required': <String>['family'],
      },
    },
    <String, dynamic>{
      'name': 'theme_font_remove',
      'description': 'Remove a font family from /ui/theme/fonts.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'family': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['family'],
      },
    },
    <String, dynamic>{
      'name': 'i18n_text_set',
      'description':
          'Upsert a single i18n string at /ui/i18n/text/<locale>/'
          '<key>. Locale is BCP-47.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'locale': <String, dynamic>{'type': 'string'},
          'key': <String, dynamic>{'type': 'string'},
          'value': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['locale', 'key', 'value'],
      },
    },
    <String, dynamic>{
      'name': 'i18n_pluralization_set',
      'description':
          'Upsert pluralization forms at /ui/i18n/pluralization/'
          '<locale>/<key>. `forms` is a CLDR-category map '
          '(zero/one/two/few/many/other → string).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'locale': <String, dynamic>{'type': 'string'},
          'key': <String, dynamic>{'type': 'string'},
          'forms': <String, dynamic>{'type': 'object'},
        },
        'required': <String>['locale', 'key', 'forms'],
      },
    },
    <String, dynamic>{
      'name': 'i18n_text_direction_set',
      'description':
          'Set text direction for a locale — '
          '/ui/i18n/textDirection/<locale> ∈ ltr / rtl.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'locale': <String, dynamic>{'type': 'string'},
          'direction': <String, dynamic>{
            'type': 'string',
            'enum': <String>['ltr', 'rtl'],
          },
        },
        'required': <String>['locale', 'direction'],
      },
    },
    <String, dynamic>{
      'name': 'widget_diff',
      'description':
          'Structural diff between the current widget at `path` and '
          'a `candidate` widget map. Returns the RFC-6902 patch '
          'that would migrate current → candidate plus a summary '
          'tree (added / removed / modified) per pointer. Pass '
          '`apply:true` to commit; default is preview.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string'},
          'candidate': <String, dynamic>{'type': 'object'},
          'apply': <String, dynamic>{'type': 'boolean', 'default': false},
        },
        'required': <String>['path', 'candidate'],
      },
    },
    <String, dynamic>{
      'name': 'apply_recipe',
      'description':
          'Apply a curated micro-recipe — a small structural '
          'transform composed of a few patches. Catalog: '
          '`wrap_with_card({path})` / '
          '`wrap_with_padding({path, value=16})` / '
          '`wrap_with_scroll({path, direction=vertical})` / '
          '`wrap_with_expanded({path, flex=1})` / '
          '`wrap_with_centered({path})` / '
          '`wrap_with_aspect_ratio({path, ratio=16/9})` / '
          '`wrap_with_clip_oval({path})` / '
          '`wrap_with_hero({path, tag})` / '
          '`wrap_with_animated_opacity({path, binding?, '
          'duration?=300, curve?=emphasized})` / '
          '`wrap_with_safearea({pageId})` / '
          '`add_floating_action({pageId, label, route})` / '
          '`add_loading_state({pageId, key})`. '
          'Pass `dryRun:true` to preview the patch shape.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'name': <String, dynamic>{'type': 'string'},
          'args': <String, dynamic>{
            'type': 'object',
            'description': 'Recipe-specific arguments — see catalog above.',
          },
          'dryRun': <String, dynamic>{'type': 'boolean', 'default': false},
        },
        'required': <String>['name'],
      },
    },
    <String, dynamic>{
      'name': 'rename_route',
      'description':
          'Rename a route path keeping the same target page. '
          'Updates `/ui/routes` plus initialRoute, '
          'navigation.items[].route, and `{{routes.<oldPath>}}` '
          'bindings. Atomic.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'oldPath': <String, dynamic>{'type': 'string'},
          'newPath': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['oldPath', 'newPath'],
      },
    },
    <String, dynamic>{
      'name': 'widget_shape_audit',
      'description':
          'Per-widget spec-shape audit — catches violations that the '
          'bundle-level validator misses (which only checks the '
          'envelope, not per-widget constraints). Rules currently '
          'enforced: onTap_must_be_action (button/iconButton/'
          'floatingActionButton/listItem/gestureDetector/inkWell '
          'event handlers require single Action object — wrap '
          'multi-action lists in sequence/batch), '
          'children_must_be_list, button_label_required, '
          'text_content_required, image_src_required. Each finding '
          'includes a `fix` tool/args when auto-correctable.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'scope': <String, dynamic>{
            'type': 'string',
            'description':
                'JSON pointer subtree (default /ui). Use to scope to '
                'one page/template.',
          },
        },
      },
    },
    <String, dynamic>{
      'name': 'extract_to_template',
      'description':
          '"Extract to template" refactor — captures the widget at '
          'widgetPath, creates /ui/templates/<newTemplateId>, '
          'and replaces the original location with a `use:` of '
          'the new template. Inverse of inline_template. '
          'Atomic (one diff_apply transaction).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'widgetPath': <String, dynamic>{
            'type': 'string',
            'description':
                'JSON pointer to the widget subtree to extract '
                '(e.g. /ui/pages/home/content/children/2).',
          },
          'newTemplateId': <String, dynamic>{
            'type': 'string',
            'description':
                'identifier for the new template '
                '(letters/digits/underscore, must start with letter).',
          },
        },
        'required': <String>['widgetPath', 'newTemplateId'],
      },
    },
    <String, dynamic>{
      'name': 'widget_lint',
      'description':
          'Local-scope quality lint beyond a11y/spec/wiring. Rules: '
          'deep_nesting (>8), empty_container, long_text_leaf '
          '(>240 chars), list_no_item_id, redundant_wrapper. '
          'Scope to a single page/template via JSON pointer.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'scope': <String, dynamic>{
            'type': 'string',
            'description': 'JSON pointer subtree (default /ui).',
          },
        },
      },
    },
    <String, dynamic>{
      'name': 'tokenization_audit',
      'description':
          'Find hardcoded color hex / spacing / radius values that '
          'should ideally reference theme tokens. Inverse of '
          'token_usage. Each finding includes a suggested '
          'token (e.g. spacing 16 → tokens.spacing.md). Optional '
          '`scope` JSON pointer to limit the walk (e.g. '
          '"/ui/pages/home").',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'scope': <String, dynamic>{
            'type': 'string',
            'description':
                'JSON pointer subtree (default /ui). Use to scope '
                'the audit to one page or component.',
          },
        },
      },
    },
    <String, dynamic>{
      'name': 'dependency_graph',
      'description':
          'Project dependency graph (page/template → '
          'routes/templates/assets/state). Each container '
          'reports its outbound edges + widget type histogram. '
          'Inverted indices answer "which pages use template X '
          '/ asset Y". Useful for marketplace pre-pack analysis '
          'and impact assessment before delete/rename.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'topWidgets': <String, dynamic>{
            'type': 'integer',
            'default': 5,
            'description':
                'how many widget types to keep per container in '
                'the topTypes histogram',
          },
        },
      },
    },
    <String, dynamic>{
      'name': 'find_references',
      'description':
          'Cross-cutting Find References — IDE-style usages '
          'lookup. Target form: "<kind>:<value>" where kind ∈ '
          '{template, state, route, asset}. Examples: '
          '"template:hero", "state:home.counter", '
          '"route:/settings", "asset:bgImage". Returns hits '
          'grouped by container (page/template id).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'target': <String, dynamic>{
            'type': 'string',
            'description':
                '"<kind>:<value>" — see kinds above. state form '
                'requires "<pageId>.<key>".',
          },
        },
        'required': <String>['target'],
      },
    },
    <String, dynamic>{
      'name': 'undo_history',
      'description':
          'Recent canonical mutations from history.jsonl. Each '
          'entry: when, kind (patch/open/saveAs/revert), '
          'changedPaths, originator (chat/gui/mcp), short '
          'before/after hashes. Use to answer "what just '
          'happened?" or scope to "my last theme edits".',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'limit': <String, dynamic>{
            'type': 'integer',
            'default': 50,
            'description': 'max entries (capped 500)',
          },
          'originator': <String, dynamic>{
            'type': 'string',
            'description':
                'exact-match filter on originator kind. Common '
                'values: "llm.semantic" (mcp / chat tool calls), '
                '"gui.editor" (direct GUI edits), "gui.import". '
                'null = all. To discover actual values for this '
                'project, call once without the filter and look at '
                'entries[*].originator.',
          },
          'pathPrefix': <String, dynamic>{
            'type': 'string',
            'description':
                'filter to entries whose changedPaths include any '
                'path under this prefix (e.g. "/ui/theme").',
          },
        },
      },
    },
    <String, dynamic>{
      'name': 'route_audit',
      'description':
          'Routing-only audit (page ↔ route ↔ initialRoute). '
          'Narrower and more actionable than '
          'health_check.wiringIssues. Returns full route '
          'table, initialRoute resolution, and per-finding fix '
          'suggestion. Finding kinds: missing_route_target, '
          'orphan_page, missing_initial_route, '
          'duplicate_route_target, no_routes, no_initial_route.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'diff_apply',
      'description':
          'Apply an external RFC 6902 patch array with per-op '
          'layer auto-inference. Use when you have a '
          'multi-op patch that legitimately spans layers '
          '(e.g. add a page + add a theme color + register '
          'an asset in one transaction). Ops sharing a layer '
          'are dispatched together; layers run in canonical '
          'order. Order within a layer is preserved.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'ops': <String, dynamic>{
            'type': 'array',
            'description':
                'Array of RFC 6902 operations: '
                '{op:"add"|"replace"|"remove"|"move"|"copy"|"test", '
                'path, value?, from?}.',
          },
        },
        'required': <String>['ops'],
      },
    },
    <String, dynamic>{
      'name': 'page_create',
      'description':
          'Atomic "create a wired page" — single dispatch that '
          'creates `/ui/pages/<id>` (with type / title / '
          'content), optionally wires `/ui/routes/<route>` '
          '(default `/<id>`), and optionally seeds the content '
          'with a layout preset (kind = hero / cardList / form '
          '/ settings / gallery / magazine / carousel / '
          'playlist / landing). Pass `home:true` to also set '
          '`/ui/initialRoute` when no initial is set yet.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'id': <String, dynamic>{'type': 'string'},
          'title': <String, dynamic>{'type': 'string'},
          'route': <String, dynamic>{
            'type': 'string',
            'description':
                'Route path (default `/<id>`). Empty string = no '
                'route entry.',
          },
          'kind': <String, dynamic>{
            'type': 'string',
            'description': 'apply_layout_preset kind. null = empty linear.',
          },
          'home': <String, dynamic>{'type': 'boolean', 'default': false},
        },
        'required': <String>['id'],
      },
    },
    <String, dynamic>{
      'name': 'search',
      'description':
          'Global text search across the canonical. Matches the '
          'query (case-insensitive substring) against page ids, '
          'template ids, route paths, asset ids, widget types, '
          'widget labels, and string leaves (text content + '
          'bindings). Returns ranked `{path, kind, preview}` '
          'hits. cap defaults to 50.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'query': <String, dynamic>{'type': 'string'},
          'cap': <String, dynamic>{'type': 'integer', 'default': 50},
        },
        'required': <String>['query'],
      },
    },
    <String, dynamic>{
      'name': 'state_propose',
      'description':
          'Walk a page widget tree, collect every `{{state.<key>}}` '
          'reference, and report keys that are not declared in '
          '/ui/state or /ui/pages/<id>/state. Pass `apply:true` '
          'to seed the missing keys with `null` at the page '
          'level (author edits values afterwards).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pageId': <String, dynamic>{'type': 'string'},
          'apply': <String, dynamic>{'type': 'boolean', 'default': false},
        },
        'required': <String>['pageId'],
      },
    },
    <String, dynamic>{
      'name': 'apply_to_each',
      'description':
          'Find every widget matching the filter and apply the '
          'same property change to each. Filter mirrors '
          'find_widgets (type / label / hasProp / refersTo / '
          'scope). `set` is a flat name → value map; `setDeep` '
          'is the same shape with dot-paths inside the widget. '
          '`cap` (default 50) caps affected count. `dryRun:true` '
          'previews per-widget patches without committing. '
          'Example: apply_to_each(type=button, set={variant:'
          "'filled'}).",
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'type': <String, dynamic>{'type': 'string'},
          'label': <String, dynamic>{'type': 'string'},
          'hasProp': <String, dynamic>{'type': 'string'},
          'refersTo': <String, dynamic>{'type': 'string'},
          'scope': <String, dynamic>{'type': 'string'},
          'set': <String, dynamic>{'type': 'object'},
          'setDeep': <String, dynamic>{'type': 'object'},
          'cap': <String, dynamic>{'type': 'integer', 'default': 50},
          'dryRun': <String, dynamic>{'type': 'boolean', 'default': false},
        },
      },
    },
    <String, dynamic>{
      'name': 'help',
      'description':
          'Self-describing catalog of vibe tools, grouped by '
          'authoring vocabulary (discovery / mutation / audit / '
          'presets / refactor / authoring_surfaces / '
          'multimodal). Useful for "what can vibe do?" answers '
          'without grep\'ing every tool description.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'pending_diff',
      'description':
          'Diff the active channel\'s canonical JSON against the '
          'version last persisted to disk — what `Save` would '
          'commit. Returns RFC-6902 ops + summary tree '
          '(added / removed / modified per pointer). Useful to '
          'review what\'s pending without committing.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'grade',
      'description':
          'Letter-grade summary of bundle quality (A–F) with a per-'
          'axis rubric (validity / a11y / assets / state / '
          'tokens, each scored 0-20 → total 100). N/A for empty '
          'bundles. Use as a marketing-style "how is this '
          'doing?" answer.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'release_check',
      'description':
          'Multi-stage graduation check. Runs health_check, then '
          'asset_audit(apply) when invalid contentRefs exist, '
          'then a11y_quick_fix when fixable findings exist, '
          'then a final health_check. Returns `{ready, before, '
          'after, steps[], remaining}`. Pass `dryRun:true` to '
          'see the planned stages without mutating.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'dryRun': <String, dynamic>{'type': 'boolean', 'default': false},
        },
      },
    },
    <String, dynamic>{
      'name': 'rename_template',
      'description':
          'Rename a template id and propagate the change to every '
          '`use` widget that names it. Atomic — collisions / '
          'missing source / spec failures abort the whole '
          'operation.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'oldId': <String, dynamic>{'type': 'string'},
          'newId': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['oldId', 'newId'],
      },
    },
    <String, dynamic>{
      'name': 'rename_state_key',
      'description':
          'Rename a reactive state key and propagate to every '
          '`{{state.<oldKey>}}` binding. Scope: `app` (default '
          '— /ui/state) or `page:<id>` (per-page state).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'oldKey': <String, dynamic>{'type': 'string'},
          'newKey': <String, dynamic>{'type': 'string'},
          'scope': <String, dynamic>{
            'type': 'string',
            'description': '`app` (default) or `page:<id>`.',
          },
        },
        'required': <String>['oldKey', 'newKey'],
      },
    },
    <String, dynamic>{
      'name': 'a11y_quick_fix',
      'description':
          'Auto-fix the unambiguous a11y findings — `text.'
          'minFontSize` (raise to 12) and `touchTarget.minSize` '
          '(set width/height to 48 on buttons / iconButton). '
          'Skips ambiguous failures (missing accessible names) — '
          'author has to provide actual labels for those. Pass '
          '`markDecorative:true` to also auto-mark image / icon '
          'findings as `decorative: true` (only when the asset '
          'is purely visual). `dryRun:true` previews; `pageId` '
          'scopes.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pageId': <String, dynamic>{'type': 'string'},
          'dryRun': <String, dynamic>{'type': 'boolean', 'default': false},
          'markDecorative': <String, dynamic>{
            'type': 'boolean',
            'default': false,
          },
        },
      },
    },
    <String, dynamic>{
      'name': 'health_check',
      'description':
          'Single-shot bundle health check. Aggregates spec '
          'validation + wiring check + a11y audit + asset '
          'registry audit + per-page state usage + dead theme '
          'token detection. Returns {status: pass|warn|fail, '
          'summary: counts, details: full sub-tool payloads}. '
          'Use this at "is the bundle ready?" moments instead '
          'of running each sub-tool individually.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
    },
    <String, dynamic>{
      'name': 'spec_card',
      'description':
          'Pull a topic-focused 1.3.4 spec card on demand — keeps '
          'the agent prompt slim. Topics: phase1_decoration / '
          'phase2_gallery / phase3_motion / phase4_media / '
          'phase5_theme_nav / primitives / m3_motion.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'topic': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['topic'],
      },
    },
    <String, dynamic>{
      'name': 'animation_preset',
      'description':
          'Apply a Material 3 motion preset to every implicit-'
          'animation widget on a page (animatedOpacity / Align '
          '/ Positioned / DefaultTextStyle / Container / '
          'scrollAnimated / hero). Sets duration + curve '
          'uniformly. Kinds: emphasized (500ms · emphasized) / '
          'standard (300ms · standard) / decelerate (250ms · '
          'emphasizedDecelerate) / accelerate (200ms · '
          'emphasizedAccelerate).',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pageId': <String, dynamic>{'type': 'string'},
          'kind': <String, dynamic>{
            'type': 'string',
            'enum': <String>[
              'emphasized',
              'standard',
              'decelerate',
              'accelerate',
            ],
          },
          'dryRun': <String, dynamic>{'type': 'boolean', 'default': false},
        },
        'required': <String>['pageId', 'kind'],
      },
    },
    <String, dynamic>{
      'name': 'token_usage',
      'description':
          'List every reference to a single theme token role across '
          'the canonical. Returns the role definition + usage '
          'list with `{path, widgetPath, property, expr}`. Use '
          'before changing a token color to preview which '
          'widgets will repaint.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'role': <String, dynamic>{
            'type': 'string',
            'description': 'Token role (e.g. `primary`, `onSurface`).',
          },
          'domain': <String, dynamic>{
            'type': 'string',
            'description':
                'Theme domain (default: `color`). Other domains: '
                '`spacing`, `shape`, `elevation`, etc.',
            'default': 'color',
          },
        },
        'required': <String>['role'],
      },
    },
    <String, dynamic>{
      'name': 'swap_widget',
      'description':
          'Swap a widget at `path` to `newType`, transferring '
          'compatible properties (matched by name against the '
          'target widget schema). Returns `{kept, dropped}` so '
          'authors see what survives. Pass `dryRun:true` to '
          'preview.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string'},
          'newType': <String, dynamic>{'type': 'string'},
          'dryRun': <String, dynamic>{'type': 'boolean', 'default': false},
        },
        'required': <String>['path', 'newType'],
      },
    },
    <String, dynamic>{
      'name': 'a11y_audit',
      'description':
          'Accessibility audit (WCAG 2.1 AA + Material). Flags '
          'buttons without accessible names, icon/image without '
          '`semanticLabel`, inputs without label/hint, very '
          'small text (<12dp), touch targets <48dp, and similar. '
          'Read-only — pass `pageId` for page scope or omit for '
          'app scope.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pageId': <String, dynamic>{'type': 'string'},
        },
      },
    },
    <String, dynamic>{
      'name': 'asset_audit',
      'description':
          'Audit /manifest/assets for entries whose `contentRef` '
          'does not match the AssetRef spec (5 schemes: '
          'bundle://, http(s)://, data:, assets/, client://). '
          'Returns invalid entries; pass `apply:true` to migrate '
          '— material:<name> entries become bare names, widget '
          '`bundle://<id>` references rewrite to the resolved '
          'value, invalid entries are dropped.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'apply': <String, dynamic>{
            'type': 'boolean',
            'default': false,
            'description':
                'When true, performs the migration. '
                'Default false = dry-run.',
          },
        },
      },
    },
    <String, dynamic>{
      'name': 'extract_i18n',
      'description':
          'Walk a page widget tree, lift literal `text.content` and '
          '`button.label` strings into /ui/i18n/text/<locale>, '
          'and rewrite the widget property to `{{i18n.text.<key'
          '>}}` bindings. Identical strings deduplicate to the '
          'same key. Existing bindings are skipped. Pass '
          '`dryRun:true` to preview.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pageId': <String, dynamic>{'type': 'string'},
          'locale': <String, dynamic>{
            'type': 'string',
            'description':
                'BCP-47 target locale. Defaults to /ui/i18n/'
                'defaultLocale or "en".',
          },
          'keyPrefix': <String, dynamic>{
            'type': 'string',
            'description': 'Key prefix (default = pageId).',
          },
          'dryRun': <String, dynamic>{'type': 'boolean', 'default': false},
        },
        'required': <String>['pageId'],
      },
    },
    <String, dynamic>{
      'name': 'navigation_item_style_set',
      'description':
          'Set NavigationStyle slot for one nav item — '
          '/ui/navigation/items/<index>/style/<slot>. Layered '
          'over the surface-level NavigationConfig.style.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'index': <String, dynamic>{'type': 'integer'},
          'slot': <String, dynamic>{'type': 'string'},
          'value': <String, dynamic>{},
          'style': <String, dynamic>{'type': 'object'},
        },
        'required': <String>['index'],
      },
    },
    <String, dynamic>{
      'name': 'navigation_style_set',
      'description':
          'Set NavigationStyle slots under /ui/navigation/style. '
          'Pass `slot`+`value` to upsert one field (dotted form '
          'allowed: `iconStyle.color`), or `style` to fully '
          'replace the style object.',
      'parameters': <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'slot': <String, dynamic>{
            'type': 'string',
            'description':
                'NavigationStyle key (backgroundColor / indicator '
                'Color / dividerColor / dividerThickness / '
                'dividerIndent / labelStyle / iconStyle / '
                'selectedColor / unselectedColor / elevation / '
                'backgroundImage / indicatorShape).',
          },
          'value': <String, dynamic>{},
          'style': <String, dynamic>{'type': 'object'},
        },
      },
    },
  ];

  static const Set<String> claimedTools = <String>{
    'pack_bundle',
    'run_shell',
    'read_build_guide',
    'project_info',
    'get_build_config',
    'run_build',
    'preview_capture',
    'layout_snapshot',
    'bundle_outline',
    'get_section',
    'tree_outline',
    'get_widget',
    'set_property',
    'add_child',
    'move_widget',
    'delete_widget',
    'replace_subtree',
    'find_widgets',
    'check_wiring',
    'rename_page',
    'extract_template',
    'inline_template',
    'duplicate_page',
    'state_usage',
    'binding_dependencies',
    'apply_theme_preset',
    'apply_layout_preset',
    'validate_bundle',
    'i18n_locale_add',
    'i18n_locale_remove',
    'service_set',
    'service_remove',
    'template_library_add',
    'template_library_remove',
    'theme_preset_set',
    'theme_font_set',
    'theme_font_remove',
    'navigation_style_set',
    'i18n_text_set',
    'i18n_pluralization_set',
    'i18n_text_direction_set',
    'navigation_item_style_set',
    'asset_audit',
    'extract_i18n',
    'a11y_audit',
    'token_usage',
    'swap_widget',
    'animation_preset',
    'widget_diff',
    'spec_card',
    'health_check',
    'a11y_quick_fix',
    'rename_template',
    'rename_state_key',
    'rename_route',
    'release_check',
    'apply_recipe',
    'grade',
    'pending_diff',
    'help',
    'apply_to_each',
    'state_propose',
    'search',
    'page_create',
    'diff_apply',
    'route_audit',
    'undo_history',
    'find_references',
    'dependency_graph',
    'tokenization_audit',
    'extract_to_template',
    'widget_lint',
    'widget_shape_audit',
  };
}

/// Helper used by [_dispatchTool] in vibe_llm to encode the tool result
/// into the LlmMessage.tool payload.
String encodeBuildToolResult(BuildToolResult r) => jsonEncode(r.toJson());

extension on BuildToolResult {
  void _appendPayload(String _) {
    /* placeholder for future enrichment */
  }
}
