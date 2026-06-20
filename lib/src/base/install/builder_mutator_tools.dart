/// `registerBuilderMutatorTools` — register the 14 `studio.builder.*`
/// manifest-mutator MCP tools onto a kernel `ServerBootstrap`. Each
/// tool reads / writes one slot of a bundle's `manifest.json` (and for
/// `writeUI` also `ui/app.json` / for `addTool` also `tools/*.js`) so
/// an external LLM authoring agent can extend a bundle's surface area
/// verbatim — same files the in-app editors touch.
///
/// All mutators are idempotent on their own key (id / command / tool /
/// key) so re-issuing a call with refined arguments overwrites in
/// place rather than appending duplicates. After every successful
/// mutation the handler calls `bridge.activateView` (when the mutator
/// returns a `view` hint) and `bridge.reloadTab` so the active bundle's
/// editor surfaces re-read the manifest without a manual reload —
/// mirroring the user-click code path.
///
/// Every studio host calls this once during `registerMcpTools` so the
/// builder surface stays identical across studios. Moved out of
/// vibe_studio's host file into base so the body of the registration
/// is shared verbatim.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/chrome_bridge.dart';

/// Register the 14 `studio.builder.*` mutator tools onto [boot].
/// Handlers route through [bridge] for post-mutation view activation
/// and tab reload; the host wires the bridge setters when its shell
/// mounts.
void registerBuilderMutatorTools(
  mk.KernelServerHost boot, {
  required ChromeBridge bridge,
}) {
  boot.addTool(
    name: 'studio.builder.writeUI',
    description:
        '[DEPRECATED — full-tree dump] Write a bundle\'s ui/app.json '
        'in one shot. Kept for new-bundle seeding and migration only. '
        'For incremental authoring, prefer the atomic surface — '
        'studio.builder.ui.{addNode, setProp, removeNode, moveNode, '
        'reorderChildren, applyPatch} — which validates against '
        'catalog.schema and rejects bad shapes before commit. '
        'Creates the ui/ directory and the ui section in manifest.json '
        'if missing. After writing, call studio.chrome.reload_tab '
        'to surface the change in the active workspace view.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the bundle directory.',
        },
        'json': <String, dynamic>{
          'type': 'object',
          'description':
              'The page JSON — must be a valid mcp_ui_dsl '
              'page widget at the root (`{type:"page", ...}`).',
        },
      },
      'required': <String>['mbdPath', 'json'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final json = args['json'];
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
      if (json is! Map) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"json must be an object"}',
            ),
          ],
          isError: true,
        );
      }
      final mbdDir = Directory(mbd);
      if (!await mbdDir.exists()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"bundle not found"}',
            ),
          ],
          isError: true,
        );
      }
      final uiDir = Directory(p.join(mbd, 'ui'));
      if (!await uiDir.exists()) await uiDir.create(recursive: true);
      final uiFile = File(p.join(uiDir.path, 'app.json'));
      try {
        await _snapshotBundle(
          mbd,
          'writeUI',
          files: const <String>['ui/app.json', 'manifest.json'],
        );
        await uiFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(json),
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"$e"}'),
          ],
          isError: true,
        );
      }
      // Route the manifest patch (ui section) through the transactional
      // authoring helper so a missing `manifest.ui` block gets seeded
      // under the same guards as every other mutator. The ui/app.json
      // disk write above is the reserved-folder asset write — separate
      // path per `BundleResources` convention.
      return _runKnowledgeMutation(args, 'studio.builder.writeUI', bridge, (
        manifest,
      ) {
        if (manifest['ui'] == null) {
          manifest['ui'] = <String, dynamic>{
            'kind': 'mcp_ui_dsl',
            'path': 'ui/app.json',
          };
        }
        return <String, dynamic>{'path': uiFile.path};
      });
    },
  );
  boot.addTool(
    name: 'studio.builder.writeScenario',
    description:
        'Write a scenario JSON into the bundle\'s '
        '`<mbdPath>/scenarios/<id>.json`. The id is taken from '
        '`scenario.id` and the filename matches. Creates the '
        '`scenarios/` directory if missing. Mirrors `writeUI` (which '
        'writes the bundle\'s `ui/app.json`) — use this for seed '
        'scenarios that ship with the bundle, distinct from '
        '`studio.scenario.save` which writes to the project workspace '
        '(`<configRoot>/scenarios/<id>.json`).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the bundle directory.',
        },
        'scenario': <String, dynamic>{
          'type': 'object',
          'description':
              'The scenario JSON — must include `id` '
              '(used as the filename stem).',
        },
      },
      'required': <String>['mbdPath', 'scenario'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final scenario = args['scenario'];
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
      if (scenario is! Map) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"scenario must be an object"}',
            ),
          ],
          isError: true,
        );
      }
      final id = scenario['id'];
      if (id is! String || id.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"scenario.id required (string)"}',
            ),
          ],
          isError: true,
        );
      }
      final mbdDir = Directory(mbd);
      if (!await mbdDir.exists()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"bundle not found"}',
            ),
          ],
          isError: true,
        );
      }
      final scenariosDir = Directory(p.join(mbd, 'scenarios'));
      if (!await scenariosDir.exists()) {
        await scenariosDir.create(recursive: true);
      }
      final relPath = p.join('scenarios', '$id.json');
      await _snapshotBundle(mbd, 'writeScenario', files: <String>[relPath]);
      final file = File(p.join(scenariosDir.path, '$id.json'));
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(scenario),
      );
      try {
        bridge.markActiveTabModified?.call();
      } catch (_) {
        /* swallow */
      }
      try {
        bridge.reloadTab?.call(null);
      } catch (_) {
        /* swallow — reload is non-fatal */
      }
      return mk.KernelToolResult(
        content: <mk.KernelContent>[
          mk.KernelTextContent(
            text: jsonEncode(<String, dynamic>{
              'ok': true,
              'path': file.path,
              'id': id,
            }),
          ),
        ],
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.patchManifest',
    description:
        'Modify a bundle\'s manifest.json. Three modes via `op`:\n'
        '  • `merge` (default) — SHALLOW merge from `patch` map. Each '
        'top-level key in patch replaces the same key wholesale.\n'
        '  • `deepMerge` (alias: `merge` with `deepMerge:true`) — '
        'recursive Map+Map merge from `patch`. Arrays still replace.\n'
        '  • `rfc6902` — apply `ops[]` JSON Patch operations '
        '(`add` / `remove` / `replace` / `move` / `copy` / `test`). '
        'Use this when you need to remove a single array element '
        '(e.g. remove `knowledge.sources[9]`) without rewriting the '
        'entire array.\n'
        'NOTE: identity / metadata fields live under the nested '
        '`manifest.{...}` block. Returns `{ok, manifest}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'op': <String, dynamic>{
          'type': 'string',
          'enum': <String>['merge', 'rfc6902'],
          'description':
              'Mutation mode. Default `merge`. With `rfc6902`, '
              'provide `ops[]` instead of `patch`.',
        },
        'patch': <String, dynamic>{
          'type': 'object',
          'description':
              'Patch object for `op:merge`. With '
              '`deepMerge:false` (default) top-level keys replace '
              'wholesale; with `deepMerge:true` nested Map+Map merges '
              'recursively. Ignored when `op:rfc6902`.',
        },
        'ops': <String, dynamic>{
          'type': 'array',
          'description':
              'JSON Patch ops for `op:rfc6902`. Each entry has '
              '`{op, path, value?, from?}`. Supported op values: '
              '`add` · `remove` · `replace` · `move` · `copy` · '
              '`test`. Paths are JSON Pointer '
              '(e.g. `/knowledge/sources/9` for the 10th source).',
          'items': <String, dynamic>{'type': 'object'},
        },
        'deepMerge': <String, dynamic>{
          'type': 'boolean',
          'description':
              'For `op:merge` only. When true, recursively merge '
              'nested Maps instead of replacing them wholesale. '
              'Arrays always replace. Default false.',
        },
      },
      'required': <String>['mbdPath'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final op = (args['op'] as String?) ?? 'merge';
      final patch = args['patch'];
      final ops = args['ops'];
      final deepMerge = args['deepMerge'] == true;
      if (mbd is! String) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"invalid args"}'),
          ],
          isError: true,
        );
      }
      if (op == 'merge' && patch is! Map) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"op:merge requires patch:object"}',
            ),
          ],
          isError: true,
        );
      }
      if (op == 'rfc6902' && ops is! List) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"op:rfc6902 requires ops:array"}',
            ),
          ],
          isError: true,
        );
      }
      // Fresh draft path: when manifest.json doesn't exist yet (e.g.
      // studio.project.new just scaffolded an empty directory),
      // seed an empty `{}` so the patch can populate fields. Routed
      // through `McpBundleWriter.writeManifest` once the directory is
      // populated, but the bootstrap of an empty manifest happens with
      // fs primitives because `McpBundleMutator` requires a valid
      // `.mbd/` tree on entry.
      final manifestFile = File(p.join(mbd, 'manifest.json'));
      if (!await manifestFile.exists()) {
        await Directory(mbd).create(recursive: true);
        await manifestFile.writeAsString('{}');
      }
      // Route the patch through `McpBundleMutator.mutate` so the
      // transaction guards (mutex / checksum) apply and the post-patch
      // shape is re-parsed against `mcp_bundle`'s schema.
      return _runKnowledgeMutation(
        args,
        'studio.builder.patchManifest',
        bridge,
        (manifest) {
          if (op == 'rfc6902') {
            for (final entry in ops as List) {
              if (entry is! Map) continue;
              _applyRfc6902Op(manifest, entry);
            }
          } else if (deepMerge) {
            _deepMergeInto(manifest, patch as Map);
          } else {
            (patch as Map).forEach((k, v) {
              manifest[k.toString()] = v;
            });
          }
          return <String, dynamic>{'manifest': manifest};
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addTool',
    description:
        'Add a kind:\'js\' tool to a bundle — writes the JS source '
        'under tools/<name>.js and appends/updates the tool entry in '
        'manifest.json under tools.tools[]. The JS source must export '
        'an async function whose name matches `target.fn`. Returns '
        '`{ok, jsPath}`.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'toolDef': <String, dynamic>{
          'type': 'object',
          'description':
              'The tool definition — must include name, '
              'kind:"js", target:{entry, fn}, description, '
              'inputSchema, outputSchema.',
        },
        'jsSource': <String, dynamic>{
          'type': 'string',
          'description':
              'JavaScript source for the tool — defines an '
              'async function matching target.fn.',
        },
      },
      'required': <String>['mbdPath', 'toolDef', 'jsSource'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final def = args['toolDef'];
      final src = args['jsSource'];
      if (mbd is! String || def is! Map || src is! String) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"invalid args"}'),
          ],
          isError: true,
        );
      }
      final name = def['name'];
      final target = def['target'];
      if (name is! String ||
          name.isEmpty ||
          target is! Map ||
          target['entry'] is! String) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text:
                  '{"ok":false,"error":"toolDef requires name '
                  'and target.entry"}',
            ),
          ],
          isError: true,
        );
      }
      final manifestFile = File(p.join(mbd, 'manifest.json'));
      if (!await manifestFile.exists()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"manifest.json not found"}',
            ),
          ],
          isError: true,
        );
      }
      final jsRel = (target['entry'] as String);
      final jsFile = File(p.join(mbd, jsRel));
      try {
        await jsFile.parent.create(recursive: true);
        // Snapshot BOTH the manifest and the JS source before we write
        // either — the JS file is a reserved-folder asset (not part of
        // the `manifest.json` mutation), so a separate snapshot call
        // captures it. The helper below snapshots `manifest.json` again
        // (cheap, idempotent — different `.history/<ts>-<label>` dir).
        await _snapshotBundle(
          mbd,
          'addTool',
          files: <String>['manifest.json', jsRel],
        );
        await jsFile.writeAsString(src);
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(text: '{"ok":false,"error":"$e"}'),
          ],
          isError: true,
        );
      }
      // Route the manifest piece through `McpBundleMutator.mutate` so
      // the new tool entry is committed under the same transaction
      // guards (mutex / checksum) as every other authoring path.
      return _runKnowledgeMutation(args, 'studio.builder.addTool', bridge, (
        manifestRaw,
      ) {
        final tools =
            (manifestRaw['tools'] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
        final list =
            (tools['tools'] as List?)
                ?.cast<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList() ??
            <Map<String, dynamic>>[];
        final newDef = Map<String, dynamic>.from(def);
        final existingIdx = list.indexWhere((t) => t['name'] == name);
        if (existingIdx >= 0) {
          list[existingIdx] = newDef;
        } else {
          list.add(newDef);
        }
        tools['tools'] = list;
        manifestRaw['tools'] = tools;
        return <String, dynamic>{
          'jsPath': jsFile.path,
          'toolName': name,
          'view': 'tools/tool',
        };
      });
    },
  );
  boot.addTool(
    name: 'studio.builder.addKnowledgeSource',
    description:
        'Append (or upsert by id) a knowledge source entry to '
        'manifest.knowledge.sources[]. A source groups documents '
        'under a sourceId so kb.query can scope retrieval. The '
        '`source` arg may include initial documents[]; otherwise '
        'follow up with addKnowledgeDoc per document. Idempotent — '
        'an existing source with the same id is replaced.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'source': <String, dynamic>{
          'type': 'object',
          'description':
              'Source object — must include id; optional documents[].',
        },
      },
      'required': <String>['mbdPath', 'source'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addKnowledgeSource',
        bridge,
        (manifest) {
          final src = args['source'];
          if (src is! Map ||
              src['id'] is! String ||
              (src['id'] as String).isEmpty) {
            throw FormatException('source.id required');
          }
          final knowledge = _ensureMap(manifest, 'knowledge');
          final sources = _ensureList(knowledge, 'sources');
          final id = src['id'] as String;
          final existing = sources.indexWhere((s) => s is Map && s['id'] == id);
          if (existing >= 0) {
            sources[existing] = Map<String, dynamic>.from(src);
          } else {
            sources.add(Map<String, dynamic>.from(src));
          }
          return <String, dynamic>{'added': 'source', 'id': id};
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addKnowledgeDoc',
    description:
        'Append (or upsert by doc.id) a document into a knowledge '
        'source\'s documents[]. The source must already exist (call '
        'addKnowledgeSource first). doc must include id + content; '
        'title + source provenance recommended.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'sourceId': <String, dynamic>{'type': 'string'},
        'doc': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['mbdPath', 'sourceId', 'doc'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addKnowledgeDoc',
        bridge,
        (manifest) {
          final sourceId = args['sourceId'];
          final doc = args['doc'];
          if (sourceId is! String || sourceId.isEmpty) {
            throw FormatException('sourceId required');
          }
          if (doc is! Map ||
              doc['id'] is! String ||
              doc['content'] is! String) {
            throw FormatException(
              'doc must include id (string) + content (string)',
            );
          }
          final knowledge = _ensureMap(manifest, 'knowledge');
          final sources = _ensureList(knowledge, 'sources');
          final srcIdx = sources.indexWhere(
            (s) => s is Map && s['id'] == sourceId,
          );
          if (srcIdx < 0) {
            throw StateError(
              'source "$sourceId" not found — '
              'call addKnowledgeSource first',
            );
          }
          final src = Map<String, dynamic>.from(sources[srcIdx] as Map);
          final docs =
              (src['documents'] as List?)
                  ?.map(
                    (d) =>
                        d is Map
                            ? Map<String, dynamic>.from(d)
                            : <String, dynamic>{},
                  )
                  .toList() ??
              <Map<String, dynamic>>[];
          final docId = doc['id'] as String;
          final existing = docs.indexWhere((d) => d['id'] == docId);
          if (existing >= 0) {
            docs[existing] = Map<String, dynamic>.from(doc);
          } else {
            docs.add(Map<String, dynamic>.from(doc));
          }
          src['documents'] = docs;
          sources[srcIdx] = src;
          return <String, dynamic>{
            'added': 'doc',
            'sourceId': sourceId,
            'docId': docId,
          };
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addSkill',
    description:
        'Append (or upsert by id) a skill entry to '
        'manifest.knowledge.skills[]. Skill = capability metadata '
        '(name + description + inputSchema). Separate from the '
        'runtime kind:js tool that implements it — they can exist '
        'independently.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'skill': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['mbdPath', 'skill'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(args, 'studio.builder.addSkill', bridge, (
        manifest,
      ) {
        final entry = args['skill'];
        if (entry is! Map<String, dynamic>) {
          throw FormatException('skill entry required (Map)');
        }
        return _upsertTopLevelList(
          manifest,
          sectionKey: 'skills',
          // mcp_bundle's SkillSection model uses the legacy `modules`
          // key — `skills` is a read-only getter alias. Writing the
          // canonical name (skills.skills) gets dropped on round-trip.
          listKey: 'modules',
          entry: Map<String, dynamic>.from(entry),
        );
      });
    },
  );
  boot.addTool(
    name: 'studio.builder.addProfile',
    description:
        'Append (or upsert by id) a profile entry to '
        'manifest.knowledge.profiles[]. Profile = persona '
        'description (tone / voice / audience).',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'profile': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['mbdPath', 'profile'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(args, 'studio.builder.addProfile', bridge, (
        manifest,
      ) {
        final entry = args['profile'];
        if (entry is! Map<String, dynamic>) {
          throw FormatException('profile entry required (Map)');
        }
        return _upsertTopLevelList(
          manifest,
          sectionKey: 'profiles',
          listKey: 'profiles',
          entry: Map<String, dynamic>.from(entry),
        );
      });
    },
  );
  boot.addTool(
    name: 'studio.builder.addPhilosophy',
    description:
        'Append (or upsert by id) a philosophy entry to '
        'manifest.knowledge.philosophies[]. Philosophy = principle '
        'statement + rationale + optional tags / priority / '
        'conflictsWith.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'philosophy': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['mbdPath', 'philosophy'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addPhilosophy',
        bridge,
        (manifest) {
          final entry = args['philosophy'];
          if (entry is! Map<String, dynamic>) {
            throw FormatException('philosophy entry required (Map)');
          }
          return _upsertTopLevelList(
            manifest,
            sectionKey: 'philosophy',
            listKey: 'philosophies',
            entry: Map<String, dynamic>.from(entry),
          );
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addKnowledge',
    description:
        'Unified knowledge upsert — `kind` selects which manifest list '
        'the `entry` lands in. Each `kind` runs a corresponding '
        '`mcp_bundle.PartialValidators` check before commit; structural '
        'errors return `{ok:false, issues:[...]}` and the write is '
        'skipped (no fs side-effect).\n'
        'Supported kinds (`entry` schema notes):\n'
        '  • `source` → `knowledge.sources[]`. {id, name, description?, '
        'documents?:[]}\n'
        '  • `fact` → `knowledge.facts[]`. {id, ...}\n'
        '  • `skill` → `knowledge.skills[]`. {id, name, ...}\n'
        '  • `profile` → `knowledge.profiles[]`. {id, name, ...}\n'
        '  • `philosophy` → `knowledge.philosophies[]`. {id, name, ...}\n'
        '  • `workflow` → `knowledge.workflows[]`. {id, name, ...}\n'
        '  • `pipeline` → `knowledge.pipelines[]`. {id, name, ...}\n'
        '  • `runbook` → `knowledge.runbooks[]`. {id, name, ...}\n'
        '  • `agent` → `agents.agents[]` (top-level, not under '
        'knowledge). {id, name, role, systemPrompt?, model?, ...}\n'
        'Returns `{ok, added: <kind>, id}` on success.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'kind': <String, dynamic>{
          'type': 'string',
          'enum': <String>[
            'source',
            'fact',
            'skill',
            'profile',
            'philosophy',
            'workflow',
            'pipeline',
            'runbook',
            'agent',
          ],
        },
        'entry': <String, dynamic>{
          'type': 'object',
          'description': 'Entry object — shape per kind (see description).',
        },
      },
      'required': <String>['mbdPath', 'kind', 'entry'],
    },
    handler: (args) async {
      final kind = args['kind'];
      final entryRaw = args['entry'];
      if (kind is! String) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"kind required (string)"}',
            ),
          ],
          isError: true,
        );
      }
      if (entryRaw is! Map) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"entry required (object)"}',
            ),
          ],
          isError: true,
        );
      }
      final entry = Map<String, dynamic>.from(entryRaw);
      // Pre-mutation PartialValidators check (mcp_bundle D3 API) —
      // catches shape mistakes before the manifest is touched.
      final issues = _validateKnowledgeEntry(kind, entry);
      if (issues != null && issues.isNotEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': 'validation failed for kind=$kind',
                'issues': issues,
                'tool': 'studio.builder.addKnowledge',
              }),
            ),
          ],
          isError: true,
        );
      }
      return _runKnowledgeMutation(
        args,
        'studio.builder.addKnowledge',
        bridge,
        (manifest) {
          // Sources are the one knowledge-category that lives nested
          // under `knowledge.*` per the mcp_bundle schema
          // (`KnowledgeSection.sources`). Every other category is a
          // top-level section (`facts.facts[]`, `skills.skills[]`,
          // `philosophy.philosophies[]`, `workflows.workflows[]`,
          // `pipelines.pipelines[]`, `runbooks.runbooks[]`,
          // `profiles.profiles[]`, `agents.agents[]`). Routing matches
          // the schema so the round-trip preserves every entry.
          if (kind == 'source') {
            return _upsertKnowledgeList(manifest, 'sources', entry);
          }
          // Top-level section / inner-list-key pairs per kind.
          const sectionByKind = <String, _SectionRoute>{
            'fact': _SectionRoute('facts', 'facts'),
            // SkillSection.fromJson reads `modules` (legacy alias kept
            // for back-compat with skill bundles authored pre-rename).
            'skill': _SectionRoute('skills', 'modules'),
            'profile': _SectionRoute('profiles', 'profiles'),
            'philosophy': _SectionRoute('philosophy', 'philosophies'),
            'workflow': _SectionRoute('workflows', 'workflows'),
            'pipeline': _SectionRoute('pipelines', 'pipelines'),
            'runbook': _SectionRoute('runbooks', 'runbooks'),
            'agent': _SectionRoute('agents', 'agents'),
          };
          final route = sectionByKind[kind];
          if (route == null) {
            throw FormatException('unsupported kind: $kind');
          }
          return _upsertTopLevelList(
            manifest,
            sectionKey: route.section,
            listKey: route.list,
            entry: entry,
          );
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addKnowledgeEntry',
    description:
        'Append (or upsert by id) an inline knowledge entry to '
        'manifest.knowledge.knowledge[]. This is the authoritative '
        'in-manifest reference doc slot — distinct from '
        '`addKnowledgeSource` / `addKnowledgeDoc` which write to '
        'manifest.knowledge.sources[].documents[] (RAG-style). Entry '
        'should include `id`, `title`, and `body`; additional fields '
        'are preserved verbatim.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'entry': <String, dynamic>{
          'type': 'object',
          'description':
              'Knowledge entry — must include `id`; '
              '`title` + `body` recommended. Upserted by id.',
        },
      },
      'required': <String>['mbdPath', 'entry'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addKnowledgeEntry',
        bridge,
        (manifest) =>
            _upsertKnowledgeList(manifest, 'knowledge', args['entry']),
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addSlashCommand',
    description:
        'Append (or upsert by command) a slash command hint to '
        'manifest.chat.slashCommands[]. When the bundle is the '
        'active tab in vibe_studio, the chat panel surfaces these '
        'as composer chips. Two flavours: '
        '(a) TEMPLATE chip — fills the input with [template] so the '
        'user (and downstream chat agent) can finish the prompt; '
        '(b) DIRECT-DISPATCH chip — submitting the chip immediately '
        'fires the bound tool, bypassing the LLM. Schema per entry: '
        '{command: "/foo", template?: "bar", description?: "...", '
        'tool?: "<bareToolName>", arguments?: {...}}. When `tool` is '
        'set, the entry is direct-dispatch (template is optional + '
        'used only as a visual placeholder); without `tool`, the '
        'entry is a template chip. template ends with a space when '
        'an arg follows so the caret lands ready '
        '(e.g. "/find " template "").',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'hint': <String, dynamic>{
          'type': 'object',
          'description':
              'Hint object — must include command ("/foo"); '
              'template + description optional.',
        },
      },
      'required': <String>['mbdPath', 'hint'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addSlashCommand',
        bridge,
        (manifest) {
          final h = args['hint'];
          if (h is! Map ||
              h['command'] is! String ||
              (h['command'] as String).isEmpty) {
            throw FormatException('hint.command required');
          }
          final chat = _ensureMap(manifest, 'chat');
          final cmds = _ensureList(chat, 'slashCommands');
          final command = h['command'] as String;
          final existing = cmds.indexWhere(
            (c) => c is Map && c['command'] == command,
          );
          if (existing >= 0) {
            cmds[existing] = Map<String, dynamic>.from(h);
          } else {
            cmds.add(Map<String, dynamic>.from(h));
          }
          return <String, dynamic>{
            'added': 'slashCommand',
            'command': command,
            'view': 'tools/slash',
          };
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addDomainAction',
    description:
        'Append (or upsert by tool) a domain-icon wiring entry to '
        'manifest.wiring.domainActions[]. When the bundle is the '
        'active tab in vibe_studio, the host appends an icon button '
        'to the left panel\'s domain row (after the built-in '
        'Import/Export/UI/Tools/Knowledge/Manifest icons). Tapping '
        'the icon calls the bundle\'s exposed tool. Schema per entry: '
        '{tool: "<bareToolName>", icon: "<materialIconName>", '
        'tooltip: "<hover label>"}. icon name comes from the host\'s '
        'small icon map (extension/play/stop/refresh/add/delete/edit/'
        'save/search/filter/history/star/flag/bug/check/sync/cloud/'
        'database/terminal/graph/chart/table/mail/send/lock/unlock/'
        'key/shield/palette/image/audio/video/file/folder/link/share/'
        'export/import) — unknown names fall back to extension.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'entry': <String, dynamic>{
          'type': 'object',
          'description':
              'Wiring entry — must include tool (bare name, no prefix); '
              'icon + tooltip optional.',
        },
      },
      'required': <String>['mbdPath', 'entry'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addDomainAction',
        bridge,
        (manifest) {
          final e = args['entry'];
          if (e is! Map ||
              e['tool'] is! String ||
              (e['tool'] as String).isEmpty) {
            throw FormatException('entry.tool required');
          }
          final wiring = _ensureMap(manifest, 'wiring');
          final list = _ensureList(wiring, 'domainActions');
          final tool = e['tool'] as String;
          final existing = list.indexWhere(
            (m) => m is Map && m['tool'] == tool,
          );
          if (existing >= 0) {
            list[existing] = Map<String, dynamic>.from(e);
          } else {
            list.add(Map<String, dynamic>.from(e));
          }
          return <String, dynamic>{
            'added': 'domainAction',
            'tool': tool,
            'view': 'tools/domain',
          };
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addSettingsSection',
    description:
        'Append (or upsert by key) a section to '
        'manifest.settings.sections[]. Sections appear inline in the '
        'Studio Builder workspace settings editor (NOT behind a gear '
        'dialog) — each section renders its label as a mono-caps '
        'header with its fields[] beneath. Schema per entry: '
        '{key: "<sectionId>", label: "<header text>"}. Use this '
        'first, then call addSettingsField to append fields. Adding '
        'a section with no fields renders the header + a "(no '
        'fields)" placeholder so the author can see the slot.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'section': <String, dynamic>{
          'type': 'object',
          'description':
              'Section descriptor — must include key (stable id used '
              'by addSettingsField) + label (display text).',
        },
      },
      'required': <String>['mbdPath', 'section'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addSettingsSection',
        bridge,
        (manifest) {
          final s = args['section'];
          if (s is! Map ||
              s['key'] is! String ||
              (s['key'] as String).isEmpty) {
            throw FormatException('section.key required');
          }
          if (s['label'] is! String || (s['label'] as String).isEmpty) {
            throw FormatException('section.label required');
          }
          final settings = _ensureMap(manifest, 'settings');
          final sections = _ensureList(settings, 'sections');
          final key = s['key'] as String;
          final existing = sections.indexWhere(
            (m) => m is Map && m['key'] == key,
          );
          // Carry existing fields[] forward when upserting so a label
          // edit doesn't blow away authored fields.
          final preservedFields =
              existing >= 0 ? (sections[existing] as Map)['fields'] : null;
          final updated = <String, dynamic>{
            'key': key,
            'label': s['label'],
            'fields':
                preservedFields is List
                    ? preservedFields
                    : <Map<String, dynamic>>[],
          };
          if (existing >= 0) {
            sections[existing] = updated;
          } else {
            sections.add(updated);
          }
          return <String, dynamic>{
            'added': 'settingsSection',
            'key': key,
            'view': 'tools/section',
          };
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addSettingsField',
    description:
        'Append (or upsert by field.key) a field to a settings '
        'section\'s fields[]. The section MUST already exist '
        '(call addSettingsSection first). Field schema: '
        '{key: "<id>", label: "<display>", type: "text"|"toggle"|'
        '"menu"|"number", value: <default>, options?: [...] (menu '
        'only)}. Edits made by the user in the workspace settings '
        'panel autosave to a per-package overrides file — the '
        'manifest holds defaults, the override file holds the '
        'current effective value.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'sectionKey': <String, dynamic>{
          'type': 'string',
          'description':
              'Key of the section to append the field to — must match '
              'a section already declared via addSettingsSection.',
        },
        'field': <String, dynamic>{
          'type': 'object',
          'description':
              'Field descriptor — must include key + label + type. '
              'Supported types: text · toggle · menu (with options[]) '
              '· number. value (default) optional.',
        },
      },
      'required': <String>['mbdPath', 'sectionKey', 'field'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addSettingsField',
        bridge,
        (manifest) {
          final sectionKey = args['sectionKey'];
          if (sectionKey is! String || sectionKey.isEmpty) {
            throw FormatException('sectionKey required');
          }
          final f = args['field'];
          if (f is! Map ||
              f['key'] is! String ||
              (f['key'] as String).isEmpty) {
            throw FormatException('field.key required');
          }
          if (f['label'] is! String || (f['label'] as String).isEmpty) {
            throw FormatException('field.label required');
          }
          if (f['type'] is! String || (f['type'] as String).isEmpty) {
            throw FormatException('field.type required');
          }
          final settings = _ensureMap(manifest, 'settings');
          final sections = _ensureList(settings, 'sections');
          final sectionIdx = sections.indexWhere(
            (m) => m is Map && m['key'] == sectionKey,
          );
          if (sectionIdx < 0) {
            throw FormatException(
              'section "$sectionKey" not found — call '
              'addSettingsSection first',
            );
          }
          final section = Map<String, dynamic>.from(
            sections[sectionIdx] as Map,
          );
          final fields =
              (section['fields'] is List)
                  ? List<dynamic>.from(section['fields'] as List)
                  : <dynamic>[];
          final fieldKey = f['key'] as String;
          final existingField = fields.indexWhere(
            (m) => m is Map && m['key'] == fieldKey,
          );
          final entry = Map<String, dynamic>.from(f);
          if (existingField >= 0) {
            fields[existingField] = entry;
          } else {
            fields.add(entry);
          }
          section['fields'] = fields;
          sections[sectionIdx] = section;
          return <String, dynamic>{
            'added': 'settingsField',
            'sectionKey': sectionKey,
            'fieldKey': fieldKey,
            'view': 'tools/section',
          };
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addSettingsEntry',
    description:
        'Append (or upsert by tool) a settings-menu wiring entry to '
        'manifest.wiring.settings[]. When the bundle is the active '
        'tab in vibe_studio, the settings dialog (gear icon in the '
        'project header) appends a "DOMAIN ACTIONS" section listing '
        'these entries; tapping one calls the bound tool with the '
        'declared arguments. Schema per entry: '
        '{tool: "<bareToolName>", label: "<menu text>", '
        'icon?: "<materialIconName>", category?: "<group label>", '
        'arguments?: {...}}. Use this for less-frequent or '
        'configuration-style verbs (export · clear cache · reset '
        'preferences) that don\'t deserve a permanent domain icon.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'entry': <String, dynamic>{
          'type': 'object',
          'description':
              'Wiring entry — must include tool (bare name) + label; '
              'icon / category / arguments optional.',
        },
      },
      'required': <String>['mbdPath', 'entry'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addSettingsEntry',
        bridge,
        (manifest) {
          final e = args['entry'];
          if (e is! Map ||
              e['tool'] is! String ||
              (e['tool'] as String).isEmpty) {
            throw FormatException('entry.tool required');
          }
          if (e['label'] is! String || (e['label'] as String).isEmpty) {
            throw FormatException('entry.label required');
          }
          final wiring = _ensureMap(manifest, 'wiring');
          final list = _ensureList(wiring, 'settings');
          final tool = e['tool'] as String;
          final existing = list.indexWhere(
            (m) => m is Map && m['tool'] == tool,
          );
          if (existing >= 0) {
            list[existing] = Map<String, dynamic>.from(e);
          } else {
            list.add(Map<String, dynamic>.from(e));
          }
          return <String, dynamic>{'added': 'settingsEntry', 'tool': tool};
        },
      );
    },
  );
  boot.addTool(
    name: 'studio.builder.addAgent',
    description:
        'Append (or upsert by id) an agent profile to the bundle\'s '
        'top-level agents[] array (NOT under knowledge). The agent map '
        'uses the canonical AgentDefinition shape: id (required), name, '
        'role, systemPrompt, model (object: {provider, model, '
        'sampling}), tools (string list). Optional: skillIds, '
        'profileIds, philosophyIds, factSourceIds, description, '
        'behavior, metadata. After authoring, the bundle reload '
        're-registers the agent into the host\'s AgentHost.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'agent': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['mbdPath', 'agent'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(args, 'studio.builder.addAgent', bridge, (
        manifest,
      ) {
        final agent = args['agent'];
        if (agent is! Map ||
            agent['id'] is! String ||
            (agent['id'] as String).isEmpty) {
          throw FormatException('agent.id required');
        }
        // mcp_bundle canonical shape: agents: {agents: [...]}.
        final agentsSection = _ensureMap(manifest, 'agents');
        final agents = _ensureList(agentsSection, 'agents');
        final id = agent['id'] as String;
        final existing = agents.indexWhere((a) => a is Map && a['id'] == id);
        if (existing >= 0) {
          agents[existing] = Map<String, dynamic>.from(agent);
        } else {
          agents.add(Map<String, dynamic>.from(agent));
        }
        return <String, dynamic>{'added': 'agent', 'id': id};
      });
    },
  );

  // ── Flow / Fact mutators (knowledge-operations §3 gap 4/5) ───────
  //
  // bundle.flow.flows[] = FlowDefinition (unified workflow / pipeline /
  // runbook — type discriminator is a future extension).
  // bundle.facts.facts[] = inline subject/predicate/object triples.
  // bundle.factGraph.embedded.facts[] = L0 fact graph entries
  // (entity-claim-evidence lifecycle).

  boot.addTool(
    name: 'studio.builder.addFlow',
    description:
        'Append (or upsert by id) a flow definition to the bundle\'s '
        'top-level `flow.flows[]` array. Flow = workflow / pipeline / '
        'runbook (FlowDefinition shape: id, name, description?, '
        'trigger?, steps[], inputs[], output?, timeoutMs?). On '
        'bundle activation the host registers it through '
        'OpsFacade.runWorkflow / runPipeline / runRunbook depending '
        'on the discriminator.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'flow': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['mbdPath', 'flow'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(args, 'studio.builder.addFlow', bridge, (
        manifest,
      ) {
        final flow = args['flow'];
        if (flow is! Map ||
            flow['id'] is! String ||
            (flow['id'] as String).isEmpty) {
          throw FormatException('flow.id required');
        }
        final section = _ensureMap(manifest, 'flow');
        final list = _ensureList(section, 'flows');
        final id = flow['id'] as String;
        final existing = list.indexWhere((e) => e is Map && e['id'] == id);
        if (existing >= 0) {
          list[existing] = Map<String, dynamic>.from(flow);
        } else {
          list.add(Map<String, dynamic>.from(flow));
        }
        return <String, dynamic>{'added': 'flow', 'id': id};
      });
    },
  );

  boot.addTool(
    name: 'studio.builder.addBehavior',
    description:
        'Append (or upsert by id) a behavior definition to the bundle\'s '
        'top-level `behavior.definitions[]` array. Behavior = the unified '
        'state + step execution engine (BehaviorDefinition shape: id, '
        'name, description?, steps[], metadata?). A step = { id, do, '
        'when?, then?, dependsOn?, onFailure? }: `do` = {tool: "<id>", '
        'args} or {skill: "<id>", inputs}; `when` = a state expression '
        '(`approved == true`, `count >= 10`, `&&`/`||`/parens); `then` = '
        'result -> outcome map (proceed / skip / wait / stop / goto:<id> '
        '+ host-registered outcomes). On bundle activation the host '
        'registers it; run via `bk.behavior.run`, resume a suspended '
        '(wait) run via `bk.behavior.resume`. A `wait` outcome suspends '
        'until state changes (e.g. an approval tool sets `approved`). '
        'flow = ephemeral, runbook = durable — same engine, the state '
        'store differs.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'behavior': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['mbdPath', 'behavior'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(args, 'studio.builder.addBehavior', bridge, (
        manifest,
      ) {
        final behavior = args['behavior'];
        if (behavior is! Map ||
            behavior['id'] is! String ||
            (behavior['id'] as String).isEmpty) {
          throw FormatException('behavior.id required');
        }
        final section = _ensureMap(manifest, 'behavior');
        final list = _ensureList(section, 'definitions');
        final id = behavior['id'] as String;
        final existing = list.indexWhere((e) => e is Map && e['id'] == id);
        if (existing >= 0) {
          list[existing] = Map<String, dynamic>.from(behavior);
        } else {
          list.add(Map<String, dynamic>.from(behavior));
        }
        return <String, dynamic>{'added': 'behavior', 'id': id};
      });
    },
  );

  boot.addTool(
    name: 'studio.builder.addFact',
    description:
        'Append (or upsert by id) an inline fact triple to '
        '`facts.facts[]`. Fact shape: `{id?, subject, predicate, '
        'object, confidence?, source?}`. Use this for simple '
        'subject-predicate-object assertions. For structured fact '
        'graph (entity / claim / evidence lifecycle), use '
        '`addEmbeddedFact` instead.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'fact': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['mbdPath', 'fact'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(args, 'studio.builder.addFact', bridge, (
        manifest,
      ) {
        final fact = args['fact'];
        if (fact is! Map ||
            fact['subject'] is! String ||
            fact['predicate'] is! String ||
            fact['object'] is! String) {
          throw FormatException(
            'fact.subject + predicate + object (strings) required',
          );
        }
        final section = _ensureMap(manifest, 'facts');
        final list = _ensureList(section, 'facts');
        final id = fact['id'] as String?;
        if (id != null && id.isNotEmpty) {
          final existing = list.indexWhere((e) => e is Map && e['id'] == id);
          if (existing >= 0) {
            list[existing] = Map<String, dynamic>.from(fact);
            return <String, dynamic>{'added': 'fact', 'id': id};
          }
        }
        list.add(Map<String, dynamic>.from(fact));
        return <String, dynamic>{'added': 'fact', 'id': id ?? '<append>'};
      });
    },
  );

  boot.addTool(
    name: 'studio.builder.addEmbeddedFact',
    description:
        'Append (or upsert by id) a structured fact to '
        '`factGraph.embedded.facts[]`. EmbeddedFact shape: `{id, '
        'entityId, type, content, confidence?, evidenceRefs?, '
        '...}`. Use this for L0 fact graph entries with entity / '
        'claim / evidence lifecycle. For simple SVO triples, use '
        '`addFact` against `facts.facts[]` instead.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{'type': 'string'},
        'fact': <String, dynamic>{'type': 'object'},
      },
      'required': <String>['mbdPath', 'fact'],
    },
    handler: (args) async {
      return _runKnowledgeMutation(
        args,
        'studio.builder.addEmbeddedFact',
        bridge,
        (manifest) {
          final fact = args['fact'];
          if (fact is! Map ||
              fact['id'] is! String ||
              (fact['id'] as String).isEmpty) {
            throw FormatException('fact.id required');
          }
          final factGraph = _ensureMap(manifest, 'factGraph');
          final embedded = _ensureMap(factGraph, 'embedded');
          final list = _ensureList(embedded, 'facts');
          final id = fact['id'] as String;
          final existing = list.indexWhere((e) => e is Map && e['id'] == id);
          if (existing >= 0) {
            list[existing] = Map<String, dynamic>.from(fact);
          } else {
            list.add(Map<String, dynamic>.from(fact));
          }
          return <String, dynamic>{'added': 'embeddedFact', 'id': id};
        },
      );
    },
  );

  // ── Read tools (symmetric companions to the mutators above) ─────
  //
  // Mutators are upsert-by-id / shallow-merge; without a read pair,
  // an external LLM cannot inspect current state and must abuse
  // patchManifest({}) to echo the manifest. These two surface the
  // existing mcp_bundle read APIs directly.

  boot.addTool(
    name: 'studio.builder.readManifest',
    description:
        'Read a bundle\'s `manifest.json` verbatim. Returns the raw '
        'parsed map under `{ok:true, manifest}` — same shape the '
        '`patchManifest` mutator operates on. Cheap (file read, no '
        'mcp_bundle typed parsing) so safe to call repeatedly when '
        'an authoring LLM wants to inspect-then-mutate.',
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
              text: '{"ok":false,"error":"mbdPath required"}',
            ),
          ],
          isError: true,
        );
      }
      final manifestFile = File(p.join(mbd, 'manifest.json'));
      if (!await manifestFile.exists()) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"manifest.json not found"}',
            ),
          ],
          isError: true,
        );
      }
      try {
        final raw = jsonDecode(await manifestFile.readAsString());
        if (raw is! Map<String, dynamic>) {
          throw const FormatException('manifest is not a JSON object');
        }
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{'ok': true, 'manifest': raw}),
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
    name: 'studio.builder.readBundle',
    description:
        'Load a bundle via `mcp_bundle`\'s validating loader '
        '(`McpBundleLoader.loadDirectory`) and return the typed view '
        'as JSON. Optional `sections` filters the output to the named '
        'top-level keys only (e.g. `["tools","skills"]`). Use this '
        'when you want validated, mcp_bundle-shaped data (correct '
        'section types, schema warnings); use `readManifest` instead '
        'when you want the literal `manifest.json` file content. '
        'Pass `lenient: true` when the bundle is known to omit '
        '`schemaVersion` or carry unresolved references — the loader '
        'falls back to `McpLoaderOptions.lenient()` so the read '
        'succeeds. On validation failure the response surfaces every '
        'individual error in `errors[]` (BundleValidationException '
        'detail) so the caller can fix the exact field.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the bundle directory.',
        },
        'sections': <String, dynamic>{
          'type': 'array',
          'items': <String, dynamic>{'type': 'string'},
          'description':
              'Optional whitelist of top-level keys to return — '
              'e.g. ["manifest","tools","skills"]. When omitted, '
              'the full McpBundle.toJson() is returned.',
        },
        'lenient': <String, dynamic>{
          'type': 'boolean',
          'description':
              'When true, load with McpLoaderOptions.lenient() — '
              'skips schemaVersion + cross-section reference '
              'checks. Default false (strict).',
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
      final sectionsArg = args['sections'];
      final Set<String>? filter =
          sectionsArg is List
              ? sectionsArg.map((e) => e.toString()).toSet()
              : null;
      // Optional `lenient: true` flag — flips the loader from
      // `McpLoaderOptions.strict()` (default) to `.lenient()` so the
      // caller can read manifests that don't carry `schemaVersion` or
      // have unresolved cross-section references. Studio seed bundles
      // historically omit `schemaVersion`; lenient lets agents
      // introspect them without rejecting the whole load.
      final lenient = args['lenient'] == true;
      final loaderOptions =
          lenient
              ? const mk.McpLoaderOptions.lenient()
              : const mk.McpLoaderOptions.strict();
      try {
        final bundle = await mk.McpBundleLoader.loadDirectory(
          mbd,
          options: loaderOptions,
        );
        final full = bundle.toJson();
        final out =
            filter == null
                ? full
                : <String, dynamic>{
                  for (final k in full.keys)
                    if (filter.contains(k)) k: full[k],
                };
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': true,
                'bundle': out,
                'lenient': lenient,
                if (filter != null) 'sections': filter.toList(),
              }),
            ),
          ],
        );
      } on mk.BundleValidationException catch (e) {
        // Surface every individual ValidationError so the caller can
        // see WHICH field failed — toString() alone only counts.
        final errorList = <String>[for (final err in e.errors) err.toString()];
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': 'BundleValidationException',
                'message': e.message,
                'errors': errorList,
                'warnings': e.warnings,
                'lenient': lenient,
                'hint':
                    lenient
                        ? 'lenient load still failed — manifest is structurally broken beyond schemaVersion / reference issues.'
                        : 'Retry with `lenient: true` to skip schemaVersion / reference checks.',
              }),
            ),
          ],
          isError: true,
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': e.toString(),
              }),
            ),
          ],
          isError: true,
        );
      }
    },
  );

  boot.addTool(
    name: 'studio.builder.writeBundleFile',
    description:
        'Write a single file inside one of the 12 reserved bundle '
        'folders via `mcp_bundle.BundleResources.write` — the typed, '
        'path-safe accessor (no `..` traversal, no absolute paths). '
        'Use this for folder-companion content that has no dedicated '
        'inline mutator: knowledge/<id>.md (text corpus that joins '
        'BM25 automatically per round 5), facts/<id>.json, '
        'workflows/<id>.json, pipelines/<id>.json, runbooks/<id>.json, '
        'tools/<name>.js (kind=js scripts — pair with addTool which '
        'declares the manifest entry), agents/<id>.json, '
        'profiles/<id>.json, philosophy/<id>.json, skills/<id>.json, '
        'assets/<rel>. Returns `{ok, folder, relPath, bytes}`. After '
        'writing, the host bundle reload notification fires so '
        'KnowledgeQueryEngine + agent loader see the change without a '
        'manual reload_tab.',
    inputSchema: const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'mbdPath': <String, dynamic>{
          'type': 'string',
          'description': 'Absolute path to the bundle directory.',
        },
        'folder': <String, dynamic>{
          'type': 'string',
          'enum': <String>[
            'ui',
            'assets',
            'skills',
            'knowledge',
            'facts',
            'workflows',
            'pipelines',
            'runbooks',
            'tools',
            'profiles',
            'philosophy',
            'agents',
          ],
          'description': 'Which reserved BundleFolder slot to write into.',
        },
        'relPath': <String, dynamic>{
          'type': 'string',
          'description':
              'Forward-slash relative path under the folder root. '
              'Empty / absolute / `..`-bearing paths are rejected.',
        },
        'content': <String, dynamic>{
          'type': 'string',
          'description': 'UTF-8 text contents to write.',
        },
      },
      'required': <String>['mbdPath', 'folder', 'relPath', 'content'],
    },
    handler: (args) async {
      final mbd = args['mbdPath'];
      final folderName = args['folder'];
      final relPath = args['relPath'];
      final content = args['content'];
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
      if (folderName is! String || folderName.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"folder required"}',
            ),
          ],
          isError: true,
        );
      }
      if (relPath is! String || relPath.isEmpty) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"relPath required"}',
            ),
          ],
          isError: true,
        );
      }
      if (content is! String) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: '{"ok":false,"error":"content must be a string"}',
            ),
          ],
          isError: true,
        );
      }
      mk.BundleFolder? folder;
      for (final f in mk.BundleFolder.values) {
        if (f.name == folderName) {
          folder = f;
          break;
        }
      }
      if (folder == null) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': 'unknown folder: $folderName',
                'allowed': <String>[
                  for (final f in mk.BundleFolder.values) f.name,
                ],
              }),
            ),
          ],
          isError: true,
        );
      }
      try {
        await _snapshotBundle(
          mbd,
          'writeBundleFile',
          files: <String>[p.join(folderName, relPath)],
        );
        final bundle = await mk.McpBundleLoader.loadDirectory(
          mbd,
          options: const mk.McpLoaderOptions.lenient(),
        );
        final res = bundle.resources(folder);
        await res.write(relPath, content);
        try {
          bridge.markActiveTabModified?.call();
        } catch (_) {
          /* swallow */
        }
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
                'folder': folder.name,
                'relPath': relPath,
                'bytes': content.length,
              }),
            ),
          ],
        );
      } catch (e) {
        return mk.KernelToolResult(
          content: <mk.KernelContent>[
            mk.KernelTextContent(
              text: jsonEncode(<String, dynamic>{
                'ok': false,
                'error': e.toString(),
              }),
            ),
          ],
          isError: true,
        );
      }
    },
  );
}

