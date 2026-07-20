/// [bundleHistoryRootFor] — mutation history must live OUTSIDE the
/// bundle artifact (sibling dir). In-bundle placement shipped authoring
/// snapshots inside packed bundles and got a stale page served live
/// (2026-07-13). Raw file access inside the artifact is design-banned.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/src/base/install/bundle_history.dart';

void main() {
  test('bh1: sibling root next to the bundle, never inside it', () {
    final root = bundleHistoryRootFor('/w/proj/bundles/app.mbd');
    expect(root, p.join('/w/proj/bundles', '.history-app.mbd'));
    expect(p.isWithin('/w/proj/bundles/app.mbd', root), isFalse,
        reason: 'history must not be inside the artifact');
  });

  test('bh2: trailing slash normalized', () {
    expect(
      bundleHistoryRootFor('/w/proj/bundles/app.mbd/'),
      p.join('/w/proj/bundles', '.history-app.mbd'),
    );
  });

  test('bh3: legacy root points inside (read-only fallback)', () {
    expect(
      legacyBundleHistoryRootFor('/w/proj/bundles/app.mbd'),
      p.join('/w/proj/bundles/app.mbd', '.history'),
    );
  });
}
