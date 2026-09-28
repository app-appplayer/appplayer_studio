/// Reads the vbu atom self-descriptions — one `<name>.yaml` beside each
/// atom's dart body — and turns each into a [WidgetSpec] with
/// `source = custom`, so the builder catalogue (and the LLM authoring
/// surface behind it) can see the studio's own widgets.
///
/// Loaded from the ASSET bundle. The previous filesystem walk looked for
/// `tools/builder/vibe_studio_ui/dart/lib/src/atoms`, a path that stopped
/// existing when that package was collapsed into the studio — so the loader
/// returned an empty list, `catalog.list(source: "custom")` showed nothing,
/// and `studio.builder.ui.addNode` rejected every `Vbu*` type as unknown.
/// Assets also close what the old header called out as a follow-up: a
/// filesystem path cannot work in a packaged build at all.
///
/// The asset key is `lib/src/ui/atoms/<name>.yaml` when this package IS the
/// app and `packages/appplayer_studio/lib/src/ui/atoms/<name>.yaml` when it
/// is a dependency (the Pro tier), so the directory is matched as a suffix.
library;

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:yaml/yaml.dart';

import 'widget_spec.dart';

class VbuAtomSpecLoader {
  VbuAtomSpecLoader({AssetBundleReader? reader})
    : _read = reader ?? const _RootBundleReader();

  /// Asset directory the specs live under, matched as a suffix so one code
  /// path serves both "this package is the app" and "this package is a
  /// dependency".
  static const _atomsDirSuffix = 'lib/src/ui/atoms/';

  final AssetBundleReader _read;
  List<WidgetSpec>? _cache;

  /// Every custom (vbu atom) widget spec. Empty only when the assets are
  /// genuinely absent, which is a packaging fault rather than a normal state.
  Future<List<WidgetSpec>> load() async {
    if (_cache != null) return _cache!;
    final out = <WidgetSpec>[];
    for (final key in await _atomKeys()) {
      try {
        final spec = _parseCustomYaml(loadYaml(await _read.loadString(key)));
        if (spec != null) out.add(spec);
      } catch (_) {
        // One malformed yaml must not empty the whole catalogue.
      }
    }
    _cache = List<WidgetSpec>.unmodifiable(out);
    return _cache!;
  }

  Future<List<String>> _atomKeys() async {
    try {
      // `AssetManifest.json` was removed from the engine bundle; the typed
      // manifest is the supported way to enumerate assets, and reading the
      // old path is what made this return nothing.
      final keys = await _read.listKeys();
      return <String>[
        for (final k in keys)
          if (k.contains(_atomsDirSuffix) && k.endsWith('.yaml')) k,
      ]..sort();
    } catch (_) {
      return const <String>[];
    }
  }

  /// Asset keys the loader resolved. Empty means the specs were not
  /// packaged — the failure mode that made every `Vbu*` type unknown.
  Future<List<String>> resolvedAssetKeys() => _atomKeys();

  /// Mirror of [DslSpecLoader.get] — canonical names first, then the
  /// spellings a spec declares for itself.
  Future<WidgetSpec?> get(String type) async {
    final all = await load();
    for (final s in all) {
      if (s.type == type) return s;
    }
    for (final s in all) {
      if (s.aliases.contains(type)) return s;
    }
    return null;
  }

  static WidgetSpec? _parseCustomYaml(dynamic yaml) {
    if (yaml is! Map) return null;
    final type = yaml['type'];
    if (type is! String) return null;
    final category = (yaml['category'] as String?) ?? 'uncategorized';
    final description = (yaml['description'] as String?) ?? '';
    final profile = yaml['profile'] as String?;
    final since = yaml['since'] as String?;
    final rawWidgetAliases = yaml['aliases'];

    final props = <WidgetPropSpec>[];
    final rawProps = yaml['properties'];
    if (rawProps is Map) {
      rawProps.forEach((k, v) {
        if (k is! String || v is! Map) return;
        final propType = _typeString(v['type']);
        final propDesc = (v['description'] as String?) ?? '';
        final isRequired =
            propDesc.startsWith('required |') ||
            propDesc.startsWith('required|') ||
            v['required'] == true;
        final rawEnum = v['enum'];
        final enumValues =
            rawEnum is List
                ? List<String>.unmodifiable(
                  rawEnum.whereType<String>().toList(),
                )
                : const <String>[];
        props.add(
          WidgetPropSpec(
            key: k,
            type: propType,
            description: propDesc,
            defaultValue: v['default'],
            required: isRequired,
            enumValues: enumValues,
          ),
        );
      });
    }

    final examples = <WidgetExampleSpec>[];
    final rawEx = yaml['examples'];
    if (rawEx is List) {
      for (final e in rawEx) {
        if (e is! Map) continue;
        final name = (e['name'] as String?) ?? 'example';
        final dsl = (e['dsl'] as String?) ?? '';
        if (dsl.isEmpty) continue;
        examples.add(WidgetExampleSpec(name: name, dsl: dsl));
      }
    }

    return WidgetSpec(
      type: type,
      category: category,
      source: WidgetSource.custom,
      description: description,
      profile: profile,
      since: since,
      aliases:
          rawWidgetAliases is List
              ? List<String>.unmodifiable(rawWidgetAliases.whereType<String>())
              : const <String>[],
      properties: props,
      examples: examples,
    );
  }

  /// Mirror of DslSpecLoader's helper — list-valued `type` fields
  /// flatten to `"a | b"` so union-typed props still surface in
  /// the catalogue without crashing the loader.
  static String _typeString(Object? raw) {
    if (raw is String) return raw.trim();
    if (raw is List) {
      final strs = raw.whereType<String>().map((s) => s.trim()).toList();
      if (strs.isNotEmpty) return strs.join(' | ');
    }
    return 'unknown';
  }
}

/// Seam over the asset bundle: lets a test supply specs without a Flutter
/// binding, and makes a broken asset path observable instead of silent.
abstract interface class AssetBundleReader {
  /// Every asset key the bundle exposes.
  Future<List<String>> listKeys();
  Future<String> loadString(String key);
}

class _RootBundleReader implements AssetBundleReader {
  const _RootBundleReader();

  @override
  Future<List<String>> listKeys() async =>
      (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets();

  @override
  Future<String> loadString(String key) => rootBundle.loadString(key);
}
