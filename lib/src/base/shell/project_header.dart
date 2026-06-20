import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'tokens.dart';

/// One domain-defined action button rendered on the right side of
/// [ProjectHeader] Row 2. Hosts pass a list (left-to-right in
/// declaration order) via [ProjectHeader.trailing]. Use this slot for
/// builder-specific verbs (Build / Compare channels / Manage assets in
/// vibe_app_builder · Diff / Search / Export in vibe_knowledge_builder)
/// — base never hard-codes domain icons.
/// Wrap [child] in a `MetaData({type:"tool", id})` node so the
/// overlay layer's element resolver can find the affordance by id.
/// Returns [child] unchanged when [elementId] is null so the wrap
/// stays free for affordances that don't need scene targeting.
Widget _wrapWithElementMeta({
  required String? elementId,
  required Widget child,
}) {
  if (elementId == null || elementId.isEmpty) return child;
  return MetaData(
    metaData: <String, dynamic>{'type': 'tool', 'id': elementId},
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}

class HeaderAction {
  const HeaderAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.emphasised = false,
    this.divider = false,
    this.elementId,
  });

  /// Stable identifier the overlay layer's element resolver looks up
  /// when an overlay declares `target:{element:"tool:<id>"}`. Domain
  /// readers (e.g. `domain_actions_reader`) populate this from the
  /// manifest's per-action `tool` short name so scene scripts can
  /// point at a specific affordance without absolute coordinates.
  /// Wrapped in `MetaData({type:"tool", id})` at render time.
  final String? elementId;

  /// Hover tooltip text. Required so domain affordances are always
  /// discoverable from a hover even when the icon is unfamiliar.
  final String tooltip;

  /// Material icon — domain picks any icon that isn't already used by
  /// the standard left side (Undo / Redo / History).
  final IconData icon;

  /// Tap handler. `null` disables the button (standard hover/tap is
  /// suppressed and the icon dims to `textTertiary`). Domain hosts use
  /// `null` to signal "this verb isn't applicable right now" without
  /// having to remove the slot — keeps the row layout stable.
  final VoidCallback? onTap;

  /// Highlights the icon (mint tone) when the verb is the
  /// recommended next action. Mirrors the same flag base uses on Save
  /// when the project is dirty.
  final bool emphasised;

  /// When true, the renderer draws a small vertical separator + gap
  /// BEFORE this action — groups subsequent actions into a visually
  /// distinct cluster. Hosts use this to mark the boundary between
  /// system-level icons (Import / Export / mode tabs) and bundle-
  /// declared wiring (domain actions, settings, slash triggers).
  /// Set on the FIRST action of each new cluster.
  final bool divider;
}

/// Strip mounted on top of [ChatPanel]. Shows the current project name,
/// a dirty indicator when there are unsaved edits, and a tooltipped row
/// of project actions:
///
///   * Row 0 — project name + dirty bullet + rename
///   * Row 1 — New / Open / Recent / Save / Save As / Revert / Close
///     (left) · Settings (right)
///   * Row 2 — Undo / Redo / History (left) · domain-defined `trailing`
///     actions (right)
///
/// Row 0 / 1 and the left half of Row 2 are universal lifecycle and
/// edit affordances — every builder needs them, base wires them. The
/// right side of Row 2 is intentionally a [trailing] slot so each
/// host (vibe_app_builder / vibe_knowledge_builder / future studios)
/// supplies its own verbs without forking the chrome.
///
/// Delete is intentionally absent — the builder never destroys the
/// user's project on disk.
class ProjectHeader extends StatelessWidget {
  const ProjectHeader({
    super.key,
    required this.projectName,
    required this.dirty,
    required this.canUndo,
    required this.canRedo,
    this.onNew,
    required this.onOpen,
    required this.onOpenRecent,
    required this.onSave,
    required this.onSaveAs,
    required this.onRevert,
    required this.onUndo,
    required this.onRedo,
    required this.onRename,
    required this.onCloseProject,
    required this.onHistory,
    required this.onSettings,
    this.trailing = const <HeaderAction>[],
    this.recentProjects = const <String>[],
    this.hasProject = true,
    this.leftPanelVisible,
    this.onToggleLeftPanel,
    this.newTooltip = 'New project',
    this.openTooltip = 'Open project folder',
  });