// ── Shared mutation runner + manifest-traversal helpers ─────────────
//
// `_runKnowledgeMutation`:
//   1. Reads the manifest at args['mbdPath']
//   2. Hands the parsed map to the callback (which mutates in place
//      and returns a summary)
//   3. Atomically writes the manifest back to disk
//   4. Returns the summary wrapped in `{ok: true}` (or `{ok:false,
//      error}` on failure).

/// Run a manifest-scoped mutation through `McpBundleMutator.mutate` —
/// the transactional authoring path published by `mcp_bundle` 0.3.3.
///
/// The closure operates on the **raw manifest JSON** for backward
/// compatibility with existing mutators (each appends/upserts at a
/// specific list / map path). After the closure returns, the helper
/// re-parses the mutated JSON through `McpBundleLoader.fromJson` —
/// schema violations throw, the mutator skips the write, and disk
/// stays untouched.
///
/// Three transaction guards inherited from `McpBundleMutator.mutate`:
///   * in-process mutex (per-mbdPath Completer queue),
///   * optimistic `sha256` checksum (load vs. pre-write diff),
///   * optional OS file lock (off by default — host is single-process).
///
/// Side effects (post-commit):
///   * `_snapshotBundle` copies the pre-mutation `manifest.json` into
///     `<mbd>/.history/<ts>-<label>/` for rollback. Snapshot lives
///     OUTSIDE the closure's optimistic-checksum window so a copy of
///     `manifest.json` does not race with the very file the mutator is
///     about to overwrite.
///   * `bridge.markActiveTabModified` flags the tab dirty.
///   * `bridge.activateView` routes to the surface named by the
///     mutator's optional `view` summary key.
///   * `bridge.reloadTab` re-reads the manifest so the active editor
///     surface sees the new entry without manual reload.
Future<mk.KernelToolResult> _runKnowledgeMutation(
  Map<String, dynamic> args,
  String toolName,
  ChromeBridge bridge,
  Map<String, dynamic> Function(Map<String, dynamic> manifest) mutate,
) async {
  final mbd = args['mbdPath'];
  if (mbd is! String || mbd.isEmpty) {
    return mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(text: '{"ok":false,"error":"mbdPath required"}'),
      ],
      isError: true,
    );
  }
  // Snapshot the pre-mutation manifest BEFORE entering the mutator
  // transaction. Lives under `.history/` so the optimistic checksum
  // (which watches `manifest.json` only) is unaffected.
  await _snapshotBundle(
    mbd,
    toolName.split('.').last,
    files: const <String>['manifest.json'],
  );
  late final Map<String, dynamic> summary;
  try {
    summary = await mk.McpBundleMutator.mutate<Map<String, dynamic>>(
      mbd,
      // Lenient at both the inbound load (legacy bundles may pre-date
      // top-level `schemaVersion`) and the post-mutation reparse —
      // authoring layer tolerates partial / migrating manifests while
      // structural breakage still throws.
      options: const mk.McpLoaderOptions.lenient(),
      fn: (current) async {
        final raw = current.toJson();
        final result = mutate(raw);
        final updated = mk.McpBundleLoader.fromJson(
          raw,
          options: const mk.McpLoaderOptions.lenient(),
        );
        return mk.MutationOutcome<Map<String, dynamic>>(
          updated: updated,
          result: result,
        );
      },
    );
  } on mk.BundleMutationException catch (e) {
    return mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(
          text: jsonEncode(<String, dynamic>{
            'ok': false,
            'error': e.message,
            'reason': e.reason.name,
            'tool': toolName,
          }),
        ),
      ],
      isError: true,
    );
  } on mk.BundleValidationException catch (e) {
    // Surface every validation error message individually — the
    // toString summary ("1 errors") hides which field broke.
    final issues = <String>[for (final err in e.errors) err.toString()];
    return mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(
          text: jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'schema validation failed',
            'issues': issues,
            'warnings': e.warnings,
            'tool': toolName,
          }),
        ),
      ],
      isError: true,
    );
  } catch (e) {
    return mk.KernelToolResult(
      content: <mk.KernelContent>[
        mk.KernelTextContent(
          text: jsonEncode(<String, dynamic>{
            'ok': false,
            'error': e.toString(),
            'tool': toolName,
          }),
        ),
      ],
      isError: true,
    );
  }
  // Mark the active tab modified — the user has touched the
  // manifest, so closing the tab silently would surprise them.
  // Picked up by `_closeTab` to gate the Cancel / Close-anyway
  // dialog. Best effort; failure here doesn't fail the mutation.
  try {
    bridge.markActiveTabModified?.call();
  } catch (_) {
    /* swallow */
  }
  // Tool → view path: if the mutator returned a `view` target, ask
  // the renderer to activate it so the user (or the LLM driving over
  // MCP) lands on the screen showing the new wiring. Best effort.
  final viewTarget = summary['view'];
  if (viewTarget is String && viewTarget.isNotEmpty) {
    final activator = bridge.activateView;
    if (activator != null) {
      try {
        activator(viewTarget, null);
      } catch (_) {
        /* swallow — view activation is non-fatal */
      }
    }
  }
  // Always reload the active tab so the editor surfaces re-read the
  // manifest — without it the left-pane list stays stale and the new
  // entry isn't visible until the user manually reloads. Best effort.
  final reload = bridge.reloadTab;
  if (reload != null) {
    try {
      reload(null);
    } catch (_) {
      /* swallow — reload is non-fatal */
    }
  }
  return mk.KernelToolResult(
    content: <mk.KernelContent>[
      mk.KernelTextContent(
        text: jsonEncode(<String, dynamic>{'ok': true, ...summary}),
      ),
    ],
  );
}

