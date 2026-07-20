/// Unit coverage for `registerBuilderMutatorTools` — the 24
/// `studio.builder.*` manifest-mutator MCP tools registered directly on
/// a bare `InProcessKernelServerHost` (no transport, no `KernelApp`
/// boot needed — the tools only depend on the abstract
/// `KernelServerHost.addTool` / `callTool` surface).
///
/// Locks:
///   - every tool name registers under `studio.builder.*`.
///   - argument validation (missing/wrong-typed required fields) on a
///     representative slice of tools returns `{ok:false, error}` /
///     `isError:true` without touching disk.
///   - each `_runKnowledgeMutation`-routed mutator upserts by its
///     documented key (idempotent second call replaces, not appends)
///     and routes to the correct manifest section per mcp_bundle's
///     canonical shape (e.g. skill -> `skills.modules[]`, not
///     `skills.skills[]`).
///   - `patchManifest`'s three modes (`merge` shallow / `deepMerge`
///     recursive / `rfc6902`) and the RFC 6902 op set (`add` /
///     `remove` / `replace` / `move` / `copy` / `test`) including
///     malformed-op error paths — this is the only reachable surface
///     for the private `_applyRfc6902Op` / `_ptrGet` / `_ptrSet` /
///     `_ptrRemove` helpers (library-private, not exported).
///   - `_runKnowledgeMutation`'s three catch branches:
///     `BundleMutationException` (bundle dir missing / manifest.json
///     missing), generic `catch(e)` (closure-thrown FormatException /
///     StateError), and the bridge side-effects
///     (`markActiveTabModified` / `activateView` / `reloadTab`).
///   - `readManifest` / `readBundle` (strict vs lenient, section
///     filter, validation-failure surfacing) / `writeBundleFile`.
///
/// NOT covered (documented, not silently skipped):
///   - `_runKnowledgeMutation`'s `on BundleValidationException` branch
///     is unreachable through this file's call sites: both the
///     mutator's inbound load AND its post-mutation reparse always
///     pass `McpLoaderOptions.lenient()` (`allowPartialLoad: true`),
///     which never throws regardless of accumulated errors — only
///     `readBundle`'s independent strict-mode load can raise
///     `BundleValidationException`, which IS covered below.
///   - `studio.builder.readBundle`'s `on mk.BundleValidationException`
///     branch is covered directly (schemaVersion-missing under strict
///     load); the generic `catch(e)` fallback on that same tool is
///     covered via a plain missing-manifest.json load failure
///     (`BundleLoadException`, not a validation exception).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

/// Invoke a registered tool by name and decode its JSON text payload —
/// mirrors the `_call` helper in `discovery_tools_test.dart` /
/// `extension_connect_tool_test.dart`, adapted to `KernelServerHost`'s
/// direct `callTool` (no `HostToolRegistry` indirection needed since
/// these tools register straight onto the abstract host).
Future<Map<String, dynamic>> _call(
  mk.KernelServerHost host,
  String name,
  Map<String, dynamic> args,
) async {
  final result = await host.callTool(name, args);
  final text = (result.content.first as mk.KernelTextContent).text;
  return jsonDecode(text) as Map<String, dynamic>;
}

