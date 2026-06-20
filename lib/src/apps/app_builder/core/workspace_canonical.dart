/// App Builder uses the platform's single canonical engine — the
/// kernel-backed [WorkspaceCanonicalImpl] (open / commit / draft autosave /
/// dirty tracking / undo-redo, all over the host's `mk.Canonical`). The
/// former App-Builder fork (a parallel in-memory impl plus a
/// `KernelCanonicalAdapter`) is gone; this re-exports the platform engine.
export 'package:appplayer_studio/base.dart'
    show WorkspaceCanonical, WorkspaceCanonicalImpl, UndoState;
