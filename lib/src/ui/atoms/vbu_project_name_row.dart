import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Compact project / bundle name row with optional dirty dot + edit
/// affordance. vibe-derived. Mono text, amber dirty bullet, edit icon
/// reveals on hover when there's a project bound.
///
/// Hosts wire `onRename` to launch a rename dialog. When [hasProject] is
/// false the row dims to `textTertiary` and the click target is
/// disabled — useful as a "No project" placeholder.
class VbuProjectNameRow extends StatefulWidget {
  const VbuProjectNameRow({
    super.key,
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
  State<VbuProjectNameRow> createState() => _VbuProjectNameRowState();
}

class _VbuProjectNameRowState extends State<VbuProjectNameRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
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
          const SizedBox(width: VbuTokens.space2),
        ],
        Flexible(
          child: Text(
            widget.projectName,
            style: vbuMono(size: 12, weight: FontWeight.w600, color: nameColor),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (widget.hasProject) ...<Widget>[
          const SizedBox(width: VbuTokens.space1),
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
