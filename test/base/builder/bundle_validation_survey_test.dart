// Measurement, not a gate.
//
// The workspace path mounts documents with `validateSchema: false`, and the
// comment above that line says why: host-registered `Vbu*` widgets were not in
// the core schema, so validation rejected them up front. Runtime 0.6.1 changed
// the contract — validation now consults the widget registry — so the reason is
// gone and the switch can be flipped. Before flipping it, measure: how many of
// the bundles on disk would be rejected, and for what.
//
// Prints a survey and asserts nothing about the count. A red build here would
// say "the bundles on disk disagree with the schema", which is exactly the
// thing being measured rather than a regression to block on.

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/builder/builder_catalog_service.dart';
import 'package:appplayer_studio/src/base/builder/schema_validator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('survey: which bundles on disk would fail authoring validation',
      () async {
    final root = _findStudioRoot();
    if (root == null) {
      // A standalone clone has no monorepo trees to survey.
      return;
    }
    final validator = SchemaValidator(BuilderCatalogService());
    final files = <File>[];
    for (final sub in const ['seed', 'example']) {
      final dir = Directory(p.join(root, sub));
      if (!dir.existsSync()) continue;
      files.addAll(dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json') && f.path.contains('/ui/'))
          // `.history/` holds previous writes of the same document; surveying
          // them would weight one bundle by how often it was edited.
          .where((f) => !f.path.contains('/.history/')));
    }

    var docs = 0, nodes = 0, rejected = 0;
    final byCode = <String, int>{};
    final samples = <String>[];

    Future<void> walk(Object? node, String where) async {
      if (node is List) {
        for (final e in node) {
          await walk(e, where);
        }
        return;
      }
      if (node is! Map) return;
      // Document roots (`page` / `application`) are not widgets — they are
      // the container the widget tree hangs from. Counting them as widgets
      // made the first survey report every document as rejected.
      const docRoots = <String>{'page', 'application'};
      if (node['type'] is String && !docRoots.contains(node['type'])) {
        nodes++;
        final r = await validator.validateNode(node);
        if (!r.ok) {
          rejected++;
          final code = '${r.rejection?['code']}';
          byCode[code] = (byCode[code] ?? 0) + 1;
          if (samples.length < 12) {
            samples.add('$where :: ${node['type']} → $code '
                '${r.rejection?['message']}');
          }
          return; // do not double-count the subtree of a rejected node
        }
      }
      for (final v in node.values) {
        await walk(v, where);
      }
    }

    for (final f in files) {
      Object? doc;
      try {
        doc = jsonDecode(f.readAsStringSync());
      } catch (_) {
        continue;
      }
      docs++;
      await walk(doc, p.relative(f.path, from: root));
    }

    // ignore: avoid_print
    print('bundle validation survey — docs: $docs · nodes: $nodes · '
        'rejected: $rejected');
    // ignore: avoid_print
    print('by code: $byCode');
    for (final s in samples) {
      // ignore: avoid_print
      print('  $s');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

String? _findStudioRoot() {
  var dir = Directory.current.path;
  for (var i = 0; i < 6; i++) {
    if (Directory(p.join(dir, 'seed')).existsSync() &&
        Directory(p.join(dir, 'example')).existsSync()) {
      return dir;
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return null;
}
