import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UiAtom', () {
    test('notify with no slot wired returns shown:false', () async {
      final atom = UiAtom(bridge: ChromeBridge());
      final result =
          await atom.dispatch('notify', ['hello']) as Map<String, dynamic>;
      expect(result['shown'], isFalse);
      expect(result['reason'], 'no host slot');
    });

    test('notify dispatches to the wired slot with severity', () async {
      String? captured;
      String? capturedSeverity;
      final bridge =
          ChromeBridge()
            ..notify = (m, {String? severity}) {
              captured = m;
              capturedSeverity = severity;
            };
      final atom = UiAtom(bridge: bridge);
      final result =
          await atom.dispatch('notify', ['hi', 'warning'])
              as Map<String, dynamic>;
      expect(result['shown'], isTrue);
      expect(captured, 'hi');
      expect(capturedSeverity, 'warning');
    });

    test('dialog with no slot returns dismissed:false', () async {
      final atom = UiAtom(bridge: ChromeBridge());
      final result =
          await atom.dispatch('dialog', ['T', 'B']) as Map<String, dynamic>;
      expect(result['dismissed'], isFalse);
      expect(result['reason'], 'no host slot');
    });

    test('dialog wired slot returns the user choice', () async {
      final bridge =
          ChromeBridge()
            ..dialog = ({required String title, required String body}) async {
              expect(title, 'T');
              expect(body, 'B');
              return true;
            };
      final atom = UiAtom(bridge: bridge);
      final result =
          await atom.dispatch('dialog', ['T', 'B']) as Map<String, dynamic>;
      expect(result['dismissed'], isTrue);
    });

    test('prompt with no slot returns choice:-1', () async {
      final atom = UiAtom(bridge: ChromeBridge());
      final result =
          await atom.dispatch('prompt', ['Q?']) as Map<String, dynamic>;
      expect(result['choice'], -1);
    });

    test('prompt wired slot forwards options + returns choice', () async {
      final bridge =
          ChromeBridge()
            ..prompt = ({
              required String question,
              List<String>? options,
            }) async {
              expect(question, 'Q?');
              expect(options, ['No', 'Yes', 'Maybe']);
              return 1;
            };
      final atom = UiAtom(bridge: bridge);
      final result =
          await atom.dispatch('prompt', [
                'Q?',
                ['No', 'Yes', 'Maybe'],
              ])
              as Map<String, dynamic>;
      expect(result['choice'], 1);
    });

    test('throws on unknown verb', () async {
      final atom = UiAtom(bridge: ChromeBridge());
      expect(() => atom.dispatch('madeup', const []), throwsArgumentError);
    });

    test('notify requires a String message', () async {
      final atom = UiAtom(bridge: ChromeBridge());
      expect(() => atom.dispatch('notify', [42]), throwsArgumentError);
    });
  });

  group('WorkspaceAtom', () {
    test('current returns null when provider returns null', () async {
      final atom = WorkspaceAtom(provider: () => null);
      expect(await atom.dispatch('current', const []), isNull);
    });

    test('save / undo / redo report no workspace cleanly', () async {
      final atom = WorkspaceAtom(provider: () => null);
      final save =
          await atom.dispatch('save', const []) as Map<String, dynamic>;
      expect(save['ok'], isFalse);
      expect(save['reason'], 'no workspace');
      final undo =
          await atom.dispatch('undo', const []) as Map<String, dynamic>;
      expect(undo['reason'], 'no workspace');
      final redo =
          await atom.dispatch('redo', const []) as Map<String, dynamic>;
      expect(redo['reason'], 'no workspace');
    });

    test(
      'current returns the snapshot when provider returns a workspace',
      () async {
        final ws = _StubWorkspace(
          path: '/tmp/foo.mbd',
          dirty: true,
          canUndoFlag: true,
        );
        final atom = WorkspaceAtom(provider: () => ws);
        final snap =
            await atom.dispatch('current', const []) as Map<String, dynamic>;
        expect(snap['path'], '/tmp/foo.mbd');
        expect(snap['isDirty'], isTrue);
        expect(snap['canUndo'], isTrue);
        expect(snap['canRedo'], isFalse);
      },
    );

    test('save delegates and reports ok', () async {
      var saved = false;
      final ws = _StubWorkspace()..onSave = () => saved = true;
      final atom = WorkspaceAtom(provider: () => ws);
      final result =
          await atom.dispatch('save', const []) as Map<String, dynamic>;
      expect(result['ok'], isTrue);
      expect(saved, isTrue);
    });

    test('undo / redo return the workspace bool result', () async {
      final ws = _StubWorkspace()..undoResult = true;
      final atom = WorkspaceAtom(provider: () => ws);
      final undo =
          await atom.dispatch('undo', const []) as Map<String, dynamic>;
      expect(undo['performed'], isTrue);
      ws.undoResult = false;
      final undo2 =
          await atom.dispatch('undo', const []) as Map<String, dynamic>;
      expect(undo2['performed'], isFalse);
    });

    test('throws on unknown verb', () async {
      final atom = WorkspaceAtom(provider: () => null);
      expect(() => atom.dispatch('madeup', const []), throwsArgumentError);
    });
  });
}

/// Minimal stand-in — implements just the surface WorkspaceAtom touches.
/// Avoids the real WorkspaceCanonical's disk + dependency footprint
/// (full integration is exercised at the host level, not the atom).
class _StubWorkspace implements WorkspaceCanonical {
  _StubWorkspace({
    this.path,
    this.dirty = false,
    this.canUndoFlag = false,
    this.canRedoFlag = false,
  });

  String? path;
  bool dirty;
  bool canUndoFlag;
  bool canRedoFlag;
  bool undoResult = true;
  bool redoResult = true;
  void Function()? onSave;

  @override
  String? get workspacePath => path;
  @override
  bool get isDirty => dirty;
  @override
  bool get hasRestoredDraft => false;
  @override
  bool get canUndo => canUndoFlag;
  @override
  bool get canRedo => canRedoFlag;

  @override
  Future<void> save() async {
    onSave?.call();
  }

  @override
  Future<bool> undo() async => undoResult;
  @override
  Future<bool> redo() async => redoResult;

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('stub: ${invocation.memberName}');
}
