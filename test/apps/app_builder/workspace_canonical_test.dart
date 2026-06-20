/// Unit tests for `app_builder/core/workspace_canonical.dart`.
///
/// The file is a re-export shim; the real logic lives in
/// `base/canonical/workspace_canonical.dart` (WorkspaceCanonicalImpl).
///
/// Tests are split into two sections:
///
///   A — Pure-value tests that need no file I/O:
///       UndoState value class.
///
///   B — File-system-backed tests that exercise WorkspaceCanonicalImpl
///       through FileWorkspaceFsPort on a temp directory. These cover:
///         b1 open   — creates empty bundle, isDirty=false.
///         b2 applyAtomic  — mutates in-memory state, isDirty=true.
///         b3 undo / redo  — canUndo / canRedo flags + stack mechanics.
///         b4 undoStateChanges stream — emitted on transition.
///         b5 hash   — non-empty string, changes after applyAtomic.
///         b6 dirtyChanges stream — emitted on transition.
///         b7 currentJson — reflects in-memory state.
///         b8 committedHash — set after open, unchanged before save.
///         b9 seedUndoStacks — repopulates stacks.
///         b10 patchToJson / patchFromJson (via undoStackJson/seedUndoStacks).
///         b11 empty-ops no-op — applyAtomic with empty patch is a no-op.
///         b12 save clears dirty.
///         b13 revert clears dirty + stacks.
///
/// NOTE: WorkspaceCanonicalImpl.open() wires a kernel Canonical that
/// writes to disk. Tests run against an actual temp directory created in
/// Directory.systemTemp to remain self-contained and leave no trace.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show
        CanonicalPatch,
        LayerId,
        UndoState,
        WorkspaceCanonical,
        WorkspaceCanonicalImpl;
import 'package:appplayer_studio/builtin_api.dart'
    show PatchOp, UserOriginator, ValidationSeverity;
import 'package:appplayer_studio/src/base/infra/workspace_fs_port.dart'
    show FileWorkspaceFsPort;
import 'package:appplayer_studio/src/base/spec/spec_validator.dart'
    show SpecValidatorImpl;

// ── helpers ────────────────────────────────────────────────────────────

WorkspaceCanonicalImpl _makeImpl() => WorkspaceCanonicalImpl(
  fsPort: FileWorkspaceFsPort(),
  validator: SpecValidatorImpl(),
);

CanonicalPatch _addOp(String path, Object? value) => CanonicalPatch(
  layer: LayerId.pages,
  ops: <PatchOp>[PatchOp(op: 'add', path: path, value: value)],
  originator: const UserOriginator(),
);

CanonicalPatch _replaceOp(String path, Object? value) => CanonicalPatch(
  layer: LayerId.pages,
  ops: <PatchOp>[PatchOp(op: 'replace', path: path, value: value)],
  originator: const UserOriginator(),
);

