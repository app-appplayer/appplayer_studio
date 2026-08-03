/// Regenerate the App Builder seed's widget vocabulary from the sources that
/// define it.
///
///   dart run tool/generate_seed_widget_knowledge.dart [--check]
///
/// The seed teaches an agent what it may author with. It was written by hand,
/// which meant it taught 11 of the specification's 158 widgets and 13 of the
/// studio's 44 — an agent that follows its own seed reaches for the eleven it
/// knows and never uses the rest, and nothing goes red about it. Prose does not
/// fail to compile.
///
/// Both vocabularies already exist in machine-readable form:
///
///   specs/mcp_ui_dsl/spec/<version>/widgets/**.yaml   the specification
///   lib/src/ui/atoms/*.yaml                            the studio's own atoms
///
/// So the seed is generated from them rather than restated beside them. A
/// version-up that adds a widget adds its doc here; one that removes a property
/// removes it from the doc. There is no third copy to drift.
///
/// Hand-written prose is **kept**. Where a doc already existed, its text is
/// preserved under `Notes:` — the generated part carries the facts, the human
/// part carries the idiom, and neither overwrites the other.
///
/// `--check` writes nothing and exits non-zero when the file on disk differs,
/// so a gate can ask "is the seed current?" without a build step.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/src/base/builder/dsl_spec_loader.dart'
    show kDslSpecVersion;
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// The knowledge source each vocabulary lands in.
const _specSourceId = 'mcp_ui_dsl_widgets';
const _customSourceId = 'mcp_ui_dsl_custom_widgets';

// `exitCode`, not a returned int: Dart ignores what `main` returns, so a gate
// wired to the return value would report a stale seed as green.
Future<void> main(List<String> args) async => exitCode = await _run(args);

Future<int> _run(List<String> args) async {
  final checkOnly = args.contains('--check');

  final specsRoot = _findUp((d) {
    final c = Directory(p.join(d, 'specs', 'mcp_ui_dsl'));
    return c.existsSync() ? p.join(d, 'specs') : null;
  });
  if (specsRoot == null) {
    stderr.writeln('no specs/ tree found above ${Directory.current.path}');
    return 2;
  }
  final seedManifest =
      File(p.join('seed', 'app_builder.mbd', 'manifest.json'));
  if (!seedManifest.existsSync()) {
    stderr.writeln('run this from the studio package root '
        '(no ${seedManifest.path})');
    return 2;
  }

  final specWidgets = _readSpecWidgets(specsRoot, kDslSpecVersion);
  final atoms = _readAtoms(p.join('lib', 'src', 'ui', 'atoms'));
  if (specWidgets.isEmpty || atoms.isEmpty) {
    stderr.writeln('read ${specWidgets.length} spec widgets and '
        '${atoms.length} atoms — refusing to write an empty vocabulary');
    return 2;
  }

  final manifest =
      jsonDecode(seedManifest.readAsStringSync()) as Map<String, dynamic>;
  final sources = ((manifest['knowledge'] as Map)['sources'] as List)
      .cast<Map<String, dynamic>>();

  final notes = _readNotes(p.join('tool', 'seed_widget_notes.json'));

  var changed = false;
  changed |= _rewrite(
    sources,
    _specSourceId,
    [
      for (final w in specWidgets)
        _doc(
          id: 'dsl-${w.type}',
          title: '${w.type} widget',
          source: 'mcp_ui_dsl/$kDslSpecVersion/widgets/${w.type}',
          body: w.describe(),
        ),
    ],
    notes,
  );
  changed |= _rewrite(
    sources,
    _customSourceId,
    [
      for (final w in atoms)
        _doc(
          id: 'custom-${w.type}',
          title: '${w.type} (studio custom widget)',
          source: 'studio/custom_widgets/${w.type}',
          body: w.describe(),
        ),
    ],
    notes,
  );

  // A note that names properties the widget does not have teaches an agent to
  // author something the checker rejects. Report it — the note is prose and
  // will not fail on its own.
  final stale = _staleNotes(notes, [...specWidgets, ...atoms]);
  for (final line in stale) {
    stdout.writeln('note drift: $line');
  }

  final rendered = '${const JsonEncoder.withIndent('  ').convert(manifest)}\n';
  final current = seedManifest.readAsStringSync();
  if (rendered == current) {
    stdout.writeln('seed vocabulary current: '
        '${specWidgets.length} spec widgets, ${atoms.length} custom');
    return 0;
  }
  if (checkOnly) {
    stderr.writeln('seed vocabulary is stale — run '
        'dart run tool/generate_seed_widget_knowledge.dart');
    return 1;
  }
  seedManifest.writeAsStringSync(rendered);
  stdout.writeln('wrote ${specWidgets.length} spec widget docs and '
      '${atoms.length} custom widget docs'
      '${changed ? '' : ' (formatting only)'}');
  return 0;
}

