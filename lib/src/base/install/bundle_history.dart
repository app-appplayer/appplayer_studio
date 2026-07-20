/// Bundle mutation-history location — OUTSIDE the bundle.
///
/// Mutator snapshots used to live at `<mbd>/.history/<ts>-<label>/`,
/// i.e. INSIDE the artifact directory. That placement was the design
/// fault behind a live defect (2026-07-13): authoring snapshots are
/// project workspace state, not bundle content, but every consumer of
/// the directory tree (canonical packer, uploads, loose-matching
/// resource resolvers) saw them as part of the bundle — a marketplace
/// serving shell ended up serving a STALE `.history` page copy over the
/// live one.
///
/// Snapshots now live in a SIBLING directory next to the bundle:
///
///   `<parent>/.history-<bundleDirName>/<ts>-<label>/`
///
/// which keeps them local to the bundle they belong to (works for
/// project channels and installed bundles alike) while guaranteeing the
/// artifact directory contains bundle content only. Readers fall back
/// to the legacy in-bundle location so old snapshots stay restorable.
library;

import 'package:path/path.dart' as p;

/// Sibling history root for the bundle at [mbdPath].
String bundleHistoryRootFor(String mbdPath) {
  final norm = p.normalize(mbdPath);
  return p.join(p.dirname(norm), '.history-${p.basename(norm)}');
}

/// Legacy (pre-2026-07-13) in-bundle history root — read-only fallback.
String legacyBundleHistoryRootFor(String mbdPath) =>
    p.join(p.normalize(mbdPath), '.history');
