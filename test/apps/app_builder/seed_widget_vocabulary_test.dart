// The agent seed teaches the UI DSL vocabulary in prose, and prose does not
// fail to compile when the spec moves. It had gone stale in the way that costs
// the most: the button doc offered `variant:'tonal'`, a value 1.4 does not
// allow, so an agent following its own seed authored a widget the checker now
// rejects — and every widget doc still cited the 1.3 subtree.
//
// This guard reads the spec the studio actually builds against
// (`kDslSpecVersion`) and fails when a seed doc cites another version or offers
// a value that widget's `enum` excludes.
//
// Skipped, not failed, when the specs tree is absent — a standalone clone of
// the studio has no `specs/` beside it.

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/builder/dsl_spec_loader.dart'
    show kDslSpecVersion;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

void main() {
  final specsRoot = _findSpecsRoot();
  final seedRoot = _findSeedRoot();

  test('seed widget docs cite the spec version the studio builds against', () {
    final docs = _widgetDocs(seedRoot!);
    expect(docs, isNotEmpty, reason: 'no seed widget docs found to check');
    final wrong = docs
        .where((d) => d.specVersion != kDslSpecVersion)
        .map((d) => '${d.bundle}/${d.id}: cites ${d.specVersion}')
        .toList();
    expect(wrong, isEmpty,
        reason: 'seed docs cite a spec version other than $kDslSpecVersion — '
            'sync them in the same step as the version-up');
  });

  test('seed widget docs offer no value the spec enum rejects', () {
    final enums = _specEnums(specsRoot!, kDslSpecVersion);
    expect(enums, isNotEmpty, reason: 'no enums parsed from the spec');

    final violations = <String>[];
    for (final doc in _widgetDocs(seedRoot!)) {
      // The seed writes value sets as `prop:'a'|'b'|'c'`.
      final matches =
          RegExp(r"(\w+):((?:'[\w-]+'\|)+'[\w-]+')").allMatches(doc.content);
      for (final m in matches) {
        final key = '${doc.widget}.${m.group(1)}';
        final allowed = enums[key];
        if (allowed == null) continue; // not an enum property — prose is free
        final offered =
            m.group(2)!.split('|').map((s) => s.replaceAll("'", '')).toList();
        final rejected = offered.where((o) => !allowed.contains(o)).toList();
        if (rejected.isNotEmpty) {
          violations.add('${doc.bundle}/${doc.id} $key offers $rejected — '
              'spec allows $allowed');
        }
      }
    }
    expect(violations, isEmpty,
        reason: 'the seed teaches values the authoring checker rejects');
  });
}

class _WidgetDoc {
  _WidgetDoc(this.bundle, this.id, this.widget, this.specVersion, this.content);
  final String bundle;
  final String id;
  final String widget;
  final String specVersion;
  final String content;
}

/// Every knowledge document in every seed bundle whose `source` names a spec
/// widget (`mcp_ui_dsl/<version>/widgets/<widget>`).
List<_WidgetDoc> _widgetDocs(String seedRoot) {
  final out = <_WidgetDoc>[];
  final sourceRe = RegExp(r'^mcp_ui_dsl/(\d+\.\d+)/widgets/(\w+)$');
  for (final dir in Directory(seedRoot).listSync().whereType<Directory>()) {
    final manifest = File(p.join(dir.path, 'manifest.json'));
    if (!manifest.existsSync()) continue;
    final json = jsonDecode(manifest.readAsStringSync());
    if (json is! Map) continue;
    final knowledge = json['knowledge'];
    if (knowledge is! Map) continue;
    final sources = knowledge['sources'];
    if (sources is! List) continue;
    for (final src in sources) {
      final docs = (src is Map) ? src['documents'] : null;
      if (docs is! List) continue;
      for (final d in docs) {
        if (d is! Map) continue;
        final m = sourceRe.firstMatch('${d['source']}');
        if (m == null) continue;
        out.add(_WidgetDoc(p.basename(dir.path), '${d['id']}', m.group(2)!,
            m.group(1)!, '${d['content']}'));
      }
    }
  }
  return out;
}

/// `<widget>.<property>` → allowed values, read from the spec's widget yamls.
Map<String, List<String>> _specEnums(String specsRoot, String version) {
  final dir =
      Directory(p.join(specsRoot, 'mcp_ui_dsl', 'spec', version, 'widgets'));
  final out = <String, List<String>>{};
  if (!dir.existsSync()) return out;
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.yaml')) continue;
    final doc = loadYaml(f.readAsStringSync());
    if (doc is! YamlMap) continue;
    final widget = doc['type'];
    final props = doc['properties'];
    if (widget is! String || props is! YamlMap) continue;
    props.forEach((name, value) {
      if (value is! YamlMap) return;
      final e = value['enum'];
      if (e is! YamlList) return;
      out['$widget.$name'] =
          e.map((v) => '$v'.replaceAll('"', '')).toList(growable: false);
    });
  }
  return out;
}

String? _findSpecsRoot() => _findUp((dir) {
      final c = Directory(p.join(dir, 'specs', 'mcp_ui_dsl'));
      return c.existsSync() ? p.join(dir, 'specs') : null;
    });

String? _findSeedRoot() => _findUp((dir) {
      final c = Directory(p.join(dir, 'seed'));
      return c.existsSync() ? c.path : null;
    });

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
