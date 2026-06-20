/// Studio key shortcut bindings — Cmd / Ctrl + Z (undo) and Cmd /
/// Ctrl + Shift + Z (redo). Host wraps its shell tree with the
/// returned [CallbackShortcuts] so the bindings survive focus changes
/// inside inner widgets.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Build the standard undo / redo shortcut map. Pass a [child] to wrap
/// inside [CallbackShortcuts] + [Focus] so shortcuts trigger regardless
/// of which descendant has keyboard focus.
Widget studioUndoRedoShortcuts({
  required VoidCallback onUndo,
  required VoidCallback onRedo,
  required Widget child,
  bool autofocus = true,
}) {
  final bindings = <ShortcutActivator, VoidCallback>{
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): onUndo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): onUndo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
        onRedo,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
        onRedo,
  };
  return CallbackShortcuts(
    bindings: bindings,
    child: Focus(autofocus: autofocus, child: child),
  );
}
