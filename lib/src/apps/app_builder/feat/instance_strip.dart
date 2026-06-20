import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart' show inspectTag;

import '../theme/app_theme.dart';
import '../theme/tokens.dart';
import '../core/types.dart';
import 'property_editors.dart';

/// Sub-strip that surfaces multi-instance layers (pages, components /
/// templates). Each entry is a small card showing the instance id + a
/// per-card delete affordance; an `Add` card creates a new entry. The
/// selected card drives [PropertiesPanel] focus.
///
/// Renders only when the focused layer has multiple-instance semantics.
/// OverviewStrip is unaffected.
///
/// Two orientations:
///   * [Axis.horizontal] — fits inside a fixed-height row.
///   * [Axis.vertical] — sidebar inside the preview area.
class InstanceStrip extends StatelessWidget {
  const InstanceStrip({
    super.key,
    required this.layer,
    required this.entries,
    required this.selectedId,
    required this.onSelect,
    required this.onAdd,
    required this.onDelete,
    required this.onDuplicate,
    this.onAddRoute,
    this.axis = Axis.horizontal,
    this.issuesPerEntry = const <String, int>{},
  });

  /// Per-entry issue count (page id / template id → blocking +
  /// advisory total). Drives the small badge on each card; absent
  /// or zero entries render no badge.
  final Map<String, int> issuesPerEntry;

  /// `LayerId.pages` (or `LayerId.dashboard`) and `LayerId.components` are
  /// the only valid hosts. Other layers receive a const empty strip.
  final LayerId layer;

  /// Ordered list of instance ids to render. Empty list → only the Add card.
  final List<String> entries;

  /// Currently focused entry. `null` → no card highlighted.
  final String? selectedId;

  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<String> onDelete;
  final ValueChanged<String> onDuplicate;

  /// Pages-only: invoked when the user picks `Add route` from the
  /// per-card `⋯` menu. Hosts pop a path-prompt dialog and dispatch
  /// the route patch. Null hides the menu entry — typical for
  /// non-page strips (templates) where routes don't apply.
  final ValueChanged<String>? onAddRoute;

  /// Layout direction. Horizontal = top sub-strip; Vertical = side panel.
  final Axis axis;

  static const double _height = 56.0;
  static const double _cardWidth = 152.0;
  static const double _verticalWidth = 168.0;
  static const double _verticalRowHeight = 32.0;

  Color _layerColor(BuildContext context) {
    switch (layer) {
      case LayerId.pages:
      case LayerId.dashboard:
        return VibeTokens.layer.page;
      case LayerId.components:
        return VibeTokens.layer.component;
      default:
        return VibeTokens.colorOf(context).borderStrong;
    }
  }

  String _addLabel() {
    switch (layer) {
      case LayerId.pages:
      case LayerId.dashboard:
        return 'Add page';
      case LayerId.components:
        return 'Add template';
      default:
        return 'Add';
    }
  }

