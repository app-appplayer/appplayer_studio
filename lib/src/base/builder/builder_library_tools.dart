/// Registers the eight `studio.builder.lib.*` tools (P5 + placeInline
/// + placeAsTemplate).
///
/// 1. `list`            — instance id list
/// 2. `read`            — one instance's stored tree
/// 3. `create`          — new instance (optional initial tree)
/// 4. `delete`          — remove one instance
/// 5. `rename`          — change instance id
/// 6. `render`          — isolated screenshot (host integration TODO —
///                        for now returns `{ok:true, todo:"host
///                        renderer hookup"}` so the surface lands
///                        without blocking on the PreviewMcpUi atom
///                        registration).
/// 7. `placeInline`     — read a stored entry, substitute
///                        `{{paramName}}` against caller params, and
///                        `addNode` the resolved tree into
///                        `ui/app.json` at the given parent path. The
///                        persisted ui contains the fully expanded
///                        subtree — no runtime reference is left
///                        behind.
/// 8. `placeAsTemplate` — register the stored entry under
///                        `ApplicationDefinition.templates[<name>]`
///                        (idempotent — same encoded JSON no-ops;
///                        different + `force:false` rejects) and
///                        `addNode` a `{type:"use", template, params}`
///                        site at the given parent path. Library
///                        edits to that entry will reflow through
///                        every `use` after a re-register.
library;

import 'dart:convert';

import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'builder_library_service.dart';
import 'builder_ui_write_service.dart';
import 'schema_validator.dart';

/// Resolves the active project's `.mbd` path when a tool's caller
/// omits `mbdPath` from its arguments. Wired by the host (see
/// `vibe_studio_host_app.dart`) against `chromeBridge.activeProjectInfo`.
typedef ActiveMbdResolver = String? Function();

/// Read `mbdPath` from [args] or fall back to the active-project
/// resolver. Returns null when both are absent — callers map that to
/// a `noActiveProject` rejection.
String? _resolveMbdPath(
  Map<String, dynamic> args,
  ActiveMbdResolver? resolver,
) {
  final raw = args['mbdPath'];
  if (raw is String && raw.isNotEmpty) return raw;
  return resolver?.call();
}