/// Snapshot the files [files] (relative to [mbdPath]) into
/// `<mbdPath>/.history/<ts>-<label>/` before a mutator overwrites them.
/// Cheap, best-effort, idempotent — failure here never blocks the
/// mutation. The `.history/` directory accumulates one snapshot per
/// mutation so the user can recover from accidental edits (LLM
/// runaway, manual mistake) without losing the auto-save behaviour
/// that makes chat-driven authoring fluid. Excluded from the bundle's
/// shipped content by the install path (see `BundleInstallSurface`).
Future<void> _snapshotBundle(
  String mbdPath,
  String label, {
  required List<String> files,
}) async {
  try {
    final ts =
        DateTime.now()
            .toUtc()
            .toIso8601String()
            .replaceAll(':', '-')
            .split('.')
            .first;
    final dir = Directory(p.join(mbdPath, '.history', '$ts-$label'));
    await dir.create(recursive: true);
    for (final rel in files) {
      final src = File(p.join(mbdPath, rel));
      if (!await src.exists()) continue;
      final dst = File(p.join(dir.path, rel));
      await dst.parent.create(recursive: true);
      await src.copy(dst.path);
    }
  } catch (_) {
    /* swallow — snapshot is best-effort */
  }
}

Map<String, dynamic> _ensureMap(Map<String, dynamic> parent, String key) {
  final existing = parent[key];
  if (existing is Map<String, dynamic>) return existing;
  if (existing is Map) {
    final m = Map<String, dynamic>.from(existing);
    parent[key] = m;
    return m;
  }
  final m = <String, dynamic>{};
  parent[key] = m;
  return m;
}