  /// Tooltip override for the New button. Hosts that want Home-tab
  /// "New package" semantics swap this in via the chrome bridge.
  final String newTooltip;

  /// Tooltip override for the Open button. Same pattern as
  /// [newTooltip] — Home tab swaps to "Open package".
  final String openTooltip;

  /// Optional left-panel collapse state. Non-null pairs (visible flag +
  /// callback) render a `panel_left_close` / `panel_left_open` icon on
  /// the right edge of the project-name row (Row 0). Null hides the
  /// affordance — useful for shells that manage panel state elsewhere.
  final bool? leftPanelVisible;
  final VoidCallback? onToggleLeftPanel;

  final String projectName;

  /// True when there are in-memory edits not yet written to disk — drives
  /// the bullet in front of the project name and enables the Save button.
  final bool dirty;

  /// False when no project is open — disables the project-scoped
  /// buttons (Save / Save As / Revert / Import / Export) so the user
  /// is steered to New / Open first.
  final bool hasProject;

  /// Drives the Undo button's enabled / disabled state.
  final bool canUndo;

  /// Drives the Redo button's enabled / disabled state.
  final bool canRedo;

  /// Most-recently-opened project paths in MRU order. Drives the
  /// chevron menu next to Open. Empty list → chevron is hidden.
  final List<String> recentProjects;

  final VoidCallback? onNew;
  final VoidCallback onOpen;

  /// Invoked when the user picks an entry from the Recent Projects menu.
  final ValueChanged<String> onOpenRecent;

  final VoidCallback onSave;
  final VoidCallback onSaveAs;
  final VoidCallback onRevert;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onRename;

  /// Drops the open project and returns the shell to the welcome state.
  /// Disabled when no project is open.
  final VoidCallback onCloseProject;

  /// Open the change-history (audit log) dialog.
  final VoidCallback onHistory;
  final VoidCallback onSettings;

  /// Domain-defined right-side actions for Row 2. Each [HeaderAction]
  /// renders as a tooltipped icon button after the [Spacer] in the
  /// undo/redo/history row. Base does not interpret the list — it
  /// just renders. See [HeaderAction] for tap / disabled / emphasised
  /// semantics.
  final List<HeaderAction> trailing;

