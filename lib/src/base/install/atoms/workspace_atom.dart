/// Workspace atom — `host.workspace.*`. Read + lifecycle access to
/// the active project canonical for the tab the activation lives in.
/// JS tools query state (`isDirty`, `canUndo`, `currentPath`) and
/// drive lifecycle ops (`save`, `undo`, `redo`).
///
/// The atom takes a *provider* — `WorkspaceCanonical Function()?` —
/// rather than a direct instance, because the active workspace can
/// change while the tab is open (the user closes / opens projects).
/// When the provider returns null, the atom reports "no workspace"
/// rather than throwing — JS sees a clean conditional path.
///
/// Mutating operations (`applyAtomic`) are intentionally NOT exposed;
/// canonical patches go through MCP tools (or future workspace
/// editing tools) so the patch + undo / redo discipline stays under
/// host control.
library;

import '../../canonical/workspace_canonical.dart';

import 'atom_category.dart';

class WorkspaceAtom extends AtomCategory {
  WorkspaceAtom({required this.provider});

  /// Provider — called fresh on every dispatch so the atom always
  /// sees the currently-active workspace (the host can swap projects
  /// without re-creating the atom).
  final WorkspaceCanonical? Function() provider;

  @override
  String get key => 'workspace';

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb(
      'current',
      description:
          'Snapshot of the active workspace — '
          '{path, isDirty, hasRestoredDraft, canUndo, canRedo} or null.',
    ),
    AtomVerb(
      'save',
      description:
          'Persist in-memory edits to disk. {ok: bool, '
          'reason?}.',
    ),
    AtomVerb(
      'undo',
      description:
          'Reverse the most recent canonical patch. '
          '{ok: bool, performed?}.',
    ),
    AtomVerb(
      'redo',
      description:
          'Re-apply the most recent undone patch. '
          '{ok: bool, performed?}.',
    ),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    final ws = provider();
    switch (verb) {
      case 'current':
        if (ws == null) return null;
        return <String, dynamic>{
          'path': ws.workspacePath,
          'isDirty': ws.isDirty,
          'hasRestoredDraft': ws.hasRestoredDraft,
          'canUndo': ws.canUndo,
          'canRedo': ws.canRedo,
        };
      case 'save':
        if (ws == null) {
          return <String, dynamic>{'ok': false, 'reason': 'no workspace'};
        }
        try {
          await ws.save();
          return <String, dynamic>{'ok': true};
        } catch (e) {
          return <String, dynamic>{'ok': false, 'reason': e.toString()};
        }
      case 'undo':
        if (ws == null) {
          return <String, dynamic>{'ok': false, 'reason': 'no workspace'};
        }
        final performed = await ws.undo();
        return <String, dynamic>{'ok': true, 'performed': performed};
      case 'redo':
        if (ws == null) {
          return <String, dynamic>{'ok': false, 'reason': 'no workspace'};
        }
        final performed = await ws.redo();
        return <String, dynamic>{'ok': true, 'performed': performed};
      default:
        throw ArgumentError('unknown verb: workspace.$verb');
    }
  }
}