List<dynamic> _ensureList(Map<String, dynamic> parent, String key) {
  final existing = parent[key];
  if (existing is List) return existing;
  final list = <dynamic>[];
  parent[key] = list;
  return list;
}

/// Apply a single JSON Patch (RFC 6902) operation against [root].
/// Supports `add` · `remove` · `replace` · `move` · `copy` · `test`.
/// Throws [FormatException] on unsupported op or invalid path.
void _applyRfc6902Op(Map<String, dynamic> root, Map entry) {
  final op = entry['op']?.toString();
  final path = entry['path']?.toString();
  if (op == null || op.isEmpty || path == null || path.isEmpty) {
    throw FormatException('rfc6902 op requires op + path');
  }
  switch (op) {
    case 'add':
      _ptrSet(root, path, entry['value'], insert: true);
      return;
    case 'remove':
      _ptrRemove(root, path);
      return;
    case 'replace':
      _ptrSet(root, path, entry['value'], insert: false);
      return;
    case 'move':
      final from = entry['from']?.toString();
      if (from == null) throw FormatException('move requires from');
      final v = _ptrGet(root, from);
      _ptrRemove(root, from);
      _ptrSet(root, path, v, insert: true);
      return;
    case 'copy':
      final from = entry['from']?.toString();
      if (from == null) throw FormatException('copy requires from');
      _ptrSet(root, path, _ptrGet(root, from), insert: true);
      return;
    case 'test':
      final v = _ptrGet(root, path);
      if (jsonEncode(v) != jsonEncode(entry['value'])) {
        throw FormatException('test failed at $path');
      }
      return;
    default:
      throw FormatException('unsupported rfc6902 op: $op');
  }
}

