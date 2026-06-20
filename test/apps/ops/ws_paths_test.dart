/// Unit tests for `ws_paths.dart` — workspace content-root derivation.
///
/// Boot-independent: pure string manipulation.
///
/// Scenarios:
///   wp1  normal workspace id produces <wsId>.mbd slug
///   wp2  slash in wsId is replaced with underscore
///   wp3  '_system' workspace id returns '_system' slot (no .mbd suffix)
///   wp4  empty projectRoot returns empty string
///   wp5  multi-slash wsId — all slashes replaced
///   wp6  wsId with no slash — plain <wsId>.mbd
///   wp7  resulting path is projectRoot + '/' + slot
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/infra/ws_paths.dart';

void main() {
  group('wsContentRoot', () {
    // wp1
    test('wp1 normal wsId → <wsId>.mbd', () {
      final result = wsContentRoot('/projects/myops', 'org/sales');
      expect(result, '/projects/myops/org_sales.mbd');
    });

    // wp2
    test('wp2 slash in wsId is replaced by underscore', () {
      final result = wsContentRoot('/root', 'team/hr');
      expect(result, '/root/team_hr.mbd');
    });

    // wp3
    test('wp3 _system wsId returns _system slot without .mbd', () {
      final result = wsContentRoot('/projects/myops', '_system');
      expect(result, '/projects/myops/_system');
      expect(result, isNot(contains('.mbd')));
    });

    // wp4
    test('wp4 empty projectRoot returns empty string', () {
      expect(wsContentRoot('', 'org/sales'), '');
    });

    // wp5
    test('wp5 multi-slash wsId replaces all slashes', () {
      final result = wsContentRoot('/root', 'a/b/c');
      expect(result, '/root/a_b_c.mbd');
    });

    // wp6
    test('wp6 wsId without slash uses wsId directly as slug', () {
      final result = wsContentRoot('/root', 'myworkspace');
      expect(result, '/root/myworkspace.mbd');
    });

    // wp7
    test('wp7 result is projectRoot + slash + slot', () {
      const root = '/data/projects/proj1';
      const wsId = 'team/eng';
      final result = wsContentRoot(root, wsId);
      expect(result.startsWith(root + '/'), isTrue);
    });

    test('wp — systemWorkspaceSlot constant', () {
      expect(systemWorkspaceSlot, '_system');
    });
  });
}
