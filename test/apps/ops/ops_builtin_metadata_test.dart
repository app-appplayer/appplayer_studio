/// `OpsBuiltInApp` metadata sanity — Ops built-in (workspace
/// operations: members / tasks / processes / knowledge / bundles).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/apps.dart';

void main() {
  group('OpsBuiltInApp metadata', () {
    const app = OpsBuiltInApp();

    test('id is "makemind_ops"', () {
      // The built-in id is `makemind_ops` (used as the workspace key
      // and tabKey). The user-visible label is just "Ops".
      expect(app.id, 'makemind_ops');
    });

    test('label is "Ops"', () {
      expect(app.label, 'Ops');
    });

    test('id / label non-empty', () {
      expect(app.id, isNotEmpty);
      expect(app.label, isNotEmpty);
    });
  });
}