List<String> _ptrSegments(String pointer) {
  if (pointer == '') return const <String>[];
  if (!pointer.startsWith('/')) {
    throw FormatException('JSON Pointer must start with /: $pointer');
  }
  return pointer
      .substring(1)
      .split('/')
      .map((s) => s.replaceAll('~1', '/').replaceAll('~0', '~'))
      .toList();
}

Object? _ptrGet(Object? root, String pointer) {
  Object? cur = root;
  for (final seg in _ptrSegments(pointer)) {
    if (cur is Map) {
      cur = cur[seg];
    } else if (cur is List) {
      final idx = int.tryParse(seg);
      if (idx == null || idx < 0 || idx >= cur.length) {
        throw FormatException('JSON Pointer list index OOB: $pointer');
      }
      cur = cur[idx];
    } else {
      throw FormatException('JSON Pointer traversal failed at $seg: $pointer');
    }
  }
  return cur;
}

void _ptrSet(
  Object? root,
  String pointer,
  Object? value, {
  required bool insert,
}) {
  final segs = _ptrSegments(pointer);
  if (segs.isEmpty) {
    throw FormatException('JSON Pointer empty (cannot set root)');
  }
  Object? parent = root;
  for (var i = 0; i < segs.length - 1; i++) {
    final seg = segs[i];
    if (parent is Map) {
      parent = parent[seg];
    } else if (parent is List) {
      final idx = int.tryParse(seg);
      if (idx == null || idx < 0 || idx >= parent.length) {
        throw FormatException('JSON Pointer list index OOB: $pointer');
      }
      parent = parent[idx];
    } else {
      throw FormatException('JSON Pointer traversal failed at $seg: $pointer');
    }
  }
  final last = segs.last;
  if (parent is Map) {
    parent[last] = value;
  } else if (parent is List) {
    if (last == '-') {
      parent.add(value);
    } else {
      final idx = int.tryParse(last);
      if (idx == null) {
        throw FormatException('JSON Pointer list index invalid: $last');
      }
      if (insert) {
        if (idx < 0 || idx > parent.length) {
          throw FormatException('JSON Pointer add index OOB: $idx');
        }
        parent.insert(idx, value);
      } else {
        if (idx < 0 || idx >= parent.length) {
          throw FormatException('JSON Pointer replace index OOB: $idx');
        }
        parent[idx] = value;
      }
    }
  } else {
    throw FormatException(
      'JSON Pointer cannot set on non-collection: $pointer',
    );
  }
}

