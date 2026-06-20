/// Combines [DslSpecLoader] (standard 1.3 widgets) with
/// [VbuAtomSpecLoader] (vbu_* atoms) so the `studio.builder.ui.catalog.*`
/// tools can serve a single unified list.
///
/// Two queries:
///
/// - [list] — filter by `category` / `source`, return a flat list of
///   specs (used for `catalog.list`).
/// - [schema] — look up one spec by `type` (used for `catalog.schema`;
///   the tool layer picks whether to drop the examples).
library;

import 'dsl_spec_loader.dart';
import 'vbu_atom_spec_loader.dart';
import 'widget_spec.dart';

class BuilderCatalogService {
  BuilderCatalogService({DslSpecLoader? dsl, VbuAtomSpecLoader? vbu})
    : _dsl = dsl ?? DslSpecLoader(),
      _vbu = vbu ?? VbuAtomSpecLoader();

  final DslSpecLoader _dsl;
  final VbuAtomSpecLoader _vbu;

  /// Flat list of widget specs. `source` filter accepts `standard` /
  /// `custom` / `all`; anything else (including null) means all.
  /// `category` filter is exact-match on [WidgetSpec.category].
  Future<List<WidgetSpec>> list({String? category, String? source}) async {
    final wantStd = source != 'custom';
    final wantCus = source != 'standard';
    final std = wantStd ? await _dsl.load() : const <WidgetSpec>[];
    final cus = wantCus ? await _vbu.load() : const <WidgetSpec>[];
    final all = <WidgetSpec>[...std, ...cus];
    if (category == null || category.isEmpty) return all;
    return all.where((s) => s.category == category).toList(growable: false);
  }

  /// Single spec by exact type. Searches standard first, then custom.
  /// Returns null when unknown.
  Future<WidgetSpec?> schema(String type) async {
    final fromStd = await _dsl.get(type);
    if (fromStd != null) return fromStd;
    return _vbu.get(type);
  }

  /// Path-discovery + loader diagnostics. Surfaces the resolved
  /// specs / workspace roots and any yaml the loader silently
  /// skipped (root-not-map / type-field-missing / parse-error).
  Future<Map<String, dynamic>> diag() async {
    // Touch both loaders so their root fields populate.
    await _dsl.load();
    await _vbu.load();
    return <String, dynamic>{
      'specsRoot': _dsl.specsRoot,
      'workspaceRoot': _vbu.workspaceRoot,
      'standardSkipped': _dsl.skipped,
    };
  }
}
