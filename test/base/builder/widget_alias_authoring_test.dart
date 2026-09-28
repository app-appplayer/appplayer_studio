// The spec lets a widget answer to more than one name. `box` is also
// `container`, `constrained`, `decoratedBox`, `constrainedBox`; `mediaPlayer`
// is also `video` and `audio`; `textInput` is also `textField`, `textfield`,
// `textFormField`, `text-form-field`. The runtime registers every one of them,
// so a document may carry any — and 31 widgets declare them.
//
// The catalogue read none. `aliases:` was parsed for PROPERTIES and never for
// the widget itself, so authoring answered `unknownType` for a spelling the
// spec declares, the schema accepts and the runtime draws. Nothing was red:
// the canonical name works, and an author who used it never saw the hole.
//
// Worse, the seed TEACHES three of those spellings, so an agent following its
// own vocabulary was refused by its own tool.
//
// Two axes are locked here:
//   1. every spelling the spec declares resolves to its canonical widget;
//   2. every type spelling the seed teaches is one the catalogue accepts.
//
// The second is the axis the seed guards did not have: they check the cited
// spec version and the enum values, so a taught TYPE that authoring rejects
// stayed green.
//
// Skipped, not failed, without a `specs/` tree — a standalone clone has none.

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/builder/builder_catalog_service.dart';
import 'package:appplayer_studio/src/base/builder/dsl_spec_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final specsRoot = _findUp((d) {
    final c = Directory(p.join(d, 'specs', 'mcp_ui_dsl'));
    return c.existsSync() ? p.join(d, 'specs') : null;
  });
  final packageRoot = _findUp(
    (d) =>
        File(p.join(d, 'seed', 'app_builder.mbd', 'manifest.json')).existsSync()
        ? d
        : null,
  );
  final skip = specsRoot == null ? 'no specs/ tree beside the studio' : null;

  test('every spelling the spec declares resolves to its widget', () async {
    final loader = DslSpecLoader(specsRoot: specsRoot);
    final all = await loader.load();
    final declared = <String, String>{
      for (final s in all)
        for (final a in s.aliases) a: s.type,
    };
    expect(
      declared,
      isNotEmpty,
      reason: 'no widget-level aliases parsed — the spec declares them on 31 '
          'widgets, so an empty map means the loader stopped reading them',
    );

    final catalog = BuilderCatalogService(dsl: loader);
    final unresolved = <String>[];
    final misrouted = <String>[];
    for (final entry in declared.entries) {
      final spec = await catalog.schema(entry.key);
      if (spec == null) {
        unresolved.add(entry.key);
      } else if (spec.type != entry.value) {
        misrouted.add('${entry.key} → ${spec.type} (want ${entry.value})');
      }
    }
    expect(
      unresolved,
      isEmpty,
      reason: 'the spec declares these spellings and authoring calls them '
          'unknown types',
    );
    expect(misrouted, isEmpty, reason: 'alias resolved to the wrong widget');
  }, skip: skip);

  test('a canonical name is never shadowed by another widget\'s alias',
      () async {
    // Built rather than read: today's spec has 48 alias names and not one
    // collides with a canonical widget, so asserting this against the real
    // tree passes without exercising anything. A synthetic tree gives the
    // rule an actual case — the day a spec introduces the collision, the
    // ordering is already pinned instead of silently retargeting documents.
    final dir = await Directory.systemTemp.createTemp('alias_shadow');
    addTearDown(() => dir.delete(recursive: true));
    final widgets = Directory(
      p.join(dir.path, 'mcp_ui_dsl', 'spec', kDslSpecVersion, 'widgets', 'x'),
    )..createSync(recursive: true);
    File(p.join(widgets.path, 'gauge.yaml')).writeAsStringSync(
      'type: gauge\ncategory: x\ndescription: the real gauge\n',
    );
    File(p.join(widgets.path, 'meter.yaml')).writeAsStringSync(
      'type: meter\ncategory: x\naliases: [gauge]\ndescription: claims it\n',
    );

    final catalog = BuilderCatalogService(
      dsl: DslSpecLoader(specsRoot: dir.path),
    );
    final got = await catalog.schema('gauge');
    expect(
      got?.type,
      'gauge',
      reason: 'a widget that owns its name must win over another widget '
          'claiming that name as an alias',
    );
    expect((await catalog.schema('meter'))?.type, 'meter');
  });

  test('the catalogue lists canonical names only', () async {
    final loader = DslSpecLoader(specsRoot: specsRoot);
    final listed = (await BuilderCatalogService(dsl: loader).list())
        .map((s) => s.type)
        .toList();
    expect(
      listed.length,
      listed.toSet().length,
      reason: 'a widget appears twice — an alias was given a row of its own, '
          'which teaches a vocabulary larger than the spec defines',
    );
    final aliases = <String>{
      for (final s in await loader.load()) ...s.aliases,
    };
    expect(
      listed.where(aliases.contains),
      isEmpty,
      reason: 'an alias is listed as if it were a separate widget',
    );
  }, skip: skip);

  test('the seed teaches no type spelling authoring rejects', () async {
    final catalog = BuilderCatalogService(dsl: DslSpecLoader(specsRoot: specsRoot));
    final taught = _seedTypeSpellings(packageRoot!);
    expect(
      taught,
      isNotEmpty,
      reason: 'no widget type spellings parsed out of the seed — the reader '
          'below found nothing, so this test cannot fail',
    );
    final rejected = <String>[];
    for (final t in taught) {
      if (await catalog.schema(t) == null) rejected.add(t);
    }
    expect(
      rejected,
      isEmpty,
      reason: 'the seed teaches spellings the authoring surface refuses, so an '
          'agent following its own vocabulary is refused by its own tool',
    );
  }, skip: skip);
}

/// Type spellings the seed offers as authorable — the backticked names in the
/// widget documents' opening line, which is where the seed names the widget
/// and its other spellings (`textInput` (also `textField`, `text-form-field`)).
Set<String> _seedTypeSpellings(String packageRoot) {
  final manifest = File(
    p.join(packageRoot, 'seed', 'app_builder.mbd', 'manifest.json'),
  );
  if (!manifest.existsSync()) return <String>{};
  final doc = jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
  final sources = ((doc['knowledge'] as Map)['sources'] as List).cast<Map>();
  final out = <String>{};
  // Spec vocabulary only. The studio's own `Vbu*` atoms resolve through the
  // asset bundle, which a plain `test()` has no binding for — they would all
  // read as rejected here and the failure would be the harness, not the seed.
  // Their reachability is asserted where the bundle exists (the Pro-tier atom
  // asset test).
  for (final id in <String>['mcp_ui_dsl_widgets']) {
    final source = sources.where((s) => s['id'] == id);
    if (source.isEmpty) continue;
    for (final d in (source.first['documents'] as List).cast<Map>()) {
      final content = d['content'];
      if (content is! String || content.isEmpty) continue;
      // The opening line names the widget and its other spellings:
      //   `textInput` (also `textField`, `textfield`, `text-form-field`) — …
      final first = content.split('\n').first;
      final head = first.contains('—') ? first.split('—').first : first;
      for (final m in RegExp(r'`([A-Za-z][A-Za-z0-9_-]*)`').allMatches(head)) {
        out.add(m.group(1)!);
      }
    }
  }
  return out;
}

String? _findUp(String? Function(String dir) probe) {
  var dir = Directory.current.path;
  for (var i = 0; i < 8; i++) {
    final hit = probe(dir);
    if (hit != null) return hit;
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return null;
}
