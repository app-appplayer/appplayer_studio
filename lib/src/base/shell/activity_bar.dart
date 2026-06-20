import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

import 'project_header.dart';

/// Thin vertical bar shown on the left edge when the chat / project
/// column is collapsed. Surfaces a panel-expand handle plus the icons
/// from `ProjectHeader` Row 1 (lifecycle) and Row 2 (undo / redo /
/// history + domain `trailing`) so the user can still drive the same
/// verbs without re-opening the panel.
///
/// **Wiring layer** — this widget owns the project-header data binding
/// (dirty / hasProject / canUndo / canRedo + named callbacks) and
/// composes [VbuActivityBar] for the actual rendering. The atom keeps
/// the visual side honest; this layer keeps the host/builder coupling
/// in one place.
class ActivityBar extends StatelessWidget {
  const ActivityBar({
    super.key,
    required this.onExpand,
    required this.onNew,
    required this.onOpen,
    required this.onSave,
    required this.onSaveAs,
    required this.onRevert,
    required this.onCloseProject,
    required this.onSettings,
    required this.onUndo,
    required this.onRedo,
    required this.onHistory,
    required this.dirty,
    required this.hasProject,
    required this.canUndo,
    required this.canRedo,
    this.trailing = const <HeaderAction>[],
  });

  final VoidCallback onExpand;

  final VoidCallback onNew;
  final VoidCallback onOpen;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;
  final VoidCallback onRevert;
  final VoidCallback onCloseProject;
  final VoidCallback onSettings;

  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onHistory;

  final bool dirty;
  final bool hasProject;
  final bool canUndo;
  final bool canRedo;

  /// Domain-defined trailing actions — same list passed to
  /// `ProjectHeader.trailing`. Rendered after the History icon.
  final List<HeaderAction> trailing;

  static const double width = 36.0;

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: const <String, dynamic>{
        'type': 'studio.chrome.activity_bar',
        'id': 'activity-bar',
        'label': 'activity bar',
      },
      child: VbuActivityBar(
        width: width,
        groups: <List<VbuActivityBarItem>>[
          // Title 1 — expand handle.
          <VbuActivityBarItem>[
            VbuActivityBarItem(
              tooltip: 'Show chat panel',
              icon: Icons.menu_outlined,
              onTap: onExpand,
            ),
          ],
          // Title 2 — lifecycle.
          <VbuActivityBarItem>[
            VbuActivityBarItem(
              tooltip: 'New project',
              icon: Icons.add_circle_outlined,
              onTap: onNew,
            ),
            VbuActivityBarItem(
              tooltip: 'Open project folder',
              icon: Icons.folder_open_outlined,
              onTap: onOpen,
            ),
            VbuActivityBarItem(
              tooltip: dirty ? 'Save' : 'Save (no changes)',
              icon: Icons.save_outlined,
              onTap: hasProject ? onSave : null,
              emphasised: dirty && hasProject,
            ),
            VbuActivityBarItem(
              tooltip: 'Save as…',
              icon: Icons.save_as_outlined,
              onTap: hasProject ? onSaveAs : null,
            ),
            VbuActivityBarItem(
              tooltip:
                  dirty
                      ? 'Revert (discard unsaved changes)'
                      : 'Revert (no changes)',
              icon: Icons.restore_outlined,
              onTap: hasProject ? onRevert : null,
            ),
            VbuActivityBarItem(
              tooltip:
                  hasProject
                      ? 'Close project (return to welcome)'
                      : 'No project open',
              icon: Icons.close_outlined,
              onTap: hasProject ? onCloseProject : null,
            ),
            VbuActivityBarItem(
              tooltip: 'Settings (MCP server, API key)',
              icon: Icons.settings_outlined,
              onTap: onSettings,
            ),
          ],
          // Title 3 — change history (undo / redo / history).
          <VbuActivityBarItem>[
            VbuActivityBarItem(
              tooltip: canUndo ? 'Undo last change' : 'Nothing to undo',
              icon: Icons.undo_outlined,
              onTap: hasProject && canUndo ? onUndo : null,
            ),
            VbuActivityBarItem(
              tooltip: canRedo ? 'Redo' : 'Nothing to redo',
              icon: Icons.redo_outlined,
              onTap: hasProject && canRedo ? onRedo : null,
            ),
            VbuActivityBarItem(
              tooltip: 'Change history (audit log)',
              icon: Icons.history_outlined,
              onTap: onHistory,
            ),
          ],
          // Title 4+ — trailing clusters. Emitted as their own groups so
          // the atom draws a visible divider between change-history and
          // domain icons (and between each `divider:true` boundary inside
          // trailing). Empty clusters are skipped so no stray divider.
          for (final cluster in _trailingClusters())
            if (cluster.isNotEmpty)
              <VbuActivityBarItem>[
                for (final action in cluster)
                  VbuActivityBarItem(
                    tooltip: action.tooltip,
                    icon: action.icon,
                    onTap: action.onTap,
                    emphasised: action.emphasised,
                  ),
              ],
        ],
      ),
    );
  }

  /// Split [trailing] into sub-clusters at every `divider:true`. The
  /// first cluster is always returned (possibly empty) so the caller
  /// can always read `.first`. Clusters are joined back to the
  /// history group + emitted as additional [VbuActivityBar] groups
  /// so the atom draws a divider between each.
  List<List<HeaderAction>> _trailingClusters() {
    final out = <List<HeaderAction>>[<HeaderAction>[]];
    for (final a in trailing) {
      if (a.divider && out.last.isNotEmpty) {
        out.add(<HeaderAction>[a]);
      } else {
        out.last.add(a);
      }
    }
    return out;
  }
}
