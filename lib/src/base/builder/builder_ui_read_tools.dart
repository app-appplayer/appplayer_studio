/// Registers the four read-side `studio.builder.ui.*` MCP tools
/// (P2 of studio-builder-rebuild):
///
/// - `studio.builder.ui.readNode`   — one node by JSON Pointer path
/// - `studio.builder.ui.readTree`   — subtree at path with depth cap
/// - `studio.builder.ui.findNodes`  — paths matching typeOf / propEq
/// - `studio.builder.ui.diff`       — RFC-6902-shaped op list between
///   two subtrees of the same bundle (or two inline trees passed
///   `from` / `to` directly).
///
/// All path inputs are JSON Pointer (RFC 6901). Failures translate
/// into the §4 diagnostic shape so external LLMs receive
/// `{ok:false, code, path, expected, actual, message, suggestion}`.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'builder_library_tools.dart' show ActiveMbdResolver;
import 'builder_ui_read_service.dart';

String? _resolveMbdPath(
  Map<String, dynamic> args,
  ActiveMbdResolver? resolver,
) {
  final raw = args['mbdPath'];
  if (raw is String && raw.isNotEmpty) return raw;
  return resolver?.call();
}

void registerUiReadTools(
  mk.KernelServerHost boot, {
  required BuilderUiReadService reader,
  ActiveMbdResolver? resolveActiveMbdPath,
}) {
  // ── readNode ────────────────────────────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.readNode',
    description:
        'Return type + props + child path summary for one node in '
        '<mbdPath>/ui/app.json. Path is a JSON Pointer (RFC 6901) — '
        'e.g. `""` for the root page, `/content/children/0/child` '
        'for the first center column. Children are returned as a '
        'list of JSON Pointer paths (one level deep) so callers '
        'can recurse via additional readNode / readTree calls '
        'without materialising the whole tree.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'path': <String, dynamic>{
          'type': 'string',
          'description': 'JSON Pointer to the node. Use `""` for root.',
        },
      },
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'readNode has no active project — pass mbdPath or open '
              'a project first.',
        );
      }
      final path = (args['path'] as String?) ?? '';
      try {
        final node = await reader.readNode(mbd, path);
        return _ok(node);
      } on FormatException catch (e) {
        return _reject(
          code: 'pathNotFound',
          path: path,
          expected: 'valid JSON Pointer that resolves inside the tree',
          actual: path,
          message: e.message,
          suggestion:
              'Call studio.builder.ui.readTree with a shallow depth '
              'to discover valid paths.',
        );
      }
    },
  );

  // ── readTree ────────────────────────────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.readTree',
    description:
        'Return the subtree at JSON Pointer `path` (default: root) '
        'capped to `depth` levels. Anything deeper renders as the '
        'string `"<truncated>"` so the response stays bounded. Omit '
        '`mbdPath` to target the active project. Default depth = '
        'unbounded — caller is responsible for choosing a reasonable '
        'cap on large trees.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'path': <String, dynamic>{
          'type': 'string',
          'description': 'JSON Pointer to the subtree root. Default `""`.',
        },
        'depth': <String, dynamic>{
          'type': 'integer',
          'description': 'Max levels to include. Omit for full tree.',
        },
      },
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'readTree has no active project — pass mbdPath or open '
              'a project first.',
        );
      }
      final path = (args['path'] as String?) ?? '';
      final depth =
          args['depth'] is num ? (args['depth'] as num).toInt() : null;
      try {
        final tree = await reader.readTree(mbd, path: path, depth: depth);
        return _ok(tree);
      } on FormatException catch (e) {
        return _reject(
          code: 'pathNotFound',
          path: path,
          expected: 'valid JSON Pointer',
          actual: path,
          message: e.message,
          suggestion:
              'Call readTree with an empty path first to see the '
              'root shape.',
        );
      }
    },
  );

  // ── findNodes ───────────────────────────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.findNodes',
    description:
        'Walk the entire tree and return JSON-Pointer paths of '
        'every node that matches the filters. `typeOf` matches '
        '`node["type"]` exactly. `propEq` is a map of '
        '`{prop: value}` pairs each of which must equal '
        '`node[prop]`. Both optional — omitting both returns every '
        'node path in the tree (handy for size sanity-checks).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'typeOf': <String, dynamic>{
          'type': 'string',
          'description': 'Exact-match widget type (e.g. `VbuTabStrip`).',
        },
        'propEq': <String, dynamic>{
          'type': 'object',
          'description':
              'Map of prop key → expected value. All pairs must match.',
        },
      },
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'findNodes has no active project — pass mbdPath or '
              'open a project first.',
        );
      }
      final typeOf = args['typeOf'] as String?;
      final propEq =
          args['propEq'] is Map
              ? (args['propEq'] as Map).cast<String, Object?>()
              : null;
      try {
        final paths = await reader.findNodes(
          mbd,
          typeOf: typeOf,
          propEq: propEq,
        );
        return _ok(<String, dynamic>{'paths': paths});
      } on FormatException catch (e) {
        return _reject(
          code: 'pathNotFound',
          message: e.message,
          suggestion: 'Verify ui/app.json exists at <mbdPath>/ui/.',
        );
      }
    },
  );

  // ── diff ─────────────────────────────────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.diff',
    description:
        'Return a list of RFC-6902-shaped ops (`add`/`remove`/'
        '`replace` + `path` + `value?`) describing every leaf-level '
        'difference between two subtrees. Two input modes:\n'
        '  • `from` / `to` (inline JSON trees) — caller supplies '
        'both already-decoded trees (e.g. snapshots from readTree).\n'
        '  • `mbdPath` + `fromPath` / `toPath` — diff two paths '
        'inside the same bundle (e.g. compare two page entries).\n'
        'Use after a write mutator to verify the intended change '
        'landed (do not trust `ok:true` alone — §13.3).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'fromPath': <String, dynamic>{'type': 'string'},
        'toPath': <String, dynamic>{'type': 'string'},
        'from': <String, dynamic>{'description': 'Inline JSON tree.'},
        'to': <String, dynamic>{'description': 'Inline JSON tree.'},
      },
    },
    handler: (args) async {
      Object? from;
      Object? to;
      if (args.containsKey('from') || args.containsKey('to')) {
        from = args['from'];
        to = args['to'];
      } else {
        final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
        final fp = args['fromPath'] as String? ?? '';
        final tp = args['toPath'] as String? ?? '';
        if (mbd == null) {
          return _reject(
            code: 'noActiveProject',
            expected: 'either {from,to} or active project + fromPath/toPath',
            message:
                'diff needs inline trees OR a bundle path + two '
                'JSON-Pointer paths.',
            suggestion:
                'Pass {"from": ..., "to": ...} or open a project '
                'first (or pass mbdPath explicitly).',
          );
        }
        try {
          final fromTree = await reader.readTree(mbd, path: fp);
          final toTree = await reader.readTree(mbd, path: tp);
          from = fromTree['tree'];
          to = toTree['tree'];
        } on FormatException catch (e) {
          return _reject(
            code: 'pathNotFound',
            message: e.message,
            suggestion: 'Use readTree to verify fromPath and toPath resolve.',
          );
        }
      }
      final ops = await reader.diff(from, to);
      return _ok(<String, dynamic>{'ops': ops});
    },
  );
}

mk.KernelToolResult _ok(Object payload) => mk.KernelToolResult(
  content: <mk.KernelContent>[mk.KernelTextContent(text: jsonEncode(payload))],
);

mk.KernelToolResult _reject({
  required String code,
  String? path,
  Object? expected,
  Object? actual,
  required String message,
  String? suggestion,
}) {
  return mk.KernelToolResult(
    content: <mk.KernelContent>[
      mk.KernelTextContent(
        text: jsonEncode(<String, dynamic>{
          'ok': false,
          'code': code,
          if (path != null) 'path': path,
          if (expected != null) 'expected': expected,
          if (actual != null) 'actual': actual,
          'message': message,
          if (suggestion != null) 'suggestion': suggestion,
        }),
      ),
    ],
    isError: true,
  );
}