  static const double _height = 96.0;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return MetaData(
      metaData: <String, dynamic>{
        'type': 'studio.chrome.project_header',
        'id': 'project-header',
        'label': projectName,
      },
      child: Container(
        key: const Key('vibe.project.header'),
        height: _height,
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(bottom: BorderSide(color: c.borderDefault)),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space3,
          vertical: VibeTokens.space2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            // Project name (mono, ellipsised). A leading bullet flags
            // unsaved edits so the user always knows save state at a glance.
            // Clicking the row opens the rename dialog when a project is open.
            // Optional collapse-toggle pinned to the row's right edge so
            // every shell that opts in gets a consistent panel handle.
            SizedBox(
              height: 18,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: _ProjectNameRow(
                      projectName: projectName,
                      dirty: dirty,
                      hasProject: hasProject,
                      onRename: onRename,
                    ),
                  ),
                  if (leftPanelVisible != null && onToggleLeftPanel != null)
                    _IconButton(
                      tooltip:
                          leftPanelVisible!
                              ? 'Hide chat panel'
                              : 'Show chat panel',
                      icon:
                          leftPanelVisible!
                              ? Icons.menu_open
                              : Icons.menu_outlined,
                      onTap: onToggleLeftPanel,
                    ),
                ],
              ),
            ),
            // Row 1 — project lifecycle (left) + Settings pinned right.
            Row(
              children: <Widget>[
                _IconButton(
                  tooltip: newTooltip,
                  icon: Icons.add_circle_outlined,
                  onTap: onNew,
                ),
                _IconButton(
                  tooltip: openTooltip,
                  icon: Icons.folder_open_outlined,
                  onTap: onOpen,
                ),
                if (recentProjects.isNotEmpty)
                  _RecentMenuButton(
                    recents: recentProjects,
                    onPick: onOpenRecent,
                  ),
                _IconButton(
                  tooltip: dirty ? 'Save' : 'Save (no changes)',
                  icon: Icons.save_outlined,
                  onTap: hasProject ? onSave : null,
                  emphasised: dirty && hasProject,
                ),
                _IconButton(
                  tooltip: 'Save as…',
                  icon: Icons.save_as_outlined,
                  onTap: hasProject ? onSaveAs : null,
                ),
                _IconButton(
                  tooltip:
                      dirty
                          ? 'Revert (discard unsaved changes)'
                          : 'Revert (no changes)',
                  icon: Icons.restore_outlined,
                  onTap: hasProject ? onRevert : null,
                ),
                _IconButton(
                  tooltip:
                      hasProject
                          ? 'Close project (return to welcome)'
                          : 'No project open',
                  icon: Icons.close_outlined,
                  onTap: hasProject ? onCloseProject : null,
                ),
                const Spacer(),
                _IconButton(
                  tooltip: 'Settings',
                  icon: Icons.settings_outlined,
                  onTap: onSettings,
                ),
              ],
            ),
            // Row 2 — Undo / Redo / History (left, base-managed standard
            // edit affordances) · domain `trailing` actions (right). Base
            // never hard-codes domain icons — every builder studio passes
            // its own verbs through the [trailing] slot.
            Row(
              children: <Widget>[
                _IconButton(
                  tooltip: canUndo ? 'Undo last change' : 'Nothing to undo',
                  icon: Icons.undo_outlined,
                  onTap: hasProject && canUndo ? onUndo : null,
                ),
                _IconButton(
                  tooltip: canRedo ? 'Redo' : 'Nothing to redo',
                  icon: Icons.redo_outlined,
                  onTap: hasProject && canRedo ? onRedo : null,
                ),
                _IconButton(
                  tooltip: 'Change history (audit log)',
                  icon: Icons.history_outlined,
                  onTap: onHistory,
                ),
                const Spacer(),
                for (final action in trailing) ...<Widget>[
                  if (action.divider) ...<Widget>[
                    const SizedBox(width: 6),
                    Container(width: 1, height: 14, color: c.borderDefault),
                    const SizedBox(width: 6),
                  ],
                  _wrapWithElementMeta(
                    elementId: action.elementId,
                    child: _IconButton(
                      tooltip: action.tooltip,
                      icon: action.icon,
                      onTap: action.onTap,
                      emphasised: action.emphasised,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentMenuButton extends StatefulWidget {
  const _RecentMenuButton({required this.recents, required this.onPick});

  final List<String> recents;
  final ValueChanged<String> onPick;

  @override
  State<_RecentMenuButton> createState() => _RecentMenuButtonState();
}

class _RecentMenuButtonState extends State<_RecentMenuButton> {
  bool _hovered = false;

  Future<void> _open(BuildContext context) async {
    final c = VibeTokens.colorOf(context);
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    final offset = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final size = box.size;
    final anchor = Rect.fromLTWH(
      offset.dx,
      offset.dy + size.height + 2,
      size.width,
      0,
    );
    final picked = await showMenu<String>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      menuPadding: EdgeInsets.zero,
      color: c.elevated,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 480),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          enabled: false,
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'RECENT PROJECTS',
            style: TextStyle(
              fontFamily: VibeTokens.fontMono,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: c.textTertiary,
            ),
          ),
        ),
        for (final path in widget.recents)
          PopupMenuItem<String>(
            value: path,
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  path.split(Platform.pathSeparator).last,
                  style: vibeMono(
                    size: 12,
                    weight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  path,
                  style: TextStyle(
                    fontFamily: VibeTokens.fontMono,
                    fontSize: 10,
                    color: c.textTertiary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
    if (picked != null) widget.onPick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Tooltip(
      message: 'Recent projects',
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _open(context),
          child: AnimatedContainer(
            duration: VibeTokens.durFast,
            curve: VibeTokens.easeStandard,
            margin: const EdgeInsets.only(right: 2),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            decoration: BoxDecoration(
              color: _hovered ? c.surface3 : Colors.transparent,
              borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
            ),
            child: Icon(
              Icons.expand_more,
              size: 16,
              color: _hovered ? c.textPrimary : c.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProjectNameRow extends StatefulWidget {
  const _ProjectNameRow({
    required this.projectName,
    required this.dirty,
    required this.hasProject,
    required this.onRename,
  });

  final String projectName;
  final bool dirty;
  final bool hasProject;
  final VoidCallback onRename;

  @override
  State<_ProjectNameRow> createState() => _ProjectNameRowState();
}

class _ProjectNameRowState extends State<_ProjectNameRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final tipMsg =
        widget.hasProject
            ? (widget.dirty
                ? '${widget.projectName} (unsaved) — click to rename'
                : '${widget.projectName} — click to rename')
            : widget.projectName;
    final nameColor =
        widget.hasProject
            ? (_hovered ? c.mint : c.textPrimary)
            : c.textTertiary;
    final row = Row(
      children: <Widget>[
        if (widget.dirty) ...<Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c.amber, shape: BoxShape.circle),
          ),
          const SizedBox(width: VibeTokens.space2),
        ],
        Flexible(
          child: Text(
            widget.projectName,
            style: vibeMono(
              size: 12,
              weight: FontWeight.w600,
              color: nameColor,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (widget.hasProject) ...<Widget>[
          const SizedBox(width: VibeTokens.space1),
          Icon(
            Icons.edit_outlined,
            size: 12,
            color: _hovered ? c.mint : c.textTertiary,
          ),
        ],
      ],
    );
    return Tooltip(
      message: tipMsg,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor:
            widget.hasProject
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
        onEnter: (_) {
          if (!widget.hasProject) return;
          setState(() => _hovered = true);
        },
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.hasProject ? widget.onRename : null,
          child: row,
        ),
      ),
    );
  }
}

class _IconButton extends StatefulWidget {
  const _IconButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.emphasised = false,
  });

  final String tooltip;
  final IconData icon;

  /// Null disables the button (no hover, dimmed icon, no tap).
  final VoidCallback? onTap;

  /// Highlights the icon (mint tone) when there is something to act on
  /// — used by the Save button so the dirty state is doubly obvious.
  final bool emphasised;

  @override
  State<_IconButton> createState() => _IconButtonState();
}

class _IconButtonState extends State<_IconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final enabled = widget.onTap != null;
    final iconColor =
        !enabled
            ? c.textTertiary
            : widget.emphasised
            ? c.mint
            : (_hovered ? c.textPrimary : c.textSecondary);
    return Tooltip(
      message: enabled ? widget.tooltip : '',
      waitDuration: const Duration(milliseconds: 150),
      preferBelow: false,
      verticalOffset: 18,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        border: Border.all(color: c.borderDefault),
      ),
      textStyle: TextStyle(
        fontFamily: VibeTokens.fontMono,
        fontSize: 11,
        color: c.textPrimary,
      ),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) {
          if (!enabled) return;
          setState(() => _hovered = true);
        },
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: VibeTokens.durFast,
            curve: VibeTokens.easeStandard,
            margin: const EdgeInsets.only(right: 1),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            decoration: BoxDecoration(
              color: enabled && _hovered ? c.surface3 : Colors.transparent,
              borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
            ),
            child: Icon(widget.icon, size: 16, color: iconColor),
          ),
        ),
      ),
    );
  }
}