// ══════════════════════════════════════════════════════════════════════
// A — Pure value tests
// ══════════════════════════════════════════════════════════════════════
void main() {
  group('A — UndoState value class', () {
    test('stores canUndo and canRedo', () {
      const s = UndoState(canUndo: true, canRedo: false);
      expect(s.canUndo, isTrue);
      expect(s.canRedo, isFalse);
    });

    test('both true', () {
      const s = UndoState(canUndo: true, canRedo: true);
      expect(s.canUndo, isTrue);
      expect(s.canRedo, isTrue);
    });

    test('both false', () {
      const s = UndoState(canUndo: false, canRedo: false);
      expect(s.canUndo, isFalse);
      expect(s.canRedo, isFalse);
    });

    test('WorkspaceCanonical is the interface type', () {
      // Just confirms the re-export chain is intact.
      expect(_makeImpl(), isA<WorkspaceCanonical>());
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // B — File-system-backed tests
  // ══════════════════════════════════════════════════════════════════
  group('B — WorkspaceCanonicalImpl (file-system)', () {
    late Directory tmpDir;
    late String mbdPath;
    late WorkspaceCanonicalImpl impl;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('ws_canon_test_');
      mbdPath = p.join(tmpDir.path, 'project.mbd');
      impl = _makeImpl();
    });

    tearDown(() async {
      try {
        await impl.dispose();
      } catch (_) {}
      if (tmpDir.existsSync()) {
        await tmpDir.delete(recursive: true);
      }
    });

    // ── b1 open ─────────────────────────────────────────────────────
    group('b1 open', () {
      test('succeeds on a fresh directory', () async {
        // expectLater + returnsNormally does not play well with sync
        // broadcast streams that fire during the call. Call directly and
        // verify the post-call state proves success.
        await impl.open(mbdPath);
        expect(impl.workspacePath, isNotNull);
      });

      test('workspacePath is set after open', () async {
        await impl.open(mbdPath);
        expect(impl.workspacePath, mbdPath);
      });

      test('isDirty is false after open', () async {
        await impl.open(mbdPath);
        expect(impl.isDirty, isFalse);
      });

      test('canUndo is false after open', () async {
        await impl.open(mbdPath);
        expect(impl.canUndo, isFalse);
      });

      test('canRedo is false after open', () async {
        await impl.open(mbdPath);
        expect(impl.canRedo, isFalse);
      });

      test('committedHash is set after open', () async {
        await impl.open(mbdPath);
        expect(impl.committedHash, isNotNull);
        expect(impl.committedHash, isNotEmpty);
      });

      test('currentJson has ui and manifest keys', () async {
        await impl.open(mbdPath);
        final json = impl.currentJson;
        expect(json.containsKey('manifest'), isTrue);
        // The empty-bundle seed includes a ui block.
        expect(json.containsKey('ui'), isTrue);
      });
    });

    // ── b2 applyAtomic ──────────────────────────────────────────────
    group('b2 applyAtomic', () {
      setUp(() async {
        await impl.open(mbdPath);
      });

      test('isDirty becomes true after applyAtomic', () async {
        await impl.applyAtomic(_addOp('/ui/myKey', 'myValue'));
        expect(impl.isDirty, isTrue);
      });

      test('currentJson reflects the mutation', () async {
        await impl.applyAtomic(_addOp('/ui/testField', 'hello'));
        expect(impl.currentJson['ui'], isA<Map>());
        final ui = impl.currentJson['ui'] as Map;
        expect(ui['testField'], 'hello');
      });

      test('replace op changes an existing value', () async {
        // The empty seed has ui.type = 'application'.
        await impl.applyAtomic(_replaceOp('/ui/type', 'replaced'));
        final ui = impl.currentJson['ui'] as Map;
        expect(ui['type'], 'replaced');
      });

      test('empty patch is a no-op (isDirty stays false)', () async {
        final noop = CanonicalPatch(
          layer: LayerId.pages,
          ops: const <PatchOp>[],
          originator: const UserOriginator(),
        );
        await impl.applyAtomic(noop);
        expect(impl.isDirty, isFalse);
      });

      test('throws StateError when called before open', () {
        final fresh = _makeImpl();
        expect(() => fresh.applyAtomic(_addOp('/ui/x', 1)), throwsStateError);
      });
    });

    // ── b3 undo / redo ──────────────────────────────────────────────
    group('b3 undo / redo', () {
      setUp(() async {
        await impl.open(mbdPath);
      });

      test('canUndo becomes true after applyAtomic', () async {
        await impl.applyAtomic(_addOp('/ui/a', 'v'));
        expect(impl.canUndo, isTrue);
      });

      test('undo returns true and restores previous state', () async {
        await impl.applyAtomic(_addOp('/ui/undoMe', 'before'));
        expect((impl.currentJson['ui'] as Map)['undoMe'], 'before');

        final ok = await impl.undo();
        expect(ok, isTrue);
        expect((impl.currentJson['ui'] as Map).containsKey('undoMe'), isFalse);
      });

      test('canUndo is false after full undo', () async {
        await impl.applyAtomic(_addOp('/ui/x', 'v'));
        await impl.undo();
        expect(impl.canUndo, isFalse);
      });

      test('undo on empty stack returns false', () async {
        final ok = await impl.undo();
        expect(ok, isFalse);
      });

      test('canRedo becomes true after undo', () async {
        await impl.applyAtomic(_addOp('/ui/r', 'v'));
        await impl.undo();
        expect(impl.canRedo, isTrue);
      });

      test('redo returns true and reapplies forward change', () async {
        await impl.applyAtomic(_addOp('/ui/redoMe', 'val'));
        await impl.undo();
        final ok = await impl.redo();
        expect(ok, isTrue);
        expect((impl.currentJson['ui'] as Map)['redoMe'], 'val');
      });

      test('redo on empty stack returns false', () async {
        final ok = await impl.redo();
        expect(ok, isFalse);
      });

      test('fresh edit after undo clears redo stack', () async {
        await impl.applyAtomic(_addOp('/ui/a', 'v'));
        await impl.undo();
        expect(impl.canRedo, isTrue);
        // New edit clears redo.
        await impl.applyAtomic(_addOp('/ui/b', 'v2'));
        expect(impl.canRedo, isFalse);
      });

      test('multiple undos walk back correctly', () async {
        await impl.applyAtomic(_addOp('/ui/step1', 'one'));
        await impl.applyAtomic(_addOp('/ui/step2', 'two'));
        await impl.undo();
        expect((impl.currentJson['ui'] as Map).containsKey('step2'), isFalse);
        await impl.undo();
        expect((impl.currentJson['ui'] as Map).containsKey('step1'), isFalse);
      });
    });

    // ── b4 undoStateChanges stream ─────────────────────────────────
    group('b4 undoStateChanges stream', () {
      test('emits UndoState on applyAtomic', () async {
        await impl.open(mbdPath);
        final states = <UndoState>[];
        final sub = impl.undoStateChanges.listen(states.add);
        await impl.applyAtomic(_addOp('/ui/x', 'y'));
        await sub.cancel();
        expect(states, isNotEmpty);
        expect(states.last.canUndo, isTrue);
      });
    });

    // ── b5 hash ─────────────────────────────────────────────────────
    group('b5 hash', () {
      test('hash returns non-empty string after open', () async {
        await impl.open(mbdPath);
        final h = await impl.hash();
        expect(h, isNotEmpty);
        expect(h, startsWith('sha256:'));
      });

      test('hash changes after applyAtomic', () async {
        await impl.open(mbdPath);
        final before = await impl.hash();
        await impl.applyAtomic(_addOp('/ui/changeMe', 'x'));
        final after = await impl.hash();
        expect(after, isNot(before));
      });

      test('hash throws StateError before open', () {
        final fresh = _makeImpl();
        expect(() => fresh.hash(), throwsStateError);
      });
    });

    // ── b6 dirtyChanges stream ─────────────────────────────────────
    group('b6 dirtyChanges stream', () {
      test('emits true when first applyAtomic is made', () async {
        await impl.open(mbdPath);
        final dirty = <bool>[];
        final sub = impl.dirtyChanges.listen(dirty.add);
        await impl.applyAtomic(_addOp('/ui/z', 'q'));
        await sub.cancel();
        expect(dirty, contains(true));
      });
    });

    // ── b7 currentJson ──────────────────────────────────────────────
    group('b7 currentJson', () {
      test('throws StateError before open', () {
        final fresh = _makeImpl();
        expect(() => fresh.currentJson, throwsStateError);
      });

      test('returns a Map after open', () async {
        await impl.open(mbdPath);
        expect(impl.currentJson, isA<Map<String, dynamic>>());
      });
    });

    // ── b8 committedHash ───────────────────────────────────────────
    group('b8 committedHash', () {
      test('null before open', () {
        final fresh = _makeImpl();
        expect(fresh.committedHash, isNull);
      });

      test('non-null after open', () async {
        await impl.open(mbdPath);
        expect(impl.committedHash, isNotNull);
        expect(impl.committedHash, startsWith('sha256:'));
      });

      test('unchanges after applyAtomic (not yet saved)', () async {
        await impl.open(mbdPath);
        final committed = impl.committedHash;
        await impl.applyAtomic(_addOp('/ui/c', 'v'));
        expect(impl.committedHash, committed);
      });
    });

    // ── b9 seedUndoStacks ──────────────────────────────────────────
    group('b9 seedUndoStacks', () {
      test('seeding with empty lists leaves canUndo/canRedo false', () async {
        await impl.open(mbdPath);
        impl.seedUndoStacks(undo: const [], redo: const []);
        expect(impl.canUndo, isFalse);
        expect(impl.canRedo, isFalse);
      });
    });

    // ── b10 undoStackJson round-trip ────────────────────────────────
    group('b10 undoStackJson / seedUndoStacks round-trip', () {
      test('undoStackJson is empty before any patch', () async {
        await impl.open(mbdPath);
        expect(impl.undoStackJson, isEmpty);
      });

      test('undoStackJson non-empty after applyAtomic', () async {
        await impl.open(mbdPath);
        await impl.applyAtomic(_addOp('/ui/rt', 'v'));
        expect(impl.undoStackJson, isNotEmpty);
      });

      test('seedUndoStacks restores canUndo from persisted stack', () async {
        // First: accumulate an undo entry, capture its JSON form,
        // then open a fresh impl and seed it.
        await impl.open(mbdPath);
        await impl.applyAtomic(_addOp('/ui/persistMe', 'data'));
        final stackJson = impl.undoStackJson;

        final impl2 = _makeImpl();
        addTearDown(() async {
          try {
            await impl2.dispose();
          } catch (_) {}
        });
        await impl2.open(mbdPath);
        impl2.seedUndoStacks(undo: stackJson, redo: const []);
        expect(impl2.canUndo, isTrue);
      });
    });

    // ── b11 empty-ops no-op ─────────────────────────────────────────
    group('b11 empty-ops no-op', () {
      test('empty patch leaves isDirty false and canUndo false', () async {
        await impl.open(mbdPath);
        final noop = CanonicalPatch(
          layer: LayerId.pages,
          ops: const <PatchOp>[],
          originator: const UserOriginator(),
        );
        await impl.applyAtomic(noop);
        expect(impl.isDirty, isFalse);
        expect(impl.canUndo, isFalse);
      });
    });

    // ── b12 save clears dirty ──────────────────────────────────────
    group('b12 save', () {
      test('save clears isDirty', () async {
        await impl.open(mbdPath);
        await impl.applyAtomic(_addOp('/ui/saveMe', 'v'));
        expect(impl.isDirty, isTrue);
        await impl.save();
        expect(impl.isDirty, isFalse);
      });

      test('save throws StateError before open', () {
        final fresh = _makeImpl();
        expect(() => fresh.save(), throwsStateError);
      });

      test('committedHash updated after save', () async {
        await impl.open(mbdPath);
        final commitBefore = impl.committedHash;
        await impl.applyAtomic(_addOp('/ui/k', 'v'));
        await impl.save();
        expect(impl.committedHash, isNot(commitBefore));
      });
    });

    // ── b13 revert ──────────────────────────────────────────────────
    group('b13 revert', () {
      test('revert clears isDirty', () async {
        await impl.open(mbdPath);
        await impl.applyAtomic(_addOp('/ui/rv', 'v'));
        expect(impl.isDirty, isTrue);
        await impl.revert();
        expect(impl.isDirty, isFalse);
      });

      test('revert clears undo stack', () async {
        await impl.open(mbdPath);
        await impl.applyAtomic(_addOp('/ui/rv2', 'v'));
        expect(impl.canUndo, isTrue);
        await impl.revert();
        expect(impl.canUndo, isFalse);
      });

      test('revert clears redo stack', () async {
        await impl.open(mbdPath);
        await impl.applyAtomic(_addOp('/ui/rv3', 'v'));
        await impl.undo();
        expect(impl.canRedo, isTrue);
        await impl.revert();
        expect(impl.canRedo, isFalse);
      });

      test('revert is a no-op when nothing is open', () async {
        final fresh = _makeImpl();
        // Must not throw.
        await expectLater(() => fresh.revert(), returnsNormally);
        await fresh.dispose();
      });
    });

    // ── hasRestoredDraft ───────────────────────────────────────────
    group('hasRestoredDraft', () {
      test('false on first open (no draft yet)', () async {
        await impl.open(mbdPath);
        expect(impl.hasRestoredDraft, isFalse);
      });
    });
  });
}
