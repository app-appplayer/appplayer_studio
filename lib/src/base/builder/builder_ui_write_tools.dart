/// Registers the five atomic write `studio.builder.ui.*` tools
/// (P3.1 of studio-builder-rebuild — without schema validation).
///
/// - `addNode`
/// - `setProp`
/// - `removeNode`
/// - `moveNode`
/// - `reorderChildren`
///
/// Every tool accepts an optional `dryRun: true` to validate path
/// resolution + structural pre-conditions without committing the
/// change. Schema-driven validation (props · enum · required ·
/// children arity) lands in P3.2 as a small `SchemaValidator`
/// helper layered between the tool handler and the write service.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'builder_library_tools.dart' show ActiveMbdResolver;
import 'builder_ui_read_service.dart';
import 'builder_ui_write_service.dart';
import 'schema_validator.dart';

String? _resolveMbdPath(
  Map<String, dynamic> args,
  ActiveMbdResolver? resolver,
) {
  final raw = args['mbdPath'];
  if (raw is String && raw.isNotEmpty) return raw;
  return resolver?.call();
}

void registerUiWriteTools(
  mk.KernelServerHost boot, {
  required BuilderUiWriteService writer,
  required BuilderUiReadService reader,
  required SchemaValidator validator,
  ActiveMbdResolver? resolveActiveMbdPath,
}) {
  // ── addNode ─────────────────────────────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.addNode',
    description:
        'Insert a new node at JSON Pointer `path`. When the target '
        'parent is a list, `position` picks the index (default = '
        'end). When the parent is a map, `path` names the new key '
        'slot directly and the value is created (or replaced). '
        'Omit `mbdPath` to target the active project. Pass `dryRun: '
        'true` to validate without committing.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'path': <String, dynamic>{'type': 'string'},
        'position': <String, dynamic>{'type': 'integer'},
        'node': <String, dynamic>{
          'type': 'object',
          'description': 'The widget node to insert (`{type, ...}`).',
        },
        'dryRun': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['path', 'node'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final path = args['path'] as String?;
      final node = args['node'];
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'addNode has no active project — pass mbdPath or open '
              'a project first.',
        );
      }
      if (path == null || node == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'path, node',
          actual: <String, dynamic>{
            'path': path,
            'node': node?.runtimeType.toString(),
          },
          message: 'addNode requires path and node.',
          suggestion:
              'Pass {"path": "<JSON Pointer>", '
              '"node": {"type": "<widget type>", ...}}.',
        );
      }
      final position =
          args['position'] is num ? (args['position'] as num).toInt() : null;
      final dryRun = args['dryRun'] == true;
      // Schema validation first — catches unknownType / missing
      // required / propTypeMismatch / enumOutOfRange / extraProperty
      // before the writer ever touches ui/app.json.
      final v = await validator.validateNode(node);
      if (!v.ok) {
        return _rejectMap(v.rejection!);
      }
      try {
        final r = await writer.addNode(
          mbdPath: mbd,
          path: path,
          position: position,
          node: node,
          dryRun: dryRun,
        );
        return _ok(r);
      } on FormatException catch (e) {
        return _reject(
          code: 'pathNotFound',
          path: path,
          message: e.message,
          suggestion:
              'Use studio.builder.ui.readTree to verify the parent '
              'path exists.',
        );
      }
    },
  );

  // ── setProp ─────────────────────────────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.setProp',
    description:
        'Set one property on a single node. Path resolves to the '
        'node (a map) and `key` names the property to replace or '
        'create. `value` is any JSON type (string / number / bool '
        '/ list / map / null). Omit `mbdPath` to target the active '
        'project. Use this for atomic prop tweaks without rewriting '
        'the whole node.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'path': <String, dynamic>{'type': 'string'},
        'key': <String, dynamic>{'type': 'string'},
        'value': <String, dynamic>{'description': 'Any JSON value.'},
        'dryRun': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['path', 'key'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final path = args['path'] as String?;
      final key = args['key'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'setProp has no active project — pass mbdPath or open '
              'a project first.',
        );
      }
      if (path == null || key == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'path, key',
          message: 'setProp requires path and key.',
          suggestion:
              'Pass {"path": ..., "key": "<prop>", '
              '"value": <any JSON>}.',
        );
      }
      final dryRun = args['dryRun'] == true;
      // Resolve the target node's `type` so the validator can pick
      // the right schema. Read failure folds into pathNotFound.
      String? nodeType;
      try {
        final node = await reader.readNode(mbd, path);
        nodeType = node['type'] as String?;
      } on FormatException catch (e) {
        return _reject(
          code: 'pathNotFound',
          path: path,
          message: e.message,
          suggestion:
              'Use studio.builder.ui.readNode to verify the node '
              'exists.',
        );
      }
      if (nodeType == null) {
        return _reject(
          code: 'propTypeMismatch',
          path: path,
          expected: 'a Map node with a `type` field',
          message:
              'setProp can only target widget nodes (Map with type), '
              'not primitives or lists.',
          suggestion: 'Use addNode / removeNode on non-widget slots.',
        );
      }
      final v = await validator.validateProp(
        type: nodeType,
        key: key,
        value: args['value'],
      );
      if (!v.ok) {
        return _rejectMap(v.rejection!);
      }
      try {
        final r = await writer.setProp(
          mbdPath: mbd,
          path: path,
          key: key,
          value: args['value'],
          dryRun: dryRun,
        );
        return _ok(r);
      } on FormatException catch (e) {
        return _reject(
          code: 'pathNotFound',
          path: path,
          message: e.message,
          suggestion:
              'Use studio.builder.ui.readNode to verify the node '
              'exists and is a map.',
        );
      }
    },
  );

  // ── removeNode ──────────────────────────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.removeNode',
    description:
        'Remove the node at JSON Pointer `path` (and its entire '
        'subtree). List elements collapse, map keys disappear. '
        'Omit `mbdPath` to target the active project. Cannot target '
        'the root (`""`).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'path': <String, dynamic>{'type': 'string'},
        'dryRun': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['path'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final path = args['path'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'removeNode has no active project — pass mbdPath or '
              'open a project first.',
        );
      }
      if (path == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'path (string)',
          message: 'removeNode requires path.',
        );
      }
      final dryRun = args['dryRun'] == true;
      try {
        final r = await writer.removeNode(
          mbdPath: mbd,
          path: path,
          dryRun: dryRun,
        );
        return _ok(r);
      } on FormatException catch (e) {
        return _reject(code: 'pathNotFound', path: path, message: e.message);
      }
    },
  );

  // ── moveNode ────────────────────────────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.moveNode',
    description:
        'Move the node at `fromPath` to `toPath`. If `toPath`\'s '
        'parent is a list, `position` picks the insert index '
        '(default = end). Omit `mbdPath` to target the active '
        'project. Removes from the source first; index shifts '
        'within the same list parent honour the post-remove tree '
        '(json-patch convention).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'fromPath': <String, dynamic>{'type': 'string'},
        'toPath': <String, dynamic>{'type': 'string'},
        'position': <String, dynamic>{'type': 'integer'},
        'dryRun': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['fromPath', 'toPath'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final fp = args['fromPath'] as String?;
      final tp = args['toPath'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'moveNode has no active project — pass mbdPath or '
              'open a project first.',
        );
      }
      if (fp == null || tp == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'fromPath, toPath',
          message: 'moveNode requires fromPath and toPath.',
        );
      }
      final position =
          args['position'] is num ? (args['position'] as num).toInt() : null;
      final dryRun = args['dryRun'] == true;
      try {
        final r = await writer.moveNode(
          mbdPath: mbd,
          fromPath: fp,
          toPath: tp,
          position: position,
          dryRun: dryRun,
        );
        return _ok(r);
      } on FormatException catch (e) {
        return _reject(code: 'pathNotFound', message: e.message);
      }
    },
  );

  // ── applyPatch (P4 — RFC 6902 batch) ────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.applyPatch',
    description:
        'Apply a JSON-Patch (RFC 6902) batch of ops atomically. Each '
        'op is one of `{op:"add"|"remove"|"replace"|"move"|"copy"|'
        '"test", path, value?, from?}`. Every widget value goes '
        'through the same schema validation as `addNode` first; '
        'any single op failure rejects the whole batch (response '
        'includes the offending `opIndex`). Use this when an LLM '
        'has multiple changes that should land together — saves a '
        'round-trip per op and keeps the on-disk ui/app.json '
        'consistent under partial failures. Pair with `dryRun: '
        'true` for an LLM to pre-flight a batch before commit.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'ops': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{
            'type': 'object',
            'description': 'RFC 6902 op (`{op, path, value?, from?}`).',
          },
        },
        'dryRun': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['ops'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final rawOps = args['ops'];
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'applyPatch has no active project — pass mbdPath or '
              'open a project first.',
        );
      }
      if (rawOps is! List) {
        return _reject(
          code: 'missingRequired',
          expected: 'ops (array)',
          message: 'applyPatch requires ops.',
          suggestion: 'Pass {"ops": [{"op":"add","path":...}, ...]}.',
        );
      }
      final dryRun = args['dryRun'] == true;
      try {
        final r = await writer.applyPatch(
          mbdPath: mbd,
          ops: rawOps,
          dryRun: dryRun,
          validateNode: (node) async {
            final v = await validator.validateNode(node);
            return v.ok ? null : v.rejection;
          },
        );
        if (r['ok'] == false) {
          return _rejectMap(r);
        }
        return _ok(r);
      } on FormatException catch (e) {
        // Disambiguate the throws coming back from _applyOp: `test`
        // op failures and unknown / malformed op headers map to
        // distinct §4 codes so LLM callers can branch on them.
        final msg = e.message;
        String code;
        if (msg.startsWith('test op failed')) {
          code = 'testFailed';
        } else if (msg.startsWith('unknown op') ||
            msg.contains('missing `op`') ||
            msg.contains('missing `path`') ||
            msg.contains('requires `from`')) {
          code = 'invalidOp';
        } else {
          code = 'pathNotFound';
        }
        return _reject(
          code: code,
          message: msg,
          suggestion:
              'Verify each op\'s path / shape with readTree + the '
              'RFC 6902 spec before retrying. No partial commit '
              'happened — ui/app.json is unchanged.',
        );
      }
    },
  );

  // ── reorderChildren ─────────────────────────────────────────
  boot.addTool(
    name: 'studio.builder.ui.reorderChildren',
    description:
        'Reorder a list at `path` using `order` — an index '
        'permutation whose length equals the current list length. '
        'New element `i` is the old element at `order[i]`. Omit '
        '`mbdPath` to target the active project. Useful for '
        'promoting / demoting a child without touching props.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'path': <String, dynamic>{'type': 'string'},
        'order': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'integer'},
          'description': 'Permutation of [0..n) where n is the list length.',
        },
        'dryRun': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['path', 'order'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final path = args['path'] as String?;
      final rawOrder = args['order'];
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'reorderChildren has no active project — pass mbdPath '
              'or open a project first.',
        );
      }
      if (path == null || rawOrder is! List) {
        return _reject(
          code: 'missingRequired',
          expected: 'path, order:int[]',
          message: 'reorderChildren requires path and order (int list).',
        );
      }
      final order = <int>[
        for (final o in rawOrder)
          if (o is num) o.toInt() else -1,
      ];
      final dryRun = args['dryRun'] == true;
      try {
        final r = await writer.reorderChildren(
          mbdPath: mbd,
          path: path,
          order: order,
          dryRun: dryRun,
        );
        return _ok(r);
      } on FormatException catch (e) {
        return _reject(
          code: 'childArityViolation',
          path: path,
          message: e.message,
          suggestion:
              'order must be a permutation of [0..n) where n is the '
              'list length. Use readNode to inspect the list first.',
        );
      }
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
}) => mk.KernelToolResult(
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

/// Validator → MCP rejection. The validator already produced the
/// §4-shaped map (`code` / `path?` / `expected?` / `actual?` /
/// `message` / `suggestion?`); we just wrap it as an MCP error.
mk.KernelToolResult _rejectMap(Map<String, dynamic> rejection) =>
    mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(
          text: jsonEncode(<String, dynamic>{'ok': false, ...rejection}),
        ),
      ],
      isError: true,
    );