Map<String, dynamic> _doc({
  required String id,
  required String title,
  required String source,
  required String body,
}) =>
    {'id': id, 'title': title, 'source': source, 'content': body};

/// Replace one source's documents, appending the hand-written note for each.
///
/// The notes live in their own file rather than being parsed back out of the
/// generated text. Reading them back out is how the first version of this was
/// written, and it was not idempotent: on the second run it could not tell its
/// own output from a human's sentence, and folded the whole generated body in
/// as a note. A generator that cannot recognise its own output has no fixed
/// point.
bool _rewrite(
  List<Map<String, dynamic>> sources,
  String sourceId,
  List<Map<String, dynamic>> generated,
  Map<String, String> notes,
) {
  final target = sources.firstWhere(
    (s) => s['id'] == sourceId,
    orElse: () => throw StateError('seed has no knowledge source "$sourceId"'),
  );

  final merged = <Map<String, dynamic>>[];
  for (final doc in generated) {
    final note = notes['${doc['id']}']?.trim();
    if (note != null && note.isNotEmpty) {
      doc['content'] = '${doc['content']}\n\n$_marker$note';
    }
    merged.add(doc);
  }
  final before = jsonEncode(target['documents']);
  target['documents'] = merged;
  return jsonEncode(merged) != before;
}

const _marker = 'Notes: ';

/// Property names a note offers that its widget does not declare.
///
/// Written as `name:type` in the seed's own house style, which is what makes
/// this checkable at all — the note says `gap:number`, the widget declares
/// `spacing`, and an agent that follows the note authors a property the
/// runtime ignores.
List<String> _staleNotes(Map<String, String> notes, List<_Widget> widgets) {
  final byId = <String, _Widget>{
    for (final w in widgets) 'dsl-${w.type}': w,
    for (final w in widgets) 'custom-${w.type}': w,
  };
  // `name:` immediately followed by a type — the seed's own house style.
  // Requiring no space after the colon drops prose labels ("Example spacer: …")
  // without needing to know what a label looks like.
  final offered = RegExp(r'\b([a-z][A-Za-z0-9]*):(?=\S)');
  final out = <String>[];
  notes.forEach((id, note) {
    final widget = byId[id];
    if (widget == null) return;
    // Examples and nested-object descriptions carry keys that belong to
    // something else — an action's `tool`, a text style's `fontSize`. Counting
    // those as the widget's own properties is how a checker starts reporting
    // correct documents as wrong.
    final own = note
        .replaceAll(RegExp(r'\{[^{}]*\}'), ' ')
        .replaceAll(RegExp(r'\{[^{}]*\}'), ' ')
        .replaceAll(RegExp(r'\([^()]*\)'), ' ');
    final declared = widget.properties.map((p) => p.name).toSet()
      ..addAll(widget.properties.expand((p) => p.aliases))
      // Every widget carries the shared ones, and `type` names the widget.
      ..addAll(const ['type', 'child', 'children', 'id', 'style', 'key']);
    // A note may name an undeclared property on purpose — to warn that the
    // runtime reads it and the checker still rejects it. Flagging that forever
    // teaches the reader to ignore this report, which is how a warning stops
    // being a warning.
    final deliberate = note.contains('not declared');

    final unknown = offered
        .allMatches(own)
        .map((m) => m.group(1)!)
        .where((n) => !declared.contains(n))
        .toSet()
        .toList()
      ..sort();
    if (deliberate) return;
    if (unknown.isNotEmpty) {
      out.add('$id offers ${unknown.join(', ')} — ${widget.type} declares '
          'none of these');
    }
  });
  out.sort();
  return out;
}

/// Hand-written prose, keyed by document id. Absent file means no notes.
Map<String, String> _readNotes(String at) {
  final f = File(at);
  if (!f.existsSync()) return const {};
  final decoded = jsonDecode(f.readAsStringSync());
  if (decoded is! Map) return const {};
  return {
    for (final e in decoded.entries) '${e.key}': '${e.value}',
  };
}

/// One widget's declared shape, from either vocabulary.
class _Widget {
  _Widget({
    required this.type,
    required this.aliases,
    required this.category,
    required this.profile,
    required this.description,
    required this.properties,
  });