void _ptrRemove(Object? root, String pointer) {
  final segs = _ptrSegments(pointer);
  if (segs.isEmpty) {
    throw FormatException('JSON Pointer empty (cannot remove root)');
  }
  Object? parent = root;
  for (var i = 0; i < segs.length - 1; i++) {
    final seg = segs[i];
    if (parent is Map) {
      parent = parent[seg];
    } else if (parent is List) {
      final idx = int.tryParse(seg);
      if (idx == null) {
        throw FormatException('JSON Pointer list index invalid: $seg');
      }
      parent = parent[idx];
    } else {
      throw FormatException('JSON Pointer traversal failed at $seg: $pointer');
    }
  }
  final last = segs.last;
  if (parent is Map) {
    parent.remove(last);
  } else if (parent is List) {
    final idx = int.tryParse(last);
    if (idx == null) {
      throw FormatException('JSON Pointer list index invalid: $last');
    }
    if (idx < 0 || idx >= parent.length) {
      throw FormatException('JSON Pointer remove index OOB: $idx');
    }
    parent.removeAt(idx);
  } else {
    throw FormatException(
      'JSON Pointer cannot remove on non-collection: $pointer',
    );
  }
}

/// Recursive deep merge of [src] into [dst], in place. Map+Map values
/// merge recursively; everything else (arrays, primitives, null)
/// replaces dst's slot wholesale. Used by `patchManifest` when called
/// with `deepMerge:true` to avoid clobbering sibling sub-keys (e.g.
/// extending `knowledge.knowledge[]` without losing `knowledge.skills[]`).
void _deepMergeInto(Map<String, dynamic> dst, Map src) {
  src.forEach((k, v) {
    final key = k.toString();
    final existing = dst[key];
    if (existing is Map<String, dynamic> && v is Map) {
      _deepMergeInto(existing, v);
    } else {
      dst[key] = v;
    }
  });
}

