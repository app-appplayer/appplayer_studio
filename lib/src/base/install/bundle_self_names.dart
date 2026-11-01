// VENDORED COPY — do not hand-edit. Canonical source:
//   os/core/brain_kernel/recipes/builder_mutator/lib/bundle_self_names.dart
// Regenerate with debug/tool/sync_builder_mutator_fork.sh.
//
/// Finds tool names in a bundle's own documents that carry the bundle's
/// id (platform spec 02 · 04-ui-host "Name isolation").
///
/// A bundle names its own tools by their declared names; the host adds the
/// id when it registers them, and the id can differ per host and per
/// activation. `<id>.<name>` is a host-side name, so it never belongs in the
/// manifest, a screen, js or wiring. Only a reference whose remainder is a
/// tool this bundle declares is reported — a host tool that happens to share
/// the prefix (a built-in's `form_builder.*`) is not the bundle's own.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One reference to fix: where it is, the name written, the declared name
/// to write instead.
class SelfNamedToolReference {
  const SelfNamedToolReference({
    required this.file,
    required this.written,
    required this.declared,
  });

  /// Bundle-relative file path.
  final String file;

  /// The id-prefixed name found.
  final String written;

  /// The declared name to use instead.
  final String declared;

  @override
  String toString() =>
      '$file: "$written" carries this bundle\'s id — write "$declared" '
      '(the host adds the id)';
}

/// Every id-prefixed reference to the bundle's own tools in the bundle at
/// [bundleDir]: declared tool names, `tool` values in the manifest (wiring,
/// chat) and in `ui/**.json`, agent `tools` allowlists and
/// `host.mcp.callTool('…')` in `tools/**.js`. Empty when the bundle has no
/// readable manifest.
List<SelfNamedToolReference> selfNamedToolReferences(String bundleDir) {
  final Map<String, dynamic> manifest;
  try {
    final raw = jsonDecode(
      File(p.join(bundleDir, 'manifest.json')).readAsStringSync(),
    );
    if (raw is! Map<String, dynamic>) return const [];
    manifest = raw;
  } on Object {
    return const [];
  }
  final meta = manifest['manifest'];
  final id = meta is Map ? meta['id'] : null;
  if (id is! String || id.isEmpty) return const [];
  final prefixes = <String>{'$id.', '${id.split('.').last}.'};

  final toolsSection = manifest['tools'];
  final toolList = toolsSection is Map ? toolsSection['tools'] : toolsSection;
  final names = <String>[
    if (toolList is List)
      for (final t in toolList)
        if (t is Map && t['name'] is String) t['name'] as String,
  ];

  // A declared name that itself starts with the id: its bare form is what
  // the bundle should declare and call.
  String? stripped(String name) {
    for (final prefix in prefixes) {
      if (name.startsWith(prefix) && name.length > prefix.length) {
        return name.substring(prefix.length);
      }
    }
    return null;
  }

  final out = <SelfNamedToolReference>[];
  final declared = <String>{};
  for (final name in names) {
    final bare = stripped(name);
    if (bare != null) {
      out.add(
        SelfNamedToolReference(
          file: 'manifest.json',
          written: name,
          declared: bare,
        ),
      );
      declared.add(bare);
    }
    declared.add(name);
  }

  // A reference names this bundle when stripping the prefix leaves one of
  // its declared tools (or a trailing-star pattern over them).
  String? ownBare(String name) {
    final bare = stripped(name);
    if (bare == null) return null;
    if (declared.contains(bare)) return bare;
    if (bare.endsWith('*')) {
      final head = bare.substring(0, bare.length - 1);
      if (declared.any((d) => d.startsWith(head))) return bare;
    }
    return null;
  }

  void check(String file, String name) {
    final bare = ownBare(name);
    if (bare != null) {
      out.add(
        SelfNamedToolReference(file: file, written: name, declared: bare),
      );
    }
  }

  void walkTools(String file, Object? node) {
    if (node is Map) {
      final tool = node['tool'];
      if (tool is String) check(file, tool);
      for (final v in node.values) {
        walkTools(file, v);
      }
    } else if (node is List) {
      for (final v in node) {
        walkTools(file, v);
      }
    }
  }

  walkTools('manifest.json', manifest['wiring']);
  walkTools('manifest.json', manifest['chat']);
  final agentsSection = manifest['agents'];
  final agents = agentsSection is Map ? agentsSection['agents'] : agentsSection;
  if (agents is List) {
    for (final a in agents) {
      final allow = a is Map ? a['tools'] : null;
      if (allow is List) {
        for (final t in allow) {
          if (t is String) check('manifest.json', t);
        }
      }
    }
  }

  final callTool = RegExp(r'''callTool\(\s*['"]([^'"]+)['"]''');
  for (final folder in const <String>['ui', 'tools']) {
    final dir = Directory(p.join(bundleDir, folder));
    if (!dir.existsSync()) continue;
    final files = dir.listSync(recursive: true).whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final rel = p.relative(f.path, from: bundleDir);
      if (p.split(rel).any((seg) => seg.startsWith('.'))) continue;
      final String text;
      try {
        text = f.readAsStringSync();
      } on Object {
        continue;
      }
      if (f.path.endsWith('.json')) {
        try {
          walkTools(rel, jsonDecode(text));
        } on FormatException {
          // A malformed file is reported by validation, not here.
        }
      } else if (f.path.endsWith('.js') || f.path.endsWith('.ts')) {
        for (final m in callTool.allMatches(text)) {
          check(rel, m.group(1)!);
        }
      }
    }
  }
  return out;
}