  final String type;
  final List<String> aliases;
  final String? category;
  final String? profile;
  final String description;
  final List<_Prop> properties;

  /// The facts an author needs, in the order they need them.
  String describe() {
    final b = StringBuffer();
    final tags = [
      if (category != null) category,
      if (profile != null) '$profile profile',
    ].join(', ');
    b.write('`$type`');
    if (aliases.isNotEmpty) b.write(' (also ${aliases.map((a) => '`$a`').join(', ')})');
    if (tags.isNotEmpty) b.write(' — $tags');
    b.write('. ');
    b.write(_oneLine(description));

    final required = properties.where((p) => p.required).toList();
    final optional = properties.where((p) => !p.required).toList();
    if (required.isNotEmpty) {
      b.write('\nRequired: ${required.map((p) => p.render()).join(', ')}.');
    }
    if (optional.isNotEmpty) {
      b.write('\nOptional: ${optional.map((p) => p.render()).join(', ')}.');
    }
    if (properties.isEmpty) {
      b.write('\nDeclares no properties of its own.');
    }
    return b.toString();
  }
}

class _Prop {
  _Prop(this.name, this.type, this.required, this.enumValues, this.def,
      this.aliases);

  final String name;
  final String type;
  final bool required;
  final List<String> enumValues;
  final String? def;
  final List<String> aliases;

  String render() {
    final b = StringBuffer('$name:$type');
    final notes = <String>[
      if (enumValues.isNotEmpty) 'one of ${enumValues.join('|')}',
      if (def != null) 'default $def',
      if (aliases.isNotEmpty) 'alias ${aliases.join('/')}',
    ];
    if (notes.isNotEmpty) b.write(' (${notes.join('; ')})');
    return b.toString();
  }
}

List<_Widget> _readSpecWidgets(String specsRoot, String version) {
  final dir =
      Directory(p.join(specsRoot, 'mcp_ui_dsl', 'spec', version, 'widgets'));
  if (!dir.existsSync()) return const [];
  final out = <_Widget>[];
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.yaml')) continue;
    // `_common.yaml` describes properties every widget shares, not a widget.
    if (p.basename(f.path).startsWith('_')) continue;
    final w = _fromYaml(f);
    if (w != null) out.add(w);
  }
  out.sort((a, b) => a.type.compareTo(b.type));
  return out;
}

List<_Widget> _readAtoms(String atomsDir) {
  final dir = Directory(atomsDir);
  if (!dir.existsSync()) return const [];
  final out = <_Widget>[];
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.yaml')) continue;
    final w = _fromYaml(f);
    if (w != null) out.add(w);
  }
  out.sort((a, b) => a.type.compareTo(b.type));
  return out;
}

_Widget? _fromYaml(File f) {
  final YamlMap doc;
  try {
    final loaded = loadYaml(f.readAsStringSync());
    if (loaded is! YamlMap) return null;
    doc = loaded;
  } catch (_) {
    return null;
  }
  final type = doc['type'];
  if (type is! String || type.isEmpty) return null;

  final props = <_Prop>[];
  final raw = doc['properties'];
  if (raw is YamlMap) {
    raw.forEach((name, value) {
      if (value is! YamlMap) return;
      props.add(_Prop(
        '$name',
        _typeOf(value['type']),
        value['required'] == true,
        _stringList(value['enum']),
        value['default'] == null
            ? null
            : '${value['default']}'.replaceAll('"', ''),
        _stringList(value['aliases']),
      ));
    });
  }
  props.sort((a, b) => a.name.compareTo(b.name));

  return _Widget(
    type: type,
    aliases: _stringList(doc['aliases']),
    category: doc['category'] is String ? doc['category'] as String : null,
    profile: doc['profile'] is String ? doc['profile'] as String : null,
    description: '${doc['description'] ?? ''}',
    properties: props,
  );
}

String _typeOf(Object? type) {
  if (type is String) return type;
  if (type is YamlList) return type.map((t) => '$t').join('|');
  if (type is List) return type.map((t) => '$t').join('|');
  return 'any';
}

List<String> _stringList(Object? value) {
  if (value is YamlList) return value.map((v) => '$v').toList();
  if (value is List) return value.map((v) => '$v').toList();
  if (value is String) return [value];
  return const [];
}

/// Collapse a yaml block scalar into one line — a knowledge document is read
/// by a retrieval surface, not rendered as markdown.
String _oneLine(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim();

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
