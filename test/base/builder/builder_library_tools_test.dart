/// Unit coverage for `registerLibraryTools` — the eight
/// `studio.builder.lib.*` tools registered on a bare
/// `InProcessKernelServerHost` over real `BuilderLibraryService` /
/// `BuilderUiWriteService` instances and a fake `BuilderCatalogService`
/// (avoids depending on the real yaml spec loader's filesystem
/// discovery — only `schema(type)` is exercised, so a small in-memory
/// stub locks the same contract without that dependency).
///
/// Locks:
///   - all 8 tools register under `studio.builder.lib.*`.
///   - `_resolveMbdPath`'s two paths: explicit `mbdPath` arg wins,
///     falling back to `resolveActiveMbdPath` when omitted; both
///     absent -> `noActiveProject`.
///   - `list` / `read` / `create` / `delete` / `rename` / `render`
///     each surface `missingRequired` for absent required args and
///     translate `BuilderLibraryService`'s `FormatException` messages
///     into the documented rejection codes (`invalidId` /
///     `alreadyExists` / `pathNotFound`).
///   - `placeInline` — param substitution via `resolveInline`,
///     `emptyEntry` (null-tree) short-circuit, schema-validator
///     rejection BEFORE any disk write, `dryRun` passthrough to
///     `BuilderUiWriteService.addNode`, and its own `pathNotFound`
///     mapping (distinct from the `noActiveProject` / `invalidId` /
///     `emptyEntry` codes above it).
///   - `placeAsTemplate` — register + addNode two-step, idempotent
///     same-JSON re-register, `alreadyExists` without `force`,
///     replace with `force:true`, and the DISTINCT `invalidArgument`
///     code `addTemplate`'s own FormatException maps to (vs
///     `addNode`'s `pathNotFound`).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart';

