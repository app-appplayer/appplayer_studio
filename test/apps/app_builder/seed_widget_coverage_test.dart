// The seed teaches an agent what it may author with, and it taught 11 of the
// specification's 158 widgets and 13 of the studio's 44. Nothing was red about
// that: an agent reaches for what it knows, authors a competent app out of
// eleven widgets, and the other 147 are simply never used. Missing vocabulary
// does not look like a defect from the inside.
//
// So coverage is asserted, not assumed. The seed is generated from the two
// sources that define the vocabulary — the spec's widget yamls and the studio's
// atom yamls — and this fails when the generated file on disk no longer matches
// them. A version-up that adds a widget turns this red until the seed is
// regenerated:
//
//   dart run tool/generate_seed_widget_knowledge.dart
//
// Skipped, not failed, when the specs tree is absent — a standalone clone of
// the studio has no `specs/` beside it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final specsRoot = _findUp((d) {
    final c = Directory(p.join(d, 'specs', 'mcp_ui_dsl'));
    return c.existsSync() ? p.join(d, 'specs') : null;
  });
  // Located by the seed itself, not by the generator beside it: the release
  // mirror carries `lib/`, `seed/` and `test/` and not `tool/`, so anchoring on
  // the generator finds nothing there and every assertion below dies on a null
  // rather than reporting what it checked.
  final packageRoot = _findUp((d) =>
      File(p.join(d, 'seed', 'app_builder.mbd', 'manifest.json')).existsSync()
          ? d
          : null);

  test('the seed teaches every widget the specification defines', () {
    final version = _specVersion(packageRoot!);
    final widgets = Directory(
            p.join(specsRoot!, 'mcp_ui_dsl', 'spec', version, 'widgets'))
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) =>
            f.path.endsWith('.yaml') && !p.basename(f.path).startsWith('_'))
        .length;
    expect(widgets, greaterThan(100), reason: 'spec widget yamls not found');

    final taught = _docIds(packageRoot, 'mcp_ui_dsl_widgets');
    expect(taught.length, widgets,
        reason: 'the seed teaches ${taught.length} of $widgets spec widgets — '
            'run dart run tool/generate_seed_widget_knowledge.dart');
  }, skip: specsRoot == null ? 'no specs/ tree beside the studio' : null);

  test('and every custom widget the studio registers', () {
    final atoms = Directory(p.join(packageRoot!, 'lib', 'src', 'ui', 'atoms'))
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yaml'))
        .length;
    expect(atoms, greaterThan(0), reason: 'atom specs not found');

    final taught = _docIds(packageRoot, 'mcp_ui_dsl_custom_widgets');
    expect(taught.length, atoms,
        reason: 'the seed teaches ${taught.length} of $atoms custom widgets — '
            'run dart run tool/generate_seed_widget_knowledge.dart');
  });

  test('every taught widget carries its declared properties', () {
    // Coverage by count alone would pass on 158 empty documents. Each doc must
    // actually say what the widget takes.
    final docs = _docs(packageRoot!, 'mcp_ui_dsl_widgets');
    final silent = docs
        .where((d) =>
            !'${d['content']}'.contains('Required:') &&
            !'${d['content']}'.contains('Optional:') &&
            !'${d['content']}'.contains('Declares no properties'))
        .map((d) => d['id'])
        .toList();
    expect(silent, isEmpty,
        reason: 'these docs name a widget without saying what it takes');
  }, skip: specsRoot == null ? 'no specs/ tree beside the studio' : null);
}

String _specVersion(String packageRoot) {
  final src =
      File(p.join(packageRoot, 'lib/src/base/builder/dsl_spec_loader.dart'))
          .readAsStringSync();
  final m = RegExp(r"kDslSpecVersion\s*=\s*'([\d.]+)'").firstMatch(src);
  return m!.group(1)!;
}

List<Map<String, dynamic>> _docs(String packageRoot, String sourceId) {
  final manifest = jsonDecode(
      File(p.join(packageRoot, 'seed', 'app_builder.mbd', 'manifest.json'))
          .readAsStringSync()) as Map<String, dynamic>;
  final sources =
      ((manifest['knowledge'] as Map)['sources'] as List).cast<Map>();
  final target = sources.firstWhere((s) => s['id'] == sourceId);
  return (target['documents'] as List).cast<Map<String, dynamic>>();
}

List<String> _docIds(String packageRoot, String sourceId) =>
    [for (final d in _docs(packageRoot, sourceId)) '${d['id']}'];

String? _findUp(String? Function(String dir) probe) {
  var dir = Directory.current.path;
  while (true) {
    final hit = probe(dir);
    if (hit != null) return hit;
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}
