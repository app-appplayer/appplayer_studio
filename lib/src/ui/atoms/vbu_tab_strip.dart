import 'package:flutter/material.dart';

import '../tokens.dart';

/// One tab descriptor — icon + label + optional close affordance.
/// Plain data; consumers store any extra context (path, project, etc.)
/// in their own collection keyed by index.
class VbuTab {
  const VbuTab({required this.label, required this.icon, this.closable = true});

  final String label;
  final IconData icon;

  /// When false, the close (×) button is omitted. Use for pinned /
  /// home tabs that should never close.
  final bool closable;
}

/// Horizontal tab strip — vbu atom. Same height as the titlebar
/// (`VbuTokens.titlebarHeight`, 28px) so it sits flush against it.
///
/// Active styling: surface3 bg + 2px mint top-accent + primary text.
/// Inactive: transparent bg + secondary text. Hover: surface2 bg.
///
/// Designed so consumers (and LLM-generated app shells) can compose
/// tabs without re-deriving the active/inactive contrast — the
/// previous host-side handroll mis-merged active pill bg into body bg
/// and made the active tab invisible. Centralising here prevents that
/// class of mistake.
class VbuTabStrip extends StatelessWidget {
  const VbuTabStrip({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onSelect,
    this.onClose,
    this.height = VbuTokens.titlebarHeight,
    this.maxTabWidth = 200,
    this.trailing = const <Widget>[],
    this.showActiveTopAccent = true,
  });

  final List<VbuTab> tabs;
  final int activeIndex;
  final ValueChanged<int> onSelect;

  /// Called when user taps × on a closable tab. If null, close
  /// affordance is hidden regardless of [VbuTab.closable].
  final ValueChanged<int>? onClose;

  final double height;
  final double maxTabWidth;

  /// Optional widgets pinned to the right of the scrollable tab row.
  /// Use for tab-strip-level actions (toggle visibility, add tab, etc.).
  final List<Widget> trailing;

  /// When true (default — matches the chrome top-tab look), active
  /// tabs draw a 2px mint top accent. Set false for sub-tab strips
  /// inside a panel (Scene Builder mode switch, etc.) where the
  /// top-accent collides visually with the outer chrome tabs.
  final bool showActiveTopAccent;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.borderDefault)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: tabs.length,
              itemBuilder:
                  (_, i) => MetaData(
                    metaData: <String, dynamic>{
                      'type': 'vbu_tab',
                      'id': tabs[i].label,
                      'label': tabs[i].label,
                      'index': i,
                      'selected': i == activeIndex,
                    },
                    behavior: HitTestBehavior.translucent,
                    child: _VbuTabPill(
                      tab: tabs[i],
                      selected: i == activeIndex,
                      onTap: () => onSelect(i),
                      onClose:
                          (onClose != null && tabs[i].closable)
                              ? () => onClose!(i)
                              : null,
                      maxLabelWidth: maxTabWidth,
                      showActiveTopAccent: showActiveTopAccent,
                    ),
                  ),
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

class _VbuTabPill extends StatefulWidget {
  const _VbuTabPill({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onClose,
    required this.maxLabelWidth,
    required this.showActiveTopAccent,
  });

  final VbuTab tab;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onClose;
  final double maxLabelWidth;
  final bool showActiveTopAccent;

  @override
  State<_VbuTabPill> createState() => _VbuTabPillState();
}

class _VbuTabPillState extends State<_VbuTabPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final selected = widget.selected;
    final bg =
        selected ? c.surface3 : (_hovered ? c.surface2 : Colors.transparent);
    // Sub-tab variants (showActiveTopAccent=false) drop the mint
    // top-bar, so the active state needs a colour cue — switch the
    // active text + icon to mint instead. Chrome-style tabs keep the
    // higher-contrast primary text since the top-bar already
    // indicates active.
    final fg =
        selected
            ? (widget.showActiveTopAccent ? c.textPrimary : c.mint)
            : c.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(VbuTokens.radiusMd),
              topRight: Radius.circular(VbuTokens.radiusMd),
            ),
            border:
                (selected && widget.showActiveTopAccent)
                    ? Border(top: BorderSide(color: c.mint, width: 2))
                    : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(widget.tab.icon, size: 13, color: fg),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: widget.maxLabelWidth),
                child: Text(
                  widget.tab.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
              if (widget.onClose != null) ...<Widget>[
                const SizedBox(width: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onClose,
                  child: Icon(Icons.close, size: 12, color: fg),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
