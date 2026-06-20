/// Listens to [dialogRequestProvider] and opens the matching dialog on
/// the next frame. Mounted under the booted ProviderScope so the dialog
/// callsite has access to the override container (= the same place
/// human-driven `showAgentDetailDialog` calls from member_page already
/// work).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/member/agent_detail_dialog.dart';
import 'ui_debug_bridge.dart';

class UiDialogListener extends ConsumerStatefulWidget {
  const UiDialogListener({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UiDialogListener> createState() => _UiDialogListenerState();
}

class _UiDialogListenerState extends ConsumerState<UiDialogListener> {
  int _lastTs = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen<DialogRequest?>(dialogRequestProvider, (prev, next) {
      if (next == null) return;
      if (next.ts == _lastTs) return; // already shown
      _lastTs = next.ts;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showAgentDetailDialog(
          context,
          ref,
          agentId: next.agentId,
          displayName: next.displayName,
        );
      });
    });
    return widget.child;
  }
}