  String _titleLabel() {
    switch (layer) {
      case LayerId.pages:
      case LayerId.dashboard:
        return 'Pages';
      case LayerId.components:
        return 'Templates';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final color = _layerColor(context);
    if (axis == Axis.vertical) {
      return Container(
        key: const Key('vibe.instance.strip'),
        width: _verticalWidth,
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(right: BorderSide(color: c.borderDefault)),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space2,
          vertical: VibeTokens.space2,
        ),
        child: ListView(
          children: <Widget>[
            _SectionTitle(label: _titleLabel(), color: color),
            for (final id in entries)
              Padding(
                padding: const EdgeInsets.only(bottom: VibeTokens.space1),
                child: _InstanceCard(
                  id: id,
                  selected: id == selectedId,
                  layerColor: color,
                  axis: Axis.vertical,
                  issues: issuesPerEntry[id] ?? 0,
                  onTap: () => onSelect(id),
                  onDelete: () => onDelete(id),
                  onDuplicate: () => onDuplicate(id),
                  onAddRoute: onAddRoute == null ? null : () => onAddRoute!(id),
                ),
              ),
            const SizedBox(height: VibeTokens.space1),
            _AddCard(
              label: _addLabel(),
              color: color,
              axis: Axis.vertical,
              onTap: onAdd,
            ),
          ],
        ),
      );
    }
    return Container(
      key: const Key('vibe.instance.strip'),
      height: _height,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.borderDefault)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space3,
        vertical: VibeTokens.space2,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            for (var i = 0; i < entries.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: VibeTokens.stripCardGap),
                child: _InstanceCard(
                  id: entries[i],
                  selected: entries[i] == selectedId,
                  layerColor: color,
                  issues: issuesPerEntry[entries[i]] ?? 0,
                  onTap: () => onSelect(entries[i]),
                  onDelete: () => onDelete(entries[i]),
                  onDuplicate: () => onDuplicate(entries[i]),
                  onAddRoute:
                      onAddRoute == null ? null : () => onAddRoute!(entries[i]),
                ),
              ),
            _AddCard(label: _addLabel(), color: color, onTap: onAdd),
          ],
        ),
      ),
    );
  }
}

class _InstanceCard extends StatefulWidget {
  const _InstanceCard({
    required this.id,
    required this.selected,
    required this.layerColor,
    required this.onTap,
    required this.onDelete,
    required this.onDuplicate,
    this.onAddRoute,
    this.axis = Axis.horizontal,
    this.issues = 0,
  });

  final String id;
  final bool selected;
  final Color layerColor;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;
  final VoidCallback? onAddRoute;
  final Axis axis;

  /// Issue count surfaced from the shell's health snapshot. Zero
  /// renders no badge so cards stay clean for healthy entries.
  final int issues;

  @override
  State<_InstanceCard> createState() => _InstanceCardState();
}

class _InstanceCardState extends State<_InstanceCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final borderColor =
        widget.selected
            ? widget.layerColor
            : _hovered
            ? c.borderStrong
            : c.borderDefault;
    final borderWidth = widget.selected ? 1.5 : 1.0;
    final cardBg = widget.selected ? c.surface3 : c.surface2;
    final nameColor = widget.selected ? c.textPrimary : c.textSecondary;

    final inner = Stack(
      children: <Widget>[
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: Container(width: 3, color: widget.layerColor),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            VibeTokens.space2 + 3,
            0,
            VibeTokens.space1,
            0,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  widget.id,
                  style: TextStyle(
                    fontFamily: VibeTokens.fontMono,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: nameColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.issues > 0)
                Tooltip(
                  message:
                      '${widget.issues} a11y / state issue'
                      '${widget.issues == 1 ? '' : 's'} '
                      'on this page — see Health bar in chat for '
                      'detail.',
                  waitDuration: const Duration(milliseconds: 200),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface3,
                      borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                      border: Border.all(color: c.coral),
                    ),
                    child: Text(
                      '${widget.issues}',
                      style: TextStyle(
                        fontFamily: VibeTokens.fontMono,
                        fontSize: 10,
                        color: c.coral,
                      ),
                    ),
                  ),
                ),
              if (_hovered || widget.selected)
                _MenuButton(
                  onDuplicate: widget.onDuplicate,
                  onDelete: widget.onDelete,
                  onAddRoute: widget.onAddRoute,
                ),
            ],
          ),
        ),
      ],
    );

    return inspectTag(
      type: 'instance_card',
      id: widget.id,
      extra: <String, dynamic>{'selected': widget.selected},
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: VibeTokens.durFast,
            curve: VibeTokens.easeStandard,
            width:
                widget.axis == Axis.vertical
                    ? double.infinity
                    : InstanceStrip._cardWidth,
            height:
                widget.axis == Axis.vertical
                    ? InstanceStrip._verticalRowHeight
                    : null,
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
              border: Border.all(color: borderColor, width: borderWidth),
            ),
            child: inner,
          ),
        ),
      ),
    );
  }
}