/// Pair of `(section, list)` keys describing where a top-level section
/// entry lives under the bundle manifest. `section` is the top-level
/// JSON key (e.g. `workflows`), `list` is the inner array key under it
/// (e.g. `workflows.workflows[]`). Used by [_upsertTopLevelList] /
/// [studio.builder.addKnowledge] to route entries to the canonical
/// mcp_bundle schema location instead of the legacy nested
/// `knowledge.<key>[]` path.
class _SectionRoute {
  const _SectionRoute(this.section, this.list);
  final String section;
  final String list;
}

/// Upsert [entry] (keyed by `entry.id`) into
/// `manifest.<sectionKey>.<listKey>[]`. Creates the section + list when
/// absent. Mirrors [_upsertKnowledgeList]'s contract, but the section
/// lives at the manifest top level instead of nested under `knowledge`.
Map<String, dynamic> _upsertTopLevelList(
  Map<String, dynamic> manifest, {
  required String sectionKey,
  required String listKey,
  required Map<String, dynamic> entry,
}) {
  final id = entry['id'];
  if (id is! String || id.isEmpty) {
    throw FormatException('$sectionKey entry must include id (string)');
  }
  final section = _ensureMap(manifest, sectionKey);
  final list = _ensureList(section, listKey);
  final existing = list.indexWhere((e) => e is Map && e['id'] == id);
  if (existing >= 0) {
    list[existing] = Map<String, dynamic>.from(entry);
  } else {
    list.add(Map<String, dynamic>.from(entry));
  }
  return <String, dynamic>{'added': listKey, 'id': id};
}