void main() {
  late Directory tmpDir;
  late mk.InProcessKernelServerHost host;
  late ChromeBridge bridge;
  late String mbdPath;

  // Bridge call trackers — set fresh per test via setUp so each test
  // observes only its own calls.
  late int modifiedCalls;
  late int reloadCalls;
  late List<String> activatedViews;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('builder_mutator_test_');
    final mbdDir = Directory(p.join(tmpDir.path, 'sample.mbd'));
    await mbdDir.create(recursive: true);
    mbdPath = mbdDir.path;

    modifiedCalls = 0;
    reloadCalls = 0;
    activatedViews = <String>[];
    bridge = ChromeBridge();
    // NOTE: assigned as separate statements (not cascaded) — an arrow
    // function body (`=>`) greedily parses a full `expression`, which
    // grammatically includes trailing cascade sections. Cascading these
    // assignments off one `ChromeBridge()` receiver would have each
    // subsequent `..` bind to the previous closure's return value
    // instead of the bridge.
    bridge.markActiveTabModified = () => modifiedCalls++;
    bridge.reloadTab = (_) => reloadCalls++;
    bridge.activateView = (target, [args]) {
      activatedViews.add(target);
      return <String, dynamic>{'ok': true, 'target': target};
    };

    host = mk.InProcessKernelServerHost(name: 'mutator-test', version: '0.0.0');
    registerBuilderMutatorTools(host, bridge: bridge);
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<void> writeManifest(Map<String, dynamic> json) async {
    await File(
      p.join(mbdPath, 'manifest.json'),
    ).writeAsString(jsonEncode(json));
  }

  Future<Map<String, dynamic>> readManifestFile() async {
    final raw = await File(p.join(mbdPath, 'manifest.json')).readAsString();
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  Map<String, dynamic> baseManifest({String id = 'com.example.test'}) =>
      <String, dynamic>{
        'manifest': <String, dynamic>{
          'id': id,
          'name': 'Test Bundle',
          'version': '1.0.0',
        },
      };

  // ── Registration ──────────────────────────────────────────────

  test('registers all 24 studio.builder.* tools', () {
    final names = host.toolDefinitions.map((d) => d.name).toSet();
    expect(
      names,
      containsAll(<String>[
        'studio.builder.writeUI',
        'studio.builder.writeScenario',
        'studio.builder.patchManifest',
        'studio.builder.addTool',
        'studio.builder.addKnowledgeSource',
        'studio.builder.addKnowledgeDoc',
        'studio.builder.addSkill',
        'studio.builder.addProfile',
        'studio.builder.addPhilosophy',
        'studio.builder.addKnowledge',
        'studio.builder.addKnowledgeEntry',
        'studio.builder.addSlashCommand',
        'studio.builder.addDomainAction',
        'studio.builder.addSettingsSection',
        'studio.builder.addSettingsField',
        'studio.builder.addSettingsEntry',
        'studio.builder.addAgent',
        'studio.builder.addFlow',
        'studio.builder.addBehavior',
        'studio.builder.addFact',
        'studio.builder.addEmbeddedFact',
        'studio.builder.readManifest',
        'studio.builder.readBundle',
        'studio.builder.writeBundleFile',
      ]),
    );
  });

  // ── writeUI ───────────────────────────────────────────────────

  group('writeUI', () {
    test('missing mbdPath rejects', () async {
      final out = await _call(host, 'studio.builder.writeUI', {
        'json': {'type': 'page'},
      });
      expect(out['ok'], isFalse);
    });

    test('non-object json rejects', () async {
      final out = await _call(host, 'studio.builder.writeUI', {
        'mbdPath': mbdPath,
        'json': 'nope',
      });
      expect(out['ok'], isFalse);
    });

    test('bundle not found rejects', () async {
      final out = await _call(host, 'studio.builder.writeUI', {
        'mbdPath': p.join(tmpDir.path, 'ghost.mbd'),
        'json': {'type': 'page'},
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('bundle not found'));
    });

    test('success writes ui/app.json + seeds manifest.ui + reloads',
        () async {
      await writeManifest(baseManifest());
      final page = <String, dynamic>{
        'type': 'page',
        'content': <String, dynamic>{'type': 'text', 'text': 'hi'},
      };
      final out = await _call(host, 'studio.builder.writeUI', {
        'mbdPath': mbdPath,
        'json': page,
      });
      expect(out['ok'], isTrue);
      expect(out['path'], p.join(mbdPath, 'ui', 'app.json'));
      final written = jsonDecode(
        await File(p.join(mbdPath, 'ui', 'app.json')).readAsString(),
      );
      expect(written, page);
      final manifest = await readManifestFile();
      expect(manifest['ui'], <String, dynamic>{
        'kind': 'mcp_ui_dsl',
        'path': 'ui/app.json',
      });
      expect(modifiedCalls, greaterThanOrEqualTo(1));
      expect(reloadCalls, greaterThanOrEqualTo(1));
    });

    test('does not overwrite an existing manifest.ui block', () async {
      final seeded = baseManifest();
      seeded['ui'] = <String, dynamic>{'kind': 'custom', 'path': 'x.json'};
      await writeManifest(seeded);
      await _call(host, 'studio.builder.writeUI', {
        'mbdPath': mbdPath,
        'json': {'type': 'page'},
      });
      final manifest = await readManifestFile();
      expect(manifest['ui'], <String, dynamic>{
        'kind': 'custom',
        'path': 'x.json',
      });
    });
  });

  // ── writeScenario ─────────────────────────────────────────────

  group('writeScenario', () {
    test('missing mbdPath rejects', () async {
      final out = await _call(host, 'studio.builder.writeScenario', {
        'scenario': {'id': 'intro'},
      });
      expect(out['ok'], isFalse);
    });

    test('non-object scenario rejects', () async {
      final out = await _call(host, 'studio.builder.writeScenario', {
        'mbdPath': mbdPath,
        'scenario': 'nope',
      });
      expect(out['ok'], isFalse);
    });

    test('missing scenario.id rejects', () async {
      final out = await _call(host, 'studio.builder.writeScenario', {
        'mbdPath': mbdPath,
        'scenario': <String, dynamic>{'steps': <dynamic>[]},
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('scenario.id'));
    });

    test('bundle not found rejects', () async {
      final out = await _call(host, 'studio.builder.writeScenario', {
        'mbdPath': p.join(tmpDir.path, 'ghost.mbd'),
        'scenario': {'id': 'intro'},
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('bundle not found'));
    });

    test('success writes scenarios/<id>.json + marks modified + reloads',
        () async {
      final scenario = <String, dynamic>{
        'id': 'intro',
        'steps': <dynamic>['a', 'b'],
      };
      final out = await _call(host, 'studio.builder.writeScenario', {
        'mbdPath': mbdPath,
        'scenario': scenario,
      });
      expect(out['ok'], isTrue);
      expect(out['id'], 'intro');
      final written = jsonDecode(
        await File(p.join(mbdPath, 'scenarios', 'intro.json')).readAsString(),
      );
      expect(written, scenario);
      expect(modifiedCalls, 1);
      expect(reloadCalls, 1);
      // Not routed through `_runKnowledgeMutation` — no view activation.
      expect(activatedViews, isEmpty);
    });
  });

  // ── patchManifest ─────────────────────────────────────────────

  group('patchManifest', () {
    test('invalid mbdPath type rejects', () async {
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': 123,
      });
      expect(out['ok'], isFalse);
    });

    test('op:merge without patch rejects', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'merge',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('op:merge requires patch'));
    });

    test('op:rfc6902 without ops rejects', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('op:rfc6902 requires ops'));
    });

    test('fresh draft: missing manifest.json is seeded then merged',
        () async {
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'patch': <String, dynamic>{
          'manifest': <String, dynamic>{
            'id': 'com.example.fresh',
            'name': 'Fresh',
            'version': '1.0.0',
          },
        },
      });
      expect(out['ok'], isTrue);
      final manifest = out['manifest'] as Map;
      expect((manifest['manifest'] as Map)['id'], 'com.example.fresh');
    });

    test('merge mode shallow-replaces top-level key', () async {
      final seeded = baseManifest();
      seeded['tools'] = <String, dynamic>{
        'tools': <dynamic>[
          <String, dynamic>{
            'name': 'old',
            'kind': 'js',
            'target': <String, dynamic>{'entry': 'tools/old.js', 'fn': 'old'},
          },
        ],
      };
      await writeManifest(seeded);
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'patch': <String, dynamic>{
          'tools': <String, dynamic>{'tools': <dynamic>[]},
        },
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      // `ToolsSection.toJson()` omits the `tools` key entirely when
      // the list is empty — the shallow replace still "won" (the old
      // entry is gone), it just surfaces as an absent key rather than
      // an empty list after the mutator's typed reparse-on-write.
      final tools = manifest['tools'];
      if (tools is Map) {
        expect(tools['tools'] ?? const <dynamic>[], isEmpty);
      } else {
        expect(tools, isNull);
      }
    });

    test('deepMerge:true preserves sibling keys under a shared parent',
        () async {
      // `wiring` is a modeled top-level section with two typed sibling
      // lists (`domainActions` / `settings`) — both survive the
      // mutator's typed reparse-on-write, unlike an ad-hoc nested key
      // the section model doesn't recognize.
      final seeded = baseManifest();
      seeded['wiring'] = <String, dynamic>{
        'domainActions': <dynamic>[
          <String, dynamic>{'tool': 'keep.me', 'icon': 'star'},
        ],
      };
      await writeManifest(seeded);
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'merge',
        'deepMerge': true,
        'patch': <String, dynamic>{
          'wiring': <String, dynamic>{
            'settings': <dynamic>[
              <String, dynamic>{'tool': 'new.entry', 'label': 'New'},
            ],
          },
        },
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final wiring = manifest['wiring'] as Map;
      expect((wiring['domainActions'] as List).single['tool'], 'keep.me');
      expect((wiring['settings'] as List).single['tool'], 'new.entry');
    });

    test('rfc6902 add/replace/remove/move/copy/test round-trip', () async {
      final seeded = baseManifest();
      seeded['facts'] = <String, dynamic>{
        'facts': <dynamic>[
          <String, dynamic>{'id': 'f1', 'subject': 'a', 'predicate': 'is', 'object': 'b'},
        ],
      };
      await writeManifest(seeded);

      // add (append via '-')
      var out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{
            'op': 'add',
            'path': '/facts/facts/-',
            'value': <String, dynamic>{
              'id': 'f2',
              'subject': 'c',
              'predicate': 'is',
              'object': 'd',
            },
          },
        ],
      });
      expect(out['ok'], isTrue, reason: out.toString());
      var manifest = await readManifestFile();
      expect((manifest['facts'] as Map)['facts'], hasLength(2));

      // replace index 0's subject via a nested manifest key add first,
      // then replace.
      out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{
            'op': 'replace',
            'path': '/facts/facts/0/subject',
            'value': 'z',
          },
        ],
      });
      expect(out['ok'], isTrue, reason: out.toString());
      manifest = await readManifestFile();
      expect(
        ((manifest['facts'] as Map)['facts'] as List).first['subject'],
        'z',
      );

      // test op passes (value matches) as a no-op guard, then remove.
      out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{
            'op': 'test',
            'path': '/facts/facts/0/subject',
            'value': 'z',
          },
          <String, dynamic>{'op': 'remove', 'path': '/facts/facts/1'},
        ],
      });
      expect(out['ok'], isTrue, reason: out.toString());
      manifest = await readManifestFile();
      expect((manifest['facts'] as Map)['facts'], hasLength(1));

      // copy + move against a top-level key the mcp_bundle schema does
      // not model (`customTag`) — round-trips verbatim through the
      // loader's `extensions._unmodeledTopLevel` capture + `toJson`
      // re-spread, unlike a nested key inside a typed section (e.g.
      // `manifest.*`), which the typed reparse-on-write silently drops.
      final withCustom = await readManifestFile();
      withCustom['customTag'] = 'hello';
      await writeManifest(withCustom);

      out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{
            'op': 'copy',
            'from': '/customTag',
            'path': '/customTagCopy',
          },
        ],
      });
      expect(out['ok'], isTrue, reason: out.toString());
      manifest = await readManifestFile();
      expect(manifest['customTagCopy'], 'hello');

      out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{
            'op': 'move',
            'from': '/customTagCopy',
            'path': '/customTagMoved',
          },
        ],
      });
      expect(out['ok'], isTrue, reason: out.toString());
      manifest = await readManifestFile();
      expect(manifest.containsKey('customTagCopy'), isFalse);
      expect(manifest['customTagMoved'], 'hello');
    });

    test('rfc6902 test-op mismatch fails the whole patch', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{
            'op': 'test',
            'path': '/manifest/name',
            'value': 'not-the-real-name',
          },
        ],
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('test failed'));
    });

    test('rfc6902 unsupported op fails', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{'op': 'frobnicate', 'path': '/manifest/name'},
        ],
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('unsupported rfc6902 op'));
    });

    test('rfc6902 op entry missing op/path fails', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{'value': 'x'},
        ],
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('requires op + path'));
    });

    test('rfc6902 move/copy without `from` fails', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{'op': 'move', 'path': '/manifest/name'},
        ],
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('move requires from'));

      out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{'op': 'copy', 'path': '/manifest/name'},
        ],
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('copy requires from'));
    });

    test('rfc6902 non-Map ops entries are silently skipped', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>['not-a-map'],
      });
      expect(out['ok'], isTrue);
    });

    test('rfc6902 add index OOB fails', () async {
      // FactsSection.toJson() omits `facts` entirely when the list is
      // empty (`if (facts.isNotEmpty) 'facts': ...`) — seed one real
      // entry so the key (and therefore the pointer's parent list)
      // survives the mutator's typed reload before the OOB add runs.
      final seeded = baseManifest();
      seeded['facts'] = <String, dynamic>{
        'facts': <dynamic>[
          <String, dynamic>{'id': 'f1', 'subject': 'a', 'predicate': 'is', 'object': 'b'},
        ],
      };
      await writeManifest(seeded);
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{
            'op': 'add',
            'path': '/facts/facts/5',
            'value': <String, dynamic>{'id': 'x'},
          },
        ],
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('OOB'));
    });

    test('rfc6902 pointer must start with / ', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.patchManifest', {
        'mbdPath': mbdPath,
        'op': 'rfc6902',
        'ops': <dynamic>[
          <String, dynamic>{'op': 'remove', 'path': 'no-leading-slash'},
        ],
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('must start with /'));
    });
  });

  // ── addTool ───────────────────────────────────────────────────

  group('addTool', () {
    test('invalid args (wrong types) rejects', () async {
      final out = await _call(host, 'studio.builder.addTool', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('invalid args'));
    });

    test('toolDef missing name/target.entry rejects', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addTool', {
        'mbdPath': mbdPath,
        'toolDef': <String, dynamic>{'kind': 'js'},
        'jsSource': 'async function x(){}',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('name'));
    });

    test('manifest.json missing rejects', () async {
      final out = await _call(host, 'studio.builder.addTool', {
        'mbdPath': mbdPath,
        'toolDef': <String, dynamic>{
          'name': 'shout',
          'target': <String, dynamic>{'entry': 'tools/shout.js', 'fn': 'shout'},
        },
        'jsSource': 'async function shout(){}',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('manifest.json not found'));
    });

    test('success writes js source + upserts manifest.tools.tools[] + '
        'activates tools/tool view', () async {
      await writeManifest(baseManifest());
      final def = <String, dynamic>{
        'name': 'shout',
        'kind': 'js',
        'description': 'shout loudly',
        'target': <String, dynamic>{'entry': 'tools/shout.js', 'fn': 'shout'},
      };
      var out = await _call(host, 'studio.builder.addTool', {
        'mbdPath': mbdPath,
        'toolDef': def,
        'jsSource': 'async function shout(){ return 1; }',
      });
      expect(out['ok'], isTrue);
      expect(out['toolName'], 'shout');
      expect(activatedViews, contains('tools/tool'));
      final jsContent =
          await File(p.join(mbdPath, 'tools', 'shout.js')).readAsString();
      expect(jsContent, 'async function shout(){ return 1; }');
      var manifest = await readManifestFile();
      var tools = (manifest['tools'] as Map)['tools'] as List;
      expect(tools, hasLength(1));

      // Upsert: same name replaces (idempotent-by-name), not appends.
      out = await _call(host, 'studio.builder.addTool', {
        'mbdPath': mbdPath,
        'toolDef': <String, dynamic>{
          ...def,
          'description': 'shout even louder',
        },
        'jsSource': 'async function shout(){ return 2; }',
      });
      expect(out['ok'], isTrue);
      manifest = await readManifestFile();
      tools = (manifest['tools'] as Map)['tools'] as List;
      expect(tools, hasLength(1));
      expect(tools.single['description'], 'shout even louder');
    });
  });

  // ── addKnowledgeSource / addKnowledgeDoc ─────────────────────

  group('addKnowledgeSource + addKnowledgeDoc', () {
    test('addKnowledgeSource requires source.id', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addKnowledgeSource', {
        'mbdPath': mbdPath,
        'source': <String, dynamic>{'name': 'no id'},
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('source.id required'));
    });

    test('addKnowledgeSource adds then upserts by id', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addKnowledgeSource', {
        'mbdPath': mbdPath,
        'source': <String, dynamic>{'id': 'src1', 'name': 'Source One'},
      });
      expect(out['ok'], isTrue);
      out = await _call(host, 'studio.builder.addKnowledgeSource', {
        'mbdPath': mbdPath,
        'source': <String, dynamic>{'id': 'src1', 'name': 'Renamed'},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final sources = (manifest['knowledge'] as Map)['sources'] as List;
      expect(sources, hasLength(1));
      expect(sources.single['name'], 'Renamed');
    });

    test('addKnowledgeDoc rejects missing sourceId / bad doc', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addKnowledgeDoc', {
        'mbdPath': mbdPath,
        'doc': <String, dynamic>{'id': 'd1', 'content': 'x'},
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('sourceId required'));

      out = await _call(host, 'studio.builder.addKnowledgeDoc', {
        'mbdPath': mbdPath,
        'sourceId': 'src1',
        'doc': <String, dynamic>{'id': 'd1'},
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('id (string) + content'));
    });

    test('addKnowledgeDoc rejects unknown source', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addKnowledgeDoc', {
        'mbdPath': mbdPath,
        'sourceId': 'ghost',
        'doc': <String, dynamic>{'id': 'd1', 'content': 'x'},
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('source "ghost" not found'));
    });

    test('addKnowledgeDoc adds then upserts by doc.id under its source',
        () async {
      await writeManifest(baseManifest());
      await _call(host, 'studio.builder.addKnowledgeSource', {
        'mbdPath': mbdPath,
        'source': <String, dynamic>{'id': 'src1', 'name': 'S1'},
      });
      var out = await _call(host, 'studio.builder.addKnowledgeDoc', {
        'mbdPath': mbdPath,
        'sourceId': 'src1',
        'doc': <String, dynamic>{'id': 'd1', 'content': 'first'},
      });
      expect(out['ok'], isTrue);
      out = await _call(host, 'studio.builder.addKnowledgeDoc', {
        'mbdPath': mbdPath,
        'sourceId': 'src1',
        'doc': <String, dynamic>{'id': 'd1', 'content': 'second'},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final sources = (manifest['knowledge'] as Map)['sources'] as List;
      final docs = (sources.single as Map)['documents'] as List;
      expect(docs, hasLength(1));
      expect(docs.single['content'], 'second');
    });
  });

  // ── addSkill / addProfile / addPhilosophy (top-level section routing) ──

  group('addSkill / addProfile / addPhilosophy', () {
    test('addSkill requires a Map entry', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addSkill', {
        'mbdPath': mbdPath,
        'skill': 'nope',
      });
      expect(out['ok'], isFalse);
    });

    test('addSkill routes to skills.modules[] (legacy alias key)',
        () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addSkill', {
        'mbdPath': mbdPath,
        'skill': <String, dynamic>{'id': 'sk1', 'name': 'Skill One'},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      expect((manifest['skills'] as Map)['modules'], hasLength(1));
    });

    test('addProfile routes to profiles.profiles[]', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addProfile', {
        'mbdPath': mbdPath,
        'profile': <String, dynamic>{'id': 'p1', 'name': 'Profile One'},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      expect((manifest['profiles'] as Map)['profiles'], hasLength(1));
    });

    test('addPhilosophy routes to philosophy.philosophies[]', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addPhilosophy', {
        'mbdPath': mbdPath,
        'philosophy': <String, dynamic>{'id': 'ph1', 'name': 'Phil One'},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      expect((manifest['philosophy'] as Map)['philosophies'], hasLength(1));
    });
  });

  // ── addKnowledge (unified upsert, kind-dispatched) ──────────────

  group('addKnowledge', () {
    test('missing kind rejects', () async {
      final out = await _call(host, 'studio.builder.addKnowledge', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'id': 'x'},
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('kind required'));
    });

    test('missing entry rejects', () async {
      final out = await _call(host, 'studio.builder.addKnowledge', {
        'mbdPath': mbdPath,
        'kind': 'fact',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('entry required'));
    });

    test('validation failure surfaces issues[] without touching disk',
        () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addKnowledge', {
        'mbdPath': mbdPath,
        'kind': 'skill',
        'entry': <String, dynamic>{'id': 'sk-noname'},
      });
      expect(out['ok'], isFalse);
      expect(out['issues'], isNotEmpty);
      final manifest = await readManifestFile();
      expect(manifest.containsKey('skills'), isFalse);
    });

    // Each supported kind routes to its documented section/list per
    // mcp_bundle's canonical schema. `_upsertKnowledgeList` /
    // `_upsertTopLevelList` both report `added: <listKey>` (not the
    // caller's `kind` string) — e.g. kind `skill` reports
    // `added: 'modules'` (the legacy alias list key).
    final cases = <String, ({String section, String list, Map<String, dynamic> entry})>{
      'source': (
        section: 'knowledge',
        list: 'sources',
        entry: <String, dynamic>{'id': 'k-src', 'name': 'Src'},
      ),
      'fact': (
        section: 'facts',
        list: 'facts',
        entry: <String, dynamic>{'id': 'k-fact'},
      ),
      'skill': (
        section: 'skills',
        list: 'modules',
        entry: <String, dynamic>{'id': 'k-skill', 'name': 'Skill'},
      ),
      'profile': (
        section: 'profiles',
        list: 'profiles',
        entry: <String, dynamic>{'id': 'k-profile', 'name': 'Profile'},
      ),
      'philosophy': (
        section: 'philosophy',
        list: 'philosophies',
        entry: <String, dynamic>{'id': 'k-phil', 'name': 'Phil'},
      ),
      'workflow': (
        section: 'workflows',
        list: 'workflows',
        entry: <String, dynamic>{'id': 'k-wf', 'name': 'Workflow'},
      ),
      'pipeline': (
        section: 'pipelines',
        list: 'pipelines',
        entry: <String, dynamic>{'id': 'k-pipe', 'name': 'Pipeline'},
      ),
      'runbook': (
        section: 'runbooks',
        list: 'runbooks',
        entry: <String, dynamic>{'id': 'k-rb', 'name': 'Runbook'},
      ),
      'agent': (
        section: 'agents',
        list: 'agents',
        entry: <String, dynamic>{'id': 'k-agent', 'name': 'Agent', 'role': 'helper'},
      ),
    };
    for (final entry in cases.entries) {
      test('kind=${entry.key} routes to ${entry.value.section}.${entry.value.list}[]',
          () async {
        await writeManifest(baseManifest());
        final out = await _call(host, 'studio.builder.addKnowledge', {
          'mbdPath': mbdPath,
          'kind': entry.key,
          'entry': entry.value.entry,
        });
        expect(out['ok'], isTrue, reason: out.toString());
        expect(out['added'], entry.value.list);
        final manifest = await readManifestFile();
        final list =
            (manifest[entry.value.section] as Map)[entry.value.list] as List;
        expect(list, hasLength(1));
        expect(list.single['id'], entry.value.entry['id']);
      });
    }
  });

  // ── addKnowledgeEntry ─────────────────────────────────────────

  group('addKnowledgeEntry', () {
    test('missing id rejects', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addKnowledgeEntry', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'title': 'no id'},
      });
      expect(out['ok'], isFalse);
    });

    test('adds then upserts by id (tool envelope reports the same id '
        'both times)', () async {
      // `knowledge.knowledge[]` is NOT a field mcp_bundle's
      // `KnowledgeSection` model recognizes (only `sources` is typed) —
      // the entry is dropped by `_runKnowledgeMutation`'s
      // reparse-on-write round trip, so this locks the tool's own
      // success envelope rather than a post-write disk read.
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addKnowledgeEntry', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'id': 'e1', 'title': 'T1', 'body': 'B1'},
      });
      expect(out['ok'], isTrue);
      expect(out['added'], 'knowledge');
      expect(out['id'], 'e1');
      out = await _call(host, 'studio.builder.addKnowledgeEntry', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'id': 'e1', 'title': 'T1-updated', 'body': 'B1'},
      });
      expect(out['ok'], isTrue);
      expect(out['id'], 'e1');
    });
  });

  // ── addSlashCommand ───────────────────────────────────────────

  group('addSlashCommand', () {
    test('missing hint.command rejects', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addSlashCommand', {
        'mbdPath': mbdPath,
        'hint': <String, dynamic>{'template': 'x'},
      });
      expect(out['ok'], isFalse);
    });

    test('adds then upserts by command; activates tools/slash', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addSlashCommand', {
        'mbdPath': mbdPath,
        'hint': <String, dynamic>{'command': '/find', 'template': '/find '},
      });
      expect(out['ok'], isTrue);
      expect(activatedViews, contains('tools/slash'));
      out = await _call(host, 'studio.builder.addSlashCommand', {
        'mbdPath': mbdPath,
        'hint': <String, dynamic>{'command': '/find', 'template': '/find changed '},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final cmds = (manifest['chat'] as Map)['slashCommands'] as List;
      expect(cmds, hasLength(1));
      expect(cmds.single['template'], '/find changed ');
    });
  });

  // ── addDomainAction ───────────────────────────────────────────

  group('addDomainAction', () {
    test('missing entry.tool rejects', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addDomainAction', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'icon': 'star'},
      });
      expect(out['ok'], isFalse);
    });

    test('adds then upserts by tool; activates tools/domain', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addDomainAction', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'tool': 'demo.run', 'icon': 'play'},
      });
      expect(out['ok'], isTrue);
      expect(activatedViews, contains('tools/domain'));
      out = await _call(host, 'studio.builder.addDomainAction', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'tool': 'demo.run', 'icon': 'stop'},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final list = (manifest['wiring'] as Map)['domainActions'] as List;
      expect(list, hasLength(1));
      expect(list.single['icon'], 'stop');
    });
  });

  // ── addSettingsSection + addSettingsField ────────────────────

  group('addSettingsSection + addSettingsField', () {
    test('addSettingsSection requires key + label', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addSettingsSection', {
        'mbdPath': mbdPath,
        'section': <String, dynamic>{'label': 'no key'},
      });
      expect(out['ok'], isFalse);
      out = await _call(host, 'studio.builder.addSettingsSection', {
        'mbdPath': mbdPath,
        'section': <String, dynamic>{'key': 'no-label'},
      });
      expect(out['ok'], isFalse);
    });

    test('addSettingsField rejects unknown section / missing fields',
        () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addSettingsField', {
        'mbdPath': mbdPath,
        'sectionKey': 'ghost',
        'field': <String, dynamic>{
          'key': 'f1',
          'label': 'F1',
          'type': 'text',
        },
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('not found'));

      out = await _call(host, 'studio.builder.addSettingsField', {
        'mbdPath': mbdPath,
        'field': <String, dynamic>{'key': 'f1', 'label': 'F1', 'type': 'text'},
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('sectionKey required'));
    });

    test(
        'creating a section then adding fields preserves them on a '
        'label-only re-register; activates tools/section', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addSettingsSection', {
        'mbdPath': mbdPath,
        'section': <String, dynamic>{'key': 'general', 'label': 'General'},
      });
      expect(out['ok'], isTrue);
      expect(activatedViews, contains('tools/section'));

      out = await _call(host, 'studio.builder.addSettingsField', {
        'mbdPath': mbdPath,
        'sectionKey': 'general',
        'field': <String, dynamic>{
          'key': 'name',
          'label': 'Name',
          'type': 'text',
          'value': 'x',
        },
      });
      expect(out['ok'], isTrue);

      // Re-register the section (label edit) — fields[] must survive.
      out = await _call(host, 'studio.builder.addSettingsSection', {
        'mbdPath': mbdPath,
        'section': <String, dynamic>{
          'key': 'general',
          'label': 'General Settings',
        },
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final sections = (manifest['settings'] as Map)['sections'] as List;
      expect(sections, hasLength(1));
      final section = sections.single as Map;
      expect(section['label'], 'General Settings');
      expect((section['fields'] as List), hasLength(1));

      // Upsert same field key — replaces, not appends.
      out = await _call(host, 'studio.builder.addSettingsField', {
        'mbdPath': mbdPath,
        'sectionKey': 'general',
        'field': <String, dynamic>{
          'key': 'name',
          'label': 'Name',
          'type': 'text',
          'value': 'y',
        },
      });
      expect(out['ok'], isTrue);
      final manifest2 = await readManifestFile();
      final fields =
          ((manifest2['settings'] as Map)['sections'] as List).single['fields']
              as List;
      expect(fields, hasLength(1));
      expect(fields.single['value'], 'y');
    });
  });

  // ── addSettingsEntry ──────────────────────────────────────────

  group('addSettingsEntry', () {
    test('requires entry.tool + entry.label', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addSettingsEntry', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'label': 'no tool'},
      });
      expect(out['ok'], isFalse);
      out = await _call(host, 'studio.builder.addSettingsEntry', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'tool': 'demo.clear'},
      });
      expect(out['ok'], isFalse);
    });

    test('adds then upserts by tool', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addSettingsEntry', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'tool': 'demo.clear', 'label': 'Clear'},
      });
      expect(out['ok'], isTrue);
      out = await _call(host, 'studio.builder.addSettingsEntry', {
        'mbdPath': mbdPath,
        'entry': <String, dynamic>{'tool': 'demo.clear', 'label': 'Clear Cache'},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final list = (manifest['wiring'] as Map)['settings'] as List;
      expect(list, hasLength(1));
      expect(list.single['label'], 'Clear Cache');
    });
  });

  // ── addAgent / addFlow / addBehavior / addFact / addEmbeddedFact ──

  group('addAgent', () {
    test('requires agent.id', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addAgent', {
        'mbdPath': mbdPath,
        'agent': <String, dynamic>{'name': 'no id'},
      });
      expect(out['ok'], isFalse);
    });

    test('adds then upserts by id under agents.agents[]', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addAgent', {
        'mbdPath': mbdPath,
        'agent': <String, dynamic>{'id': 'a1', 'name': 'Agent One'},
      });
      expect(out['ok'], isTrue);
      out = await _call(host, 'studio.builder.addAgent', {
        'mbdPath': mbdPath,
        'agent': <String, dynamic>{'id': 'a1', 'name': 'Agent One Renamed'},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final list = (manifest['agents'] as Map)['agents'] as List;
      expect(list, hasLength(1));
      expect(list.single['name'], 'Agent One Renamed');
    });
  });

  group('addFlow', () {
    test('requires flow.id', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addFlow', {
        'mbdPath': mbdPath,
        'flow': <String, dynamic>{'name': 'no id'},
      });
      expect(out['ok'], isFalse);
    });

    test('adds then upserts by id under flow.flows[]', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addFlow', {
        'mbdPath': mbdPath,
        'flow': <String, dynamic>{'id': 'f1', 'name': 'Flow One', 'steps': <dynamic>[]},
      });
      expect(out['ok'], isTrue);
      out = await _call(host, 'studio.builder.addFlow', {
        'mbdPath': mbdPath,
        'flow': <String, dynamic>{'id': 'f1', 'name': 'Flow One v2', 'steps': <dynamic>[]},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final list = (manifest['flow'] as Map)['flows'] as List;
      expect(list, hasLength(1));
      expect(list.single['name'], 'Flow One v2');
    });
  });

  group('addBehavior', () {
    test('requires behavior.id', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addBehavior', {
        'mbdPath': mbdPath,
        'behavior': <String, dynamic>{'name': 'no id'},
      });
      expect(out['ok'], isFalse);
    });

    test('adds then upserts by id under behavior.definitions[]', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addBehavior', {
        'mbdPath': mbdPath,
        'behavior': <String, dynamic>{'id': 'b1', 'name': 'B1', 'steps': <dynamic>[]},
      });
      expect(out['ok'], isTrue);
      out = await _call(host, 'studio.builder.addBehavior', {
        'mbdPath': mbdPath,
        'behavior': <String, dynamic>{'id': 'b1', 'name': 'B1 v2', 'steps': <dynamic>[]},
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final list = (manifest['behavior'] as Map)['definitions'] as List;
      expect(list, hasLength(1));
      expect(list.single['name'], 'B1 v2');
    });
  });

  group('addFact', () {
    test('requires subject + predicate + object', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addFact', {
        'mbdPath': mbdPath,
        'fact': <String, dynamic>{'subject': 'a'},
      });
      expect(out['ok'], isFalse);
    });

    test('with id: adds then upserts; without id: always appends',
        () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addFact', {
        'mbdPath': mbdPath,
        'fact': <String, dynamic>{
          'id': 'fact1',
          'subject': 'sky',
          'predicate': 'is',
          'object': 'blue',
        },
      });
      expect(out['ok'], isTrue);
      out = await _call(host, 'studio.builder.addFact', {
        'mbdPath': mbdPath,
        'fact': <String, dynamic>{
          'id': 'fact1',
          'subject': 'sky',
          'predicate': 'is',
          'object': 'grey',
        },
      });
      expect(out['ok'], isTrue);
      var manifest = await readManifestFile();
      var list = (manifest['facts'] as Map)['facts'] as List;
      expect(list, hasLength(1));
      expect(list.single['object'], 'grey');

      out = await _call(host, 'studio.builder.addFact', {
        'mbdPath': mbdPath,
        'fact': <String, dynamic>{
          'subject': 'grass',
          'predicate': 'is',
          'object': 'green',
        },
      });
      expect(out['ok'], isTrue);
      expect(out['id'], '<append>');
      manifest = await readManifestFile();
      list = (manifest['facts'] as Map)['facts'] as List;
      expect(list, hasLength(2));
    });
  });

  group('addEmbeddedFact', () {
    test('requires fact.id', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.addEmbeddedFact', {
        'mbdPath': mbdPath,
        'fact': <String, dynamic>{'entityId': 'e1'},
      });
      expect(out['ok'], isFalse);
    });

    test('adds then upserts by id under factGraph.embedded.facts[]',
        () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.addEmbeddedFact', {
        'mbdPath': mbdPath,
        'fact': <String, dynamic>{
          'id': 'ef1',
          'entityId': 'e1',
          'type': 'claim',
          'content': 'v1',
        },
      });
      expect(out['ok'], isTrue);
      out = await _call(host, 'studio.builder.addEmbeddedFact', {
        'mbdPath': mbdPath,
        'fact': <String, dynamic>{
          'id': 'ef1',
          'entityId': 'e1',
          'type': 'claim',
          'content': 'v2',
        },
      });
      expect(out['ok'], isTrue);
      final manifest = await readManifestFile();
      final list =
          ((manifest['factGraph'] as Map)['embedded'] as Map)['facts']
              as List;
      expect(list, hasLength(1));
      expect(list.single['content'], 'v2');
    });
  });

  // ── _runKnowledgeMutation guard branches ─────────────────────

  group('_runKnowledgeMutation guards', () {
    test('bundle directory missing -> BundleMutationException(lockFailed)',
        () async {
      final out = await _call(host, 'studio.builder.addAgent', {
        'mbdPath': p.join(tmpDir.path, 'never-created.mbd'),
        'agent': <String, dynamic>{'id': 'a1', 'name': 'A'},
      });
      expect(out['ok'], isFalse);
      expect(out['reason'], 'lockFailed');
    });

    test('directory exists but manifest.json missing -> conflict reason',
        () async {
      final dir = Directory(p.join(tmpDir.path, 'no-manifest.mbd'));
      await dir.create(recursive: true);
      final out = await _call(host, 'studio.builder.addAgent', {
        'mbdPath': dir.path,
        'agent': <String, dynamic>{'id': 'a1', 'name': 'A'},
      });
      expect(out['ok'], isFalse);
      expect(out['reason'], 'conflict');
    });
  });

  // ── readManifest ──────────────────────────────────────────────

  group('readManifest', () {
    test('missing mbdPath rejects', () async {
      final out = await _call(host, 'studio.builder.readManifest', {});
      expect(out['ok'], isFalse);
    });

    test('manifest.json not found rejects', () async {
      final out = await _call(host, 'studio.builder.readManifest', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('manifest.json not found'));
    });

    test('malformed (non-object) manifest.json rejects', () async {
      await File(
        p.join(mbdPath, 'manifest.json'),
      ).writeAsString(jsonEncode(<dynamic>['not', 'an', 'object']));
      final out = await _call(host, 'studio.builder.readManifest', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
    });

    test('returns the raw manifest verbatim', () async {
      final seeded = baseManifest();
      await writeManifest(seeded);
      final out = await _call(host, 'studio.builder.readManifest', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isTrue);
      expect(out['manifest'], seeded);
    });
  });

  // ── readBundle ────────────────────────────────────────────────

  group('readBundle', () {
    test('missing mbdPath rejects', () async {
      final out = await _call(host, 'studio.builder.readBundle', {});
      expect(out['ok'], isFalse);
    });

    test('generic load failure (manifest.json missing) hits the fallback '
        'catch(e) branch', () async {
      final out = await _call(host, 'studio.builder.readBundle', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['error'], isNot(contains('BundleValidationException')));
    });

    test('strict load (default) fails on missing schemaVersion; lenient '
        'succeeds', () async {
      await writeManifest(baseManifest());
      var out = await _call(host, 'studio.builder.readBundle', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['error'], 'BundleValidationException');
      expect(out['errors'], isNotEmpty);
      expect(out['hint'], contains('lenient'));

      out = await _call(host, 'studio.builder.readBundle', {
        'mbdPath': mbdPath,
        'lenient': true,
      });
      expect(out['ok'], isTrue);
      expect(out['lenient'], isTrue);
      expect(out['bundle'], isA<Map>());
    });

    test('sections filter narrows the response to the requested keys',
        () async {
      final seeded = baseManifest();
      seeded['schemaVersion'] = '1.0.0';
      seeded['facts'] = <String, dynamic>{
        'facts': <dynamic>[
          <String, dynamic>{'id': 'f1', 'subject': 'a', 'predicate': 'is', 'object': 'b'},
        ],
      };
      await writeManifest(seeded);
      final out = await _call(host, 'studio.builder.readBundle', {
        'mbdPath': mbdPath,
        'sections': <dynamic>['manifest'],
      });
      expect(out['ok'], isTrue);
      final bundle = out['bundle'] as Map;
      expect(bundle.containsKey('manifest'), isTrue);
      expect(bundle.containsKey('facts'), isFalse);
    });
  });

  // ── writeBundleFile ───────────────────────────────────────────

  group('writeBundleFile', () {
    test('missing mbdPath / folder / relPath / content each reject',
        () async {
      var out = await _call(host, 'studio.builder.writeBundleFile', {});
      expect(out['ok'], isFalse);
      out = await _call(host, 'studio.builder.writeBundleFile', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      out = await _call(host, 'studio.builder.writeBundleFile', {
        'mbdPath': mbdPath,
        'folder': 'knowledge',
      });
      expect(out['ok'], isFalse);
      out = await _call(host, 'studio.builder.writeBundleFile', {
        'mbdPath': mbdPath,
        'folder': 'knowledge',
        'relPath': 'doc.md',
      });
      expect(out['ok'], isFalse);
    });

    test('unknown folder name rejects with allowed list', () async {
      final out = await _call(host, 'studio.builder.writeBundleFile', {
        'mbdPath': mbdPath,
        'folder': 'bogus',
        'relPath': 'x',
        'content': 'y',
      });
      expect(out['ok'], isFalse);
      expect(out['error'], contains('unknown folder'));
      expect(out['allowed'], isNotEmpty);
    });

    test('manifest load failure hits the generic catch(e) branch',
        () async {
      final out = await _call(host, 'studio.builder.writeBundleFile', {
        'mbdPath': mbdPath,
        'folder': 'knowledge',
        'relPath': 'doc.md',
        'content': 'hello',
      });
      expect(out['ok'], isFalse);
    });

    test('success writes the file under the reserved folder + marks '
        'modified + reloads', () async {
      await writeManifest(baseManifest());
      final out = await _call(host, 'studio.builder.writeBundleFile', {
        'mbdPath': mbdPath,
        'folder': 'knowledge',
        'relPath': 'doc1.md',
        'content': '# hello',
      });
      expect(out['ok'], isTrue);
      expect(out['folder'], 'knowledge');
      expect(out['relPath'], 'doc1.md');
      expect(out['bytes'], '# hello'.length);
      final written =
          await File(p.join(mbdPath, 'knowledge', 'doc1.md')).readAsString();
      expect(written, '# hello');
      expect(modifiedCalls, greaterThanOrEqualTo(1));
      expect(reloadCalls, greaterThanOrEqualTo(1));
    });
  });
}
