/// Read a scaffold template stored under a bundle's reserved `assets/`
/// folder (per mcp_bundle [BundleFolder] spec) and produce the
/// `{path, content}` entries `studio.project.create` consumes as
/// `initialFiles`. Walks every file under the template subdirectory and
/// applies `{{key}}` placeholder substitution from [vars].
///
/// Per spec, every studio-shipped scaffold lives under
/// `assets/templates/<variant>.<extension>/`. Domains call this helper
/// from their lifecycle tool (e.g. `studio_builder.newProject`) so
/// host shells never embed template plumbing themselves.
import 'package:mcp_bundle/mcp_bundle.dart';
import 'package:path/path.dart' as p;

/// Load every file under `<bundlePath>/assets/<assetSubpath>/`, apply
/// `{{key}}` substitution from [vars], and emit entries whose `path` is
/// rebased to [emitSubdir] (so the caller can drop the template into a
/// new project's bundle folder verbatim). Returns an empty list when the
/// directory doesn't exist — callers decide how strict to be.
Future<List<Map<String, dynamic>>> loadAssetTemplate({
  required String bundlePath,
  required String assetSubpath,
  required String emitSubdir,
  Map<String, String> vars = const <String, String>{},
}) async {
  final resources = BundleResources(
    bundleRoot: bundlePath,
    folder: BundleFolder.assets,
  );
  final all = await resources.list();
  final prefix = assetSubpath.endsWith('/') ? assetSubpath : '$assetSubpath/';
  final out = <Map<String, dynamic>>[];
  for (final rel in all) {
    if (!rel.startsWith(prefix)) continue;
    final inside = rel.substring(prefix.length);
    if (inside.isEmpty) continue;
    var content = await resources.read(rel);
    for (final entry in vars.entries) {
      content = content.replaceAll('{{${entry.key}}}', entry.value);
    }
    out.add(<String, dynamic>{
      'path': p.join(emitSubdir, inside),
      'content': content,
    });
  }
  return out;
}