void registerLibraryTools(
  mk.KernelServerHost boot, {
  required BuilderLibraryService library,
  required BuilderUiWriteService writer,
  required SchemaValidator validator,
  ActiveMbdResolver? resolveActiveMbdPath,
}) {
  boot.addTool(
    name: 'studio.builder.lib.list',
    description:
        'List every instance id stored in the project library '
        '(`<projectPath>/library/<id>.json`, sibling of the active '
        '.mbd). Omit `mbdPath` to target the active project; pass '
        'explicitly to operate on another project.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
      },
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'lib.list has no active project — pass mbdPath or open '
              'a project in Studio Builder first.',
        );
      }
      final ids = await library.list(mbd);
      return _ok(<String, dynamic>{'ids': ids});
    },
  );

  boot.addTool(
    name: 'studio.builder.lib.read',
    description:
        'Return the stored JSON tree for one library instance. '
        'Omit `mbdPath` to target the active project. Returns '
        '`pathNotFound` when no entry exists for the id.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'id': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['id'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final id = args['id'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'lib.read has no active project — pass mbdPath or open '
              'a project first.',
        );
      }
      if (id == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'id (string)',
          message: 'lib.read requires id.',
        );
      }
      try {
        final tree = await library.read(mbd, id);
        return _ok(<String, dynamic>{'id': id, 'tree': tree});
      } on FormatException catch (e) {
        return _reject(
          code:
              e.message.contains('id must match')
                  ? 'invalidId'
                  : 'pathNotFound',
          message: e.message,
          suggestion: 'Call studio.builder.lib.list to see registered ids.',
        );
      }
    },
  );

  boot.addTool(
    name: 'studio.builder.lib.create',
    description:
        'Create a new library instance. `tree` seeds the body '
        '(omit for an empty stub). Omit `mbdPath` to target the '
        'active project. Rejects when an entry with the same id '
        'already exists — use `delete` + `create`, or `rename`, '
        'for explicit replacement.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'id': <String, dynamic>{'type': 'string'},
        'tree': <String, dynamic>{
          'description': 'Initial JSON tree (any JSON value).',
        },
      },
      'required': <String>['id'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final id = args['id'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'lib.create has no active project — pass mbdPath or '
              'open a project first.',
        );
      }
      if (id == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'id (string)',
          message: 'lib.create requires id.',
        );
      }
      try {
        await library.create(mbd, id, tree: args['tree']);
        return _ok(<String, dynamic>{'ok': true, 'id': id});
      } on FormatException catch (e) {
        return _reject(
          code:
              e.message.contains('already exists')
                  ? 'alreadyExists'
                  : (e.message.contains('id must match')
                      ? 'invalidId'
                      : 'pathNotFound'),
          message: e.message,
        );
      }
    },
  );

  boot.addTool(
    name: 'studio.builder.lib.delete',
    description:
        'Remove one library instance. Omit `mbdPath` to target the '
        'active project. Rejects when no matching entry exists (so '
        'accidental deletes surface).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'id': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['id'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final id = args['id'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'lib.delete has no active project — pass mbdPath or '
              'open a project first.',
        );
      }
      if (id == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'id (string)',
          message: 'lib.delete requires id.',
        );
      }
      try {
        await library.delete(mbd, id);
        return _ok(<String, dynamic>{'ok': true, 'id': id});
      } on FormatException catch (e) {
        return _reject(code: 'pathNotFound', message: e.message);
      }
    },
  );

  boot.addTool(
    name: 'studio.builder.lib.rename',
    description:
        'Change an instance id from `oldId` to `newId`. Omit '
        '`mbdPath` to target the active project. Rejects when '
        '`oldId` is missing or `newId` already exists. Does NOT '
        'rewrite intra-tree references — that lands together with '
        'the `use` widget shape in a follow-up phase.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'oldId': <String, dynamic>{'type': 'string'},
        'newId': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['oldId', 'newId'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final oldId = args['oldId'] as String?;
      final newId = args['newId'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'lib.rename has no active project — pass mbdPath or '
              'open a project first.',
        );
      }
      if (oldId == null || newId == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'oldId, newId',
          message: 'lib.rename requires oldId and newId.',
        );
      }
      try {
        await library.rename(mbd, oldId, newId);
        return _ok(<String, dynamic>{
          'ok': true,
          'oldId': oldId,
          'newId': newId,
        });
      } on FormatException catch (e) {
        return _reject(
          code:
              e.message.contains('already exists')
                  ? 'alreadyExists'
                  : 'pathNotFound',
          message: e.message,
        );
      }
    },
  );

  boot.addTool(
    name: 'studio.builder.lib.render',
    description:
        'Take an isolated screenshot of one library instance — '
        'mount its tree alone (no app shell, no other library '
        'entries) and capture. Omit `mbdPath` to target the active '
        'project. NOTE: host integration is pending — returns a '
        'TODO marker today; the real handler will plug into the '
        'host\'s renderer once the PreviewMcpUi atom lands (#15).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'id': <String, dynamic>{'type': 'string'},
      },
      'required': <String>['id'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final id = args['id'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'lib.render has no active project — pass mbdPath or '
              'open a project first.',
        );
      }
      if (id == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'id (string)',
          message: 'lib.render requires id.',
        );
      }
      // Verify entry exists so the placeholder still surfaces real
      // lookup errors.
      try {
        await library.read(mbd, id);
      } on FormatException catch (e) {
        return _reject(
          code: 'pathNotFound',
          message: e.message,
          suggestion: 'Call studio.builder.lib.list to confirm the id.',
        );
      }
      return _ok(<String, dynamic>{
        'ok': true,
        'id': id,
        'todo':
            'host renderer hookup pending — PreviewMcpUi atom (#15) '
            'needs to land before isolated screenshot is wired.',
      });
    },
  );

  boot.addTool(
    name: 'studio.builder.lib.placeInline',
    description:
        'Place a library instance inline into ui/app.json. Reads '
        'the stored entry, substitutes `{{paramName}}` placeholders '
        'with `params` values, validates the resolved root via the '
        'shared schema validator, then `addNode`s the tree at '
        '`parentPath` (with optional `position`). Omit `mbdPath` to '
        'target the active project. The persisted ui holds the '
        'fully expanded subtree — no runtime template reference is '
        'created. Pass `dryRun: true` to verify the resolution and '
        'parent path without committing.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'parentPath': <String, dynamic>{'type': 'string'},
        'libId': <String, dynamic>{'type': 'string'},
        'params': <String, dynamic>{
          'type': 'object',
          'description':
              'Values for {{paramName}} substitution. A whole-string '
              '`{{x}}` returns the param value as-is so non-string '
              'params keep their type.',
        },
        'position': <String, dynamic>{'type': 'integer'},
        'dryRun': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['parentPath', 'libId'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final parentPath = args['parentPath'] as String?;
      final libId = args['libId'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'lib.placeInline has no active project — pass mbdPath '
              'or open a project first.',
        );
      }
      if (parentPath == null || libId == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'parentPath, libId',
          message: 'lib.placeInline requires parentPath and libId.',
          suggestion:
              'Pass {"parentPath": "<JSON Pointer>", '
              '"libId": "<library entry id>", "params": {...}}.',
        );
      }
      final rawParams = args['params'];
      final params =
          rawParams is Map
              ? rawParams.cast<String, Object?>()
              : const <String, Object?>{};
      final position =
          args['position'] is num ? (args['position'] as num).toInt() : null;
      final dryRun = args['dryRun'] == true;

      ({Object? tree, List<String> warnings}) resolved;
      try {
        resolved = await library.resolveInline(mbd, libId, params);
      } on FormatException catch (e) {
        return _reject(
          code:
              e.message.contains('id must match')
                  ? 'invalidId'
                  : 'pathNotFound',
          message: e.message,
          suggestion: 'Call studio.builder.lib.list to confirm the entry id.',
        );
      }

      final tree = resolved.tree;
      if (tree == null) {
        return _reject(
          code: 'emptyEntry',
          message:
              'library entry "$libId" resolved to null — nothing to '
              'insert. Seed the entry with lib.create({tree: {...}}).',
        );
      }
      // Validate the resolved root through the same schema gate the
      // ui write tools use. Lets unknownType / extraProperty land
      // before we mutate ui/app.json.
      final v = await validator.validateNode(tree);
      if (!v.ok) {
        return _rejectMap(v.rejection!);
      }

      try {
        final r = await writer.addNode(
          mbdPath: mbd,
          path: parentPath,
          position: position,
          node: tree,
          dryRun: dryRun,
        );
        final payload = <String, dynamic>{
          ...r,
          'libId': libId,
          if (resolved.warnings.isNotEmpty) 'warnings': resolved.warnings,
        };
        return _ok(payload);
      } on FormatException catch (e) {
        return _reject(
          code: 'pathNotFound',
          message: e.message,
          suggestion: 'Use studio.builder.ui.readTree to verify parentPath.',
        );
      }
    },
  );

  boot.addTool(
    name: 'studio.builder.lib.placeAsTemplate',
    description:
        'Register a library entry under '
        '`ApplicationDefinition.templates[<templateName||libId>]` and '
        'place a `{type:"use", template, params}` site at '
        '`parentPath`. The library tree itself stays the source of '
        'truth — subsequent library edits + re-register flow through '
        'every use. Idempotent: same encoded JSON re-registers as a '
        'no-op; a different body rejects with `alreadyExists` unless '
        '`force:true`. `params` lands on the use site (resolved at '
        'render time by the template runtime — not pre-substituted). '
        'Pass `dryRun:true` to verify without committing.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Optional. Defaults to the active project\'s .mbd.',
        },
        'parentPath': <String, dynamic>{'type': 'string'},
        'libId': <String, dynamic>{'type': 'string'},
        'templateName': <String, dynamic>{
          'type': 'string',
          'description':
              'Optional. Name to register under templates[]. '
              'Defaults to libId.',
        },
        'params': <String, dynamic>{
          'type': 'object',
          'description':
              'Use-site params. Forwarded verbatim to the `use` '
              'widget — the runtime resolves `{{param}}` against '
              'these at render time. (Not pre-substituted, unlike '
              'placeInline.)',
        },
        'position': <String, dynamic>{'type': 'integer'},
        'force': <String, dynamic>{
          'type': 'boolean',
          'description':
              'Default false. When the template name already holds a '
              'different body, true overwrites; false rejects.',
        },
        'dryRun': <String, dynamic>{'type': 'boolean'},
      },
      'required': <String>['parentPath', 'libId'],
    },
    handler: (args) async {
      final mbd = _resolveMbdPath(args, resolveActiveMbdPath);
      final parentPath = args['parentPath'] as String?;
      final libId = args['libId'] as String?;
      if (mbd == null) {
        return _reject(
          code: 'noActiveProject',
          message:
              'lib.placeAsTemplate has no active project — pass '
              'mbdPath or open a project first.',
        );
      }
      if (parentPath == null || libId == null) {
        return _reject(
          code: 'missingRequired',
          expected: 'parentPath, libId',
          message: 'lib.placeAsTemplate requires parentPath and libId.',
          suggestion:
              'Pass {"parentPath": "<JSON Pointer>", '
              '"libId": "<library entry id>", '
              '"templateName": "<optional>", "params": {...}}.',
        );
      }
      final templateName =
          (args['templateName'] is String &&
                  (args['templateName'] as String).isNotEmpty)
              ? args['templateName'] as String
              : libId;
      final rawParams = args['params'];
      final params =
          rawParams is Map
              ? rawParams.cast<String, Object?>()
              : const <String, Object?>{};
      final position =
          args['position'] is num ? (args['position'] as num).toInt() : null;
      final force = args['force'] == true;
      final dryRun = args['dryRun'] == true;

      // Read the raw library entry. Validation runs on the raw tree —
      // params are resolved at render time, not register time.
      Object? entry;
      try {
        entry = await library.read(mbd, libId);
      } on FormatException catch (e) {
        return _reject(
          code:
              e.message.contains('id must match')
                  ? 'invalidId'
                  : 'pathNotFound',
          message: e.message,
          suggestion: 'Call studio.builder.lib.list to confirm the entry id.',
        );
      }
      if (entry == null) {
        return _reject(
          code: 'emptyEntry',
          message:
              'library entry "$libId" is null — nothing to register. '
              'Seed the entry with lib.create({tree: {...}}).',
        );
      }
      // Validate the raw root via the shared schema gate so
      // unknownType / extraProperty lands before mutating ui/app.json.
      final v = await validator.validateNode(entry);
      if (!v.ok) {
        return _rejectMap(v.rejection!);
      }

      // 1. Register under templates[name]. Idempotent for same JSON,
      //    rejects on different + !force.
      Map<String, dynamic> registerResult;
      try {
        registerResult = await writer.addTemplate(
          mbdPath: mbd,
          name: templateName,
          entry: entry,
          force: force,
          dryRun: dryRun,
        );
      } on FormatException catch (e) {
        return _reject(
          code:
              e.message.contains('already exists')
                  ? 'alreadyExists'
                  : 'invalidArgument',
          message: e.message,
          suggestion:
              'Pass force:true to overwrite an existing template, or '
              'use a different templateName.',
        );
      }

      // 2. addNode the use site at parentPath.
      final useNode = <String, Object?>{
        'type': 'use',
        'template': templateName,
        if (params.isNotEmpty) 'params': params,
      };
      try {
        final addResult = await writer.addNode(
          mbdPath: mbd,
          path: parentPath,
          position: position,
          node: useNode,
          dryRun: dryRun,
        );
        return _ok(<String, dynamic>{
          ...addResult,
          'libId': libId,
          'templateName': templateName,
          'templateRegistered': registerResult['registered'] == true,
          'templateReplaced': registerResult['replaced'] == true,
        });
      } on FormatException catch (e) {
        return _reject(
          code: 'pathNotFound',
          message: e.message,
          suggestion: 'Use studio.builder.ui.readTree to verify parentPath.',
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
        if (expected != null) 'expected': expected,
        if (actual != null) 'actual': actual,
        'message': message,
        if (suggestion != null) 'suggestion': suggestion,
      }),
    ),
  ],
  isError: true,
);

/// Validator -> MCP rejection. The validator already produced the
/// rejection map (`code` / `path?` / `expected?` / `actual?` /
/// `message` / `suggestion?`); just wrap as an MCP error.
mk.KernelToolResult _rejectMap(Map<String, dynamic> rejection) =>
    mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(
          text: jsonEncode(<String, dynamic>{'ok': false, ...rejection}),
        ),
      ],
      isError: true,
    );