/// Per-kind partial validation — dispatches to
/// `mcp_bundle.PartialValidators` for the canonical entry-shape checks
/// shipped alongside the authoring API (mcp_bundle 0.3.3 G3). Returns
/// the issue list when the entry is malformed; `null` for clean entries.
List<String>? _validateKnowledgeEntry(String kind, Map<String, dynamic> entry) {
  switch (kind) {
    case 'source':
      return mk.PartialValidators.validateKnowledgeSource(entry);
    case 'fact':
      return mk.PartialValidators.validateFact(entry);
    case 'skill':
      return mk.PartialValidators.validateSkill(entry);
    case 'profile':
      return mk.PartialValidators.validateProfile(entry);
    case 'philosophy':
      return mk.PartialValidators.validatePhilosophy(entry);
    case 'workflow':
      return mk.PartialValidators.validateWorkflow(entry);
    case 'pipeline':
      return mk.PartialValidators.validatePipeline(entry);
    case 'runbook':
      return mk.PartialValidators.validateRunbook(entry);
    case 'agent':
      return mk.PartialValidators.validateAgent(entry);
    default:
      return <String>['unsupported kind: $kind'];
  }
}

Map<String, dynamic> _upsertKnowledgeList(
  Map<String, dynamic> manifest,
  String key,
  Object? entry,
) {
  if (entry is! Map ||
      entry['id'] is! String ||
      (entry['id'] as String).isEmpty) {
    throw FormatException('$key entry must include id (string)');
  }
  final knowledge = _ensureMap(manifest, 'knowledge');
  final list = _ensureList(knowledge, key);
  final id = entry['id'] as String;
  final existing = list.indexWhere((e) => e is Map && e['id'] == id);
  if (existing >= 0) {
    list[existing] = Map<String, dynamic>.from(entry);
  } else {
    list.add(Map<String, dynamic>.from(entry));
  }
  return <String, dynamic>{'added': key, 'id': id};
}