/// Minimal catalog stub — recognizes exactly two widget types so
/// `SchemaValidator` has something real to check against without
/// touching the on-disk yaml spec loaders.
class _FakeCatalogService extends BuilderCatalogService {
  @override
  Future<WidgetSpec?> schema(String type) async {
    switch (type) {
      case 'box':
        return WidgetSpec(
          type: 'box',
          category: 'layout',
          source: WidgetSource.standard,
          description: 'A box.',
        );
      case 'text':
        return WidgetSpec(
          type: 'text',
          category: 'atom',
          source: WidgetSource.standard,
          description: 'Text.',
          properties: <WidgetPropSpec>[
            WidgetPropSpec(
              key: 'text',
              type: 'string',
              description: 'required | body text',
              required: true,
            ),
          ],
        );
      default:
        return null;
    }
  }
}

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
  late String projectDir;
  late String mbdPath;
  late mk.InProcessKernelServerHost host;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('builder_lib_tools_test_');
    projectDir = tmpDir.path;
    final mbdDir = Directory(p.join(projectDir, 'sample.mbd'));
    await mbdDir.create(recursive: true);
    mbdPath = mbdDir.path;

    host = mk.InProcessKernelServerHost(name: 'lib-test', version: '0.0.0');
    registerLibraryTools(
      host,
      library: BuilderLibraryService(),
      writer: BuilderUiWriteService(),
      validator: SchemaValidator(_FakeCatalogService()),
      // No resolver — every test must supply `mbdPath` explicitly
      // unless testing the fallback resolver directly (separate group).
      resolveActiveMbdPath: null,
    );
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<void> seedLibraryEntry(String id, Object tree) async {
    final libDir = Directory(p.join(projectDir, 'library'));
    if (!libDir.existsSync()) await libDir.create(recursive: true);
    await File(p.join(libDir.path, '$id.json')).writeAsString(jsonEncode(tree));
  }

  /// Seed a null-body entry directly on disk — `jsonDecode('null')`
  /// yields Dart `null`, which `BuilderLibraryService.create` cannot
  /// produce (it always writes at least `{}`).
  Future<void> seedNullEntry(String id) async {
    final libDir = Directory(p.join(projectDir, 'library'));
    if (!libDir.existsSync()) await libDir.create(recursive: true);
    await File(p.join(libDir.path, '$id.json')).writeAsString('null');
  }

  Future<void> writeUiApp(Object root) async {
    final uiDir = Directory(p.join(mbdPath, 'ui'));
    await uiDir.create(recursive: true);
    await File(
      p.join(uiDir.path, 'app.json'),
    ).writeAsString(jsonEncode(root));
  }

  test('registers all 8 studio.builder.lib.* tools', () {
    final names = host.toolDefinitions.map((d) => d.name).toSet();
    expect(
      names,
      containsAll(<String>[
        'studio.builder.lib.list',
        'studio.builder.lib.read',
        'studio.builder.lib.create',
        'studio.builder.lib.delete',
        'studio.builder.lib.rename',
        'studio.builder.lib.render',
        'studio.builder.lib.placeInline',
        'studio.builder.lib.placeAsTemplate',
      ]),
    );
  });

  group('mbdPath resolution', () {
    test('every tool rejects noActiveProject when mbdPath is omitted and '
        'no resolver is wired', () async {
      final out = await _call(host, 'studio.builder.lib.list', {});
      expect(out['ok'], isFalse);
      expect(out['code'], 'noActiveProject');
    });

    test('resolveActiveMbdPath supplies mbdPath when the arg is omitted',
        () async {
      final resolvedHost =
          mk.InProcessKernelServerHost(name: 'lib-resolver-test', version: '0.0.0');
      registerLibraryTools(
        resolvedHost,
        library: BuilderLibraryService(),
        writer: BuilderUiWriteService(),
        validator: SchemaValidator(_FakeCatalogService()),
        resolveActiveMbdPath: () => mbdPath,
      );
      await seedLibraryEntry('fromResolver', <String, dynamic>{'type': 'box'});
      final out = await _call(resolvedHost, 'studio.builder.lib.list', {});
      // `lib.list`'s success payload is `{ids: [...]}` — no top-level
      // `ok` key (unlike most other tools in this file); absence of
      // `code` is the success signal here.
      expect(out['code'], isNull);
      expect(out['ids'], contains('fromResolver'));
    });

    test('explicit mbdPath arg wins over the resolver', () async {
      final otherMbd = Directory(p.join(projectDir, 'other.mbd'));
      await otherMbd.create(recursive: true);
      final resolvedHost =
          mk.InProcessKernelServerHost(name: 'lib-resolver-test2', version: '0.0.0');
      registerLibraryTools(
        resolvedHost,
        library: BuilderLibraryService(),
        writer: BuilderUiWriteService(),
        validator: SchemaValidator(_FakeCatalogService()),
        resolveActiveMbdPath: () => mbdPath,
      );
      final out = await _call(resolvedHost, 'studio.builder.lib.list', {
        'mbdPath': otherMbd.path,
      });
      expect(out['code'], isNull);
      expect(out['ids'], isEmpty);
    });
  });

  group('list', () {
    test('empty library returns an empty id list', () async {
      final out = await _call(host, 'studio.builder.lib.list', {
        'mbdPath': mbdPath,
      });
      expect(out['code'], isNull);
      expect(out['ids'], isEmpty);
    });

    test('returns every stored id', () async {
      await seedLibraryEntry('a', <String, dynamic>{'type': 'box'});
      await seedLibraryEntry('b', <String, dynamic>{'type': 'text', 'text': 'hi'});
      final out = await _call(host, 'studio.builder.lib.list', {
        'mbdPath': mbdPath,
      });
      expect(out['code'], isNull);
      expect(out['ids'], containsAll(<String>['a', 'b']));
    });
  });

  group('read', () {
    test('missing id rejects with missingRequired', () async {
      final out = await _call(host, 'studio.builder.lib.read', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'missingRequired');
    });

    test('unknown id rejects with pathNotFound', () async {
      final out = await _call(host, 'studio.builder.lib.read', {
        'mbdPath': mbdPath,
        'id': 'ghost',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'pathNotFound');
    });

    test('invalid id (bad characters) rejects with invalidId', () async {
      final out = await _call(host, 'studio.builder.lib.read', {
        'mbdPath': mbdPath,
        'id': 'bad id',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'invalidId');
    });

    test('returns the stored tree', () async {
      await seedLibraryEntry('card', <String, dynamic>{'type': 'box'});
      final out = await _call(host, 'studio.builder.lib.read', {
        'mbdPath': mbdPath,
        'id': 'card',
      });
      // `lib.read`'s success payload is `{id, tree}` — no `ok` key.
      expect(out['code'], isNull);
      expect(out['tree'], <String, dynamic>{'type': 'box'});
    });
  });

  group('create', () {
    test('missing id rejects', () async {
      final out = await _call(host, 'studio.builder.lib.create', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'missingRequired');
    });

    test('invalid id rejects with invalidId', () async {
      final out = await _call(host, 'studio.builder.lib.create', {
        'mbdPath': mbdPath,
        'id': 'bad id',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'invalidId');
    });

    test('creates a new entry with the given tree', () async {
      final out = await _call(host, 'studio.builder.lib.create', {
        'mbdPath': mbdPath,
        'id': 'fresh',
        'tree': <String, dynamic>{'type': 'box'},
      });
      expect(out['ok'], isTrue);
      final file = File(p.join(projectDir, 'library', 'fresh.json'));
      expect(jsonDecode(await file.readAsString()), <String, dynamic>{'type': 'box'});
    });

    test('omitted tree creates an empty stub', () async {
      final out = await _call(host, 'studio.builder.lib.create', {
        'mbdPath': mbdPath,
        'id': 'stub',
      });
      expect(out['ok'], isTrue);
      final file = File(p.join(projectDir, 'library', 'stub.json'));
      expect(jsonDecode(await file.readAsString()), <String, dynamic>{});
    });

    test('duplicate id rejects with alreadyExists', () async {
      await _call(host, 'studio.builder.lib.create', {
        'mbdPath': mbdPath,
        'id': 'dup',
      });
      final out = await _call(host, 'studio.builder.lib.create', {
        'mbdPath': mbdPath,
        'id': 'dup',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'alreadyExists');
    });
  });

  group('delete', () {
    test('missing id rejects', () async {
      final out = await _call(host, 'studio.builder.lib.delete', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'missingRequired');
    });

    test('unknown id rejects with pathNotFound', () async {
      final out = await _call(host, 'studio.builder.lib.delete', {
        'mbdPath': mbdPath,
        'id': 'ghost',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'pathNotFound');
    });

    test('removes the entry file', () async {
      await seedLibraryEntry('todel', <String, dynamic>{'type': 'box'});
      final out = await _call(host, 'studio.builder.lib.delete', {
        'mbdPath': mbdPath,
        'id': 'todel',
      });
      expect(out['ok'], isTrue);
      expect(
        File(p.join(projectDir, 'library', 'todel.json')).existsSync(),
        isFalse,
      );
    });
  });

  group('rename', () {
    test('missing oldId/newId rejects', () async {
      final out = await _call(host, 'studio.builder.lib.rename', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'missingRequired');
    });

    test('unknown oldId rejects with pathNotFound', () async {
      final out = await _call(host, 'studio.builder.lib.rename', {
        'mbdPath': mbdPath,
        'oldId': 'ghost',
        'newId': 'target',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'pathNotFound');
    });

    test('existing newId rejects with alreadyExists', () async {
      await seedLibraryEntry('a', <String, dynamic>{'type': 'box'});
      await seedLibraryEntry('b', <String, dynamic>{'type': 'box'});
      final out = await _call(host, 'studio.builder.lib.rename', {
        'mbdPath': mbdPath,
        'oldId': 'a',
        'newId': 'b',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'alreadyExists');
    });

    test('invalid id characters fall through to the generic pathNotFound '
        'code (rename has no dedicated invalidId branch)', () async {
      final out = await _call(host, 'studio.builder.lib.rename', {
        'mbdPath': mbdPath,
        'oldId': 'bad id',
        'newId': 'ok',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'pathNotFound');
    });

    test('renames the entry on disk', () async {
      await seedLibraryEntry('old', <String, dynamic>{'type': 'box'});
      final out = await _call(host, 'studio.builder.lib.rename', {
        'mbdPath': mbdPath,
        'oldId': 'old',
        'newId': 'renamed',
      });
      expect(out['ok'], isTrue);
      expect(
        File(p.join(projectDir, 'library', 'renamed.json')).existsSync(),
        isTrue,
      );
    });
  });

  group('render', () {
    test('missing id rejects', () async {
      final out = await _call(host, 'studio.builder.lib.render', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'missingRequired');
    });

    test('unknown id rejects with pathNotFound', () async {
      final out = await _call(host, 'studio.builder.lib.render', {
        'mbdPath': mbdPath,
        'id': 'ghost',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'pathNotFound');
    });

    test('known id returns the pending-hookup TODO marker', () async {
      await seedLibraryEntry('card', <String, dynamic>{'type': 'box'});
      final out = await _call(host, 'studio.builder.lib.render', {
        'mbdPath': mbdPath,
        'id': 'card',
      });
      expect(out['ok'], isTrue);
      expect(out['id'], 'card');
      expect(out['todo'], isNotEmpty);
    });
  });

  group('placeInline', () {
    test('missing parentPath/libId rejects', () async {
      final out = await _call(host, 'studio.builder.lib.placeInline', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'missingRequired');
    });

    test('unknown libId rejects with pathNotFound', () async {
      final out = await _call(host, 'studio.builder.lib.placeInline', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'ghost',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'pathNotFound');
    });

    test('null-tree entry rejects with emptyEntry', () async {
      await seedNullEntry('nullish');
      final out = await _call(host, 'studio.builder.lib.placeInline', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'nullish',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'emptyEntry');
    });

    test('schema validation rejects an unregistered widget type before '
        'any disk write', () async {
      await seedLibraryEntry('mystery', <String, dynamic>{'type': 'quantum'});
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      final out = await _call(host, 'studio.builder.lib.placeInline', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'mystery',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'unknownType');
      final app = jsonDecode(
        await File(p.join(mbdPath, 'ui', 'app.json')).readAsString(),
      );
      expect((app as Map)['content'], isNull);
    });

    test('addNode failure (unresolvable parentPath) maps to pathNotFound',
        () async {
      await seedLibraryEntry('box1', <String, dynamic>{'type': 'box'});
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      final out = await _call(host, 'studio.builder.lib.placeInline', {
        'mbdPath': mbdPath,
        'parentPath': '/content/99',
        'libId': 'box1',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'pathNotFound');
    });

    test('resolves {{param}} substitution, validates, and addNodes into '
        'ui/app.json', () async {
      await seedLibraryEntry('label', <String, dynamic>{
        'type': 'text',
        'text': '{{msg}}',
      });
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      final out = await _call(host, 'studio.builder.lib.placeInline', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'label',
        'params': <String, dynamic>{'msg': 'hello'},
      });
      expect(out['ok'], isTrue);
      expect(out['libId'], 'label');
      final app = jsonDecode(
        await File(p.join(mbdPath, 'ui', 'app.json')).readAsString(),
      );
      expect((app as Map)['content'], <String, dynamic>{
        'type': 'text',
        'text': 'hello',
      });
    });

    test('unresolved params surface as warnings in the response', () async {
      await seedLibraryEntry('label2', <String, dynamic>{
        'type': 'text',
        'text': '{{missing}}',
      });
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      final out = await _call(host, 'studio.builder.lib.placeInline', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'label2',
      });
      expect(out['ok'], isTrue);
      expect(out['warnings'], contains('unresolved param: missing'));
    });

    test('dryRun:true validates without writing to disk', () async {
      await seedLibraryEntry('box2', <String, dynamic>{'type': 'box'});
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      final out = await _call(host, 'studio.builder.lib.placeInline', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'box2',
        'dryRun': true,
      });
      expect(out['ok'], isTrue);
      expect(out['dryRun'], isTrue);
      final app = jsonDecode(
        await File(p.join(mbdPath, 'ui', 'app.json')).readAsString(),
      );
      expect((app as Map)['content'], isNull);
    });
  });

  group('placeAsTemplate', () {
    test('missing parentPath/libId rejects', () async {
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'missingRequired');
    });

    test('unknown libId rejects with pathNotFound', () async {
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'ghost',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'pathNotFound');
    });

    test('null-tree entry rejects with emptyEntry', () async {
      await seedNullEntry('nullish2');
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'nullish2',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'emptyEntry');
    });

    test('schema validation rejects an unregistered widget type before '
        'registering the template', () async {
      await seedLibraryEntry('mystery2', <String, dynamic>{'type': 'quantum'});
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'mystery2',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'unknownType');
    });

    test('addTemplate failure (missing ui/app.json) maps to '
        'invalidArgument, not pathNotFound', () async {
      await seedLibraryEntry('box3', <String, dynamic>{'type': 'box'});
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'box3',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'invalidArgument');
    });

    test('addNode failure (unresolvable parentPath) maps to pathNotFound '
        'AFTER the template registers successfully', () async {
      await seedLibraryEntry('box4', <String, dynamic>{'type': 'box'});
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content/99',
        'libId': 'box4',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'pathNotFound');
      final app = jsonDecode(
        await File(p.join(mbdPath, 'ui', 'app.json')).readAsString(),
      );
      expect((app as Map)['templates'], <String, dynamic>{
        'box4': <String, dynamic>{'type': 'box'},
      });
    });

    test('registers the template + places a `use` site; defaults '
        'templateName to libId', () async {
      await seedLibraryEntry('badge', <String, dynamic>{
        'type': 'text',
        'text': 'v1',
      });
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'badge',
        'params': <String, dynamic>{'x': 1},
      });
      expect(out['ok'], isTrue);
      expect(out['templateName'], 'badge');
      expect(out['templateRegistered'], isTrue);
      expect(out['templateReplaced'], isFalse);
      final app = jsonDecode(
        await File(p.join(mbdPath, 'ui', 'app.json')).readAsString(),
      ) as Map;
      expect(app['templates'], <String, dynamic>{
        'badge': <String, dynamic>{'type': 'text', 'text': 'v1'},
      });
      expect(app['content'], <String, dynamic>{
        'type': 'use',
        'template': 'badge',
        'params': <String, dynamic>{'x': 1},
      });
    });

    test('re-registering the same body is idempotent (no-op registration)',
        () async {
      await seedLibraryEntry('idem', <String, dynamic>{'type': 'box'});
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'idem',
      });
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'idem',
      });
      expect(out['ok'], isTrue);
      expect(out['templateRegistered'], isFalse);
      expect(out['templateReplaced'], isFalse);
    });

    test('conflicting body without force rejects with alreadyExists',
        () async {
      await seedLibraryEntry('conf', <String, dynamic>{'type': 'box'});
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'conf',
        'templateName': 'shared',
      });
      // Different library entry registered under the SAME templateName.
      await seedLibraryEntry('conf2', <String, dynamic>{'type': 'text', 'text': 'x'});
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'conf2',
        'templateName': 'shared',
      });
      expect(out['ok'], isFalse);
      expect(out['code'], 'alreadyExists');
    });

    test('conflicting body with force:true replaces', () async {
      await seedLibraryEntry('conf3', <String, dynamic>{'type': 'box'});
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'conf3',
        'templateName': 'sharedF',
      });
      await seedLibraryEntry('conf4', <String, dynamic>{'type': 'text', 'text': 'x'});
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'conf4',
        'templateName': 'sharedF',
        'force': true,
      });
      expect(out['ok'], isTrue);
      expect(out['templateReplaced'], isTrue);
    });

    test('dryRun:true validates + registers-in-memory without writing '
        'to disk', () async {
      await seedLibraryEntry('dry', <String, dynamic>{'type': 'box'});
      await writeUiApp(<String, dynamic>{'type': 'page', 'content': null});
      final out = await _call(host, 'studio.builder.lib.placeAsTemplate', {
        'mbdPath': mbdPath,
        'parentPath': '/content',
        'libId': 'dry',
        'dryRun': true,
      });
      expect(out['ok'], isTrue);
      expect(out['dryRun'], isTrue);
      final app = jsonDecode(
        await File(p.join(mbdPath, 'ui', 'app.json')).readAsString(),
      ) as Map;
      expect(app.containsKey('templates'), isFalse);
      expect(app['content'], isNull);
    });
  });
}
