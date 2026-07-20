/// Instance-profile resolution — the config-root-name / port-band derivations
/// and slot claiming behind `--instance` / auto-assign (`studio_main.dart`).
///
/// NOTE: the auto-INCREMENT-when-a-slot-is-taken path is a MULTI-PROCESS
/// behaviour — POSIX fcntl advisory locks do not conflict WITHIN one process,
/// so a single test process cannot simulate "another instance holds slot 1".
/// That path is covered by the live multi-instance run (three concurrent
/// processes → 1/2/3, then slot-1 reclaim). These unit tests cover the pure
/// derivations (the bug-prone stride) plus the single-process claim basics.
///
///   i1  instanceConfigRootName — 1 = bare base; N > 1 = `<base>-N`
///   i2  instancePortOffset — 1 = 0; band stride 100 (not 1 → avoids the
///       per-domain-server sweep collision)
///   i3  claimInstanceSlot honours an explicit instance number
///   i4  claimInstanceSlot auto-picks slot 1 in a fresh dir + creates its lock
library;

import 'dart:io';

import 'package:appplayer_studio/src/base/main/studio_main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('i1 instanceConfigRootName: 1 = base, N>1 = <base>-N', () {
    expect(StudioMain.instanceConfigRootName('vibe_studio', 1), 'vibe_studio');
    expect(
      StudioMain.instanceConfigRootName('vibe_studio', 2),
      'vibe_studio-2',
    );
    expect(
      StudioMain.instanceConfigRootName('vibe_studio', 3),
      'vibe_studio-3',
    );
    // 0 / negatives collapse to instance 1 (bare base).
    expect(StudioMain.instanceConfigRootName('x', 0), 'x');
  });

  test('i2 instancePortOffset: 1 = 0, band stride = 100', () {
    expect(StudioMain.instancePortOffset(1), 0);
    expect(StudioMain.instancePortOffset(2), 100);
    expect(StudioMain.instancePortOffset(3), 200);
    expect(StudioMain.kInstancePortStride, 100);
    // Stride regression guard: a +1 step would put instance 2's main port on
    // top of instance 1's first domain server (defaultPort + 1).
    expect(StudioMain.instancePortOffset(2), greaterThan(1));
  });

  group('claimInstanceSlot', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('inst_slot_'));
    tearDown(() => tmp.existsSync() ? tmp.deleteSync(recursive: true) : null);

    test('i3 honours an explicit instance number', () {
      final lockDir = Directory(p.join(tmp.path, 'x.locks'));
      final r = StudioMain.claimInstanceSlot(lockDir, 4);
      expect(r.instance, 4);
      r.lock?.closeSync();
    });

    test('i4 auto-picks slot 1 in a fresh dir + creates its lock file', () {
      final lockDir = Directory(p.join(tmp.path, 'x.locks'));
      final r = StudioMain.claimInstanceSlot(lockDir, null);
      expect(r.instance, 1);
      expect(r.lock, isNotNull);
      expect(
        File(p.join(lockDir.path, 'instance-1.lock')).existsSync(),
        isTrue,
      );
      r.lock?.closeSync();
    });
  });
}
