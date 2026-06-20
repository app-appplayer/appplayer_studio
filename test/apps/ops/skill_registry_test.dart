/// AppSkillRegistry — unit tests for all pure in-memory paths.
///
/// Boot-independent: no I/O, no OpsBuiltInApp.
///
/// Scenarios:
///   sr1  register + get — happy path returns exact definition
///   sr2  register overwrites an existing id
///   sr3  get — returns null for unknown id
///   sr4  list — returns all registered definitions
///   sr5  list — empty when nothing registered
///   sr6  remove — removes registered definition; get returns null
///   sr7  remove — no-op for unknown id (no crash)
///   sr8  length — reflects current count
///   sr9  changes stream — fires on register (initial add)
///   sr10 changes stream — fires on register (overwrite)
///   sr11 changes stream — fires on remove when entry existed
///   sr12 changes stream — does NOT fire on remove for unknown id
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_definition.dart';
import 'package:appplayer_studio/src/apps/ops/skills/skill_registry.dart';

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

SkillDefinition _makeDef(String id, {int version = 1}) =>
    SkillDefinition.fromYaml({
      'id': id,
      'version': version,
      'actionBody': {'kind': 'noop'},
    });

void main() {
  group('AppSkillRegistry', () {
    late AppSkillRegistry reg;

    setUp(() => reg = AppSkillRegistry());

    // sr1
    test('sr1 register + get returns the registered definition', () {
      final def = _makeDef('greet');
      reg.register(def);
      expect(reg.get('greet'), same(def));
    });

    // sr2
    test('sr2 register overwrites existing id', () {
      final v1 = _makeDef('greet', version: 1);
      final v2 = _makeDef('greet', version: 2);
      reg.register(v1);
      reg.register(v2);
      expect(reg.get('greet'), same(v2));
    });

    // sr3
    test('sr3 get returns null for unknown id', () {
      expect(reg.get('does_not_exist'), isNull);
    });

    // sr4
    test('sr4 list returns all registered definitions', () {
      final a = _makeDef('alpha');
      final b = _makeDef('beta');
      reg.register(a);
      reg.register(b);
      final listed = reg.list();
      expect(listed, hasLength(2));
      expect(listed, containsAll([a, b]));
    });

    // sr5
    test('sr5 list is empty when nothing registered', () {
      expect(reg.list(), isEmpty);
    });

    // sr6
    test('sr6 remove deletes the entry; get returns null', () {
      reg.register(_makeDef('to_remove'));
      reg.remove('to_remove');
      expect(reg.get('to_remove'), isNull);
    });

    // sr7
    test('sr7 remove is a no-op for unknown id', () {
      expect(() => reg.remove('ghost'), returnsNormally);
    });

    // sr8
    test('sr8 length reflects current registration count', () {
      expect(reg.length, 0);
      reg.register(_makeDef('a'));
      expect(reg.length, 1);
      reg.register(_makeDef('b'));
      expect(reg.length, 2);
      reg.remove('a');
      expect(reg.length, 1);
    });

    // sr9
    test('sr9 changes stream fires on new register', () async {
      final events = <void>[];
      final sub = reg.changes.listen((_) => events.add(null));
      reg.register(_makeDef('x'));
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      await sub.cancel();
    });

    // sr10
    test('sr10 changes stream fires on overwrite register', () async {
      reg.register(_makeDef('x', version: 1));
      final events = <void>[];
      final sub = reg.changes.listen((_) => events.add(null));
      reg.register(_makeDef('x', version: 2)); // overwrite
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      await sub.cancel();
    });

    // sr11
    test('sr11 changes stream fires on remove when entry existed', () async {
      reg.register(_makeDef('removable'));
      final events = <void>[];
      final sub = reg.changes.listen((_) => events.add(null));
      reg.remove('removable');
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      await sub.cancel();
    });

    // sr12
    test('sr12 changes stream does not fire on remove of unknown id', () async {
      final events = <void>[];
      final sub = reg.changes.listen((_) => events.add(null));
      reg.remove('ghost');
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await sub.cancel();
    });
  });
}