/// Trailing `⋮` button that opens a [showMenu] popup with `Duplicate` /
/// `Delete`. Uses an opaque [GestureDetector] so the tap is claimed before
/// the parent card's tap handler runs (which would otherwise consume it
/// and re-fire `onTap`).
class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.onDuplicate,
    required this.onDelete,
    this.onAddRoute,
  });

  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  /// When non-null, the popup gains an `Add route` entry — pages-only.
  /// Hosts open a dialog to capture the URL path and dispatch the
  /// route patch on confirm.
  final VoidCallback? onAddRoute;

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
    final selected = await showMenu<String>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      menuPadding: EdgeInsets.zero,
      color: c.elevated,
      constraints: const BoxConstraints(minWidth: 120),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'duplicate',
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'Duplicate',
            style: vibeMono(size: 11, color: c.textPrimary),
          ),
        ),
        if (onAddRoute != null)
          PopupMenuItem<String>(
            value: 'addRoute',
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'Add route',
              style: vibeMono(size: 11, color: c.textPrimary),
            ),
          ),
        PopupMenuItem<String>(
          value: 'delete',
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text('Delete', style: vibeMono(size: 11, color: c.coral)),
        ),
      ],
    );
    if (selected == 'duplicate') {
      onDuplicate();
    } else if (selected == 'addRoute') {
      onAddRoute?.call();
    } else if (selected == 'delete') {
      onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Icon(
          Icons.more_vert,
          size: 16,
          color: VibeTokens.colorOf(context).textTertiary,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VibeTokens.space1,
        0,
        VibeTokens.space1,
        VibeTokens.space2,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: VibeTokens.fontMono,
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: c.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

class _AddCard extends StatefulWidget {
  const _AddCard({
    required this.label,
    required this.color,
    required this.onTap,
    this.axis = Axis.horizontal,
  });
  final String label;
  final Color color;
  final VoidCallback onTap;
  final Axis axis;

  @override
  State<_AddCard> createState() => _AddCardState();
}

class _AddCardState extends State<_AddCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return inspectTag(
      type: 'instance_card_add',
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: VibeTokens.durFast,
            curve: VibeTokens.easeStandard,
            width:
                widget.axis == Axis.vertical
                    ? double.infinity
                    : InstanceStrip._cardWidth * 0.7,
            height:
                widget.axis == Axis.vertical
                    ? InstanceStrip._verticalRowHeight
                    : null,
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
              border: Border.all(
                color: _hovered ? widget.color : c.borderSubtle,
                width: _hovered ? 1.5 : 1.0,
              ),
            ),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.add, size: 14, color: c.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    widget.label,
                    style: TextStyle(
                      fontFamily: VibeTokens.fontSans,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: c.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks the user for a fresh instance id with the given title. Returns null
/// when the dialog is dismissed or the input is empty.
Future<String?> promptForInstanceId(
  BuildContext context, {
  required String title,
  required String hint,
}) async {
  final ctrl = TextEditingController();
  final c = VibeTokens.colorOf(context);
  return showDialog<String?>(
    context: context,
    builder:
        (ctx) => Dialog(
          backgroundColor: c.surface2,
          child: SizedBox(
            width: 360,
            child: Padding(
              padding: const EdgeInsets.all(VibeTokens.space4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: VibeTokens.fontMono,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: VibeTokens.space2),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    style: TextStyle(
                      fontFamily: VibeTokens.fontMono,
                      fontSize: 12,
                      color: c.textPrimary,
                    ),
                    decoration: InputDecoration(hintText: hint, isDense: true),
                    onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
                  ),
                  const SizedBox(height: VibeTokens.space3),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(null),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: VibeTokens.space2),
                      FilledButton(
                        onPressed:
                            () => Navigator.of(ctx).pop(ctrl.text.trim()),
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
  ).then((v) => v == null || v.isEmpty ? null : v);
}

/// Shared `PatchDispatcher` re-export so consumers can spell the type
/// without importing `property_editors.dart` directly.
typedef InstanceDispatcher = PatchDispatcher;
