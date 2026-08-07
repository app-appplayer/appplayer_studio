import 'package:flutter/material.dart';

import '../../renderer/render_context.dart';
import '../../utils/binding_path.dart';
import '../widget_factory.dart';

/// Factory for `popover` (spec §2.11.6). Alias: `hoverCard`.
///
/// Distinct from `tooltip` (text only, nothing focusable) and `customDialog`
/// (modal, centred). A popover keeps the page usable behind it and positions
/// against its anchor — the part composition cannot supply: flipping to the
/// other side when it would overflow the viewport, and returning focus to the
/// trigger on dismiss.
class PopoverFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final properties = extractProperties(definition);

    final childDef = properties['child'] as Map<String, dynamic>?;
    final contentDef = properties['content'] as Map<String, dynamic>?;
    if (childDef == null || contentDef == null) return const SizedBox.shrink();

    final trigger = context.resolve<String?>(properties['trigger']) ?? 'tap';
    // Two-way: binding it lets an action drive the surface, which is the only
    // way `trigger: manual` is usable at all.
    final openBinding = twoWayPath(properties['open']);
    final open = context.resolve<bool?>(properties['open']) ?? false;
    final placement = context.resolve<String?>(properties['placement']) ?? 'auto';
    final openDelay = context.resolve<num?>(properties['openDelay'])?.toInt() ?? 0;
    final closeDelay = context.resolve<num?>(properties['closeDelay'])?.toInt() ?? 0;
    final dismissOnOutside =
        context.resolve<bool?>(properties['dismissOnOutside']) ?? true;
    final onOpen = actionOf(properties['onOpen'], context);
    final onClose = actionOf(properties['onClose'], context);

    void emit(Map<String, dynamic>? action) {
      if (action == null) return;
      context.actionHandler.execute(action, context);
    }

    return _Popover(
      open: open,
      onOpenChanged: (value) {
        if (openBinding != null) context.setValue(openBinding, value);
      },
      anchor: context.renderer.renderWidget(childDef, context),
      content: context.renderer.renderWidget(contentDef, context),
      trigger: trigger,
      placement: placement,
      openDelay: Duration(milliseconds: openDelay),
      closeDelay: Duration(milliseconds: closeDelay),
      dismissOnOutside: dismissOnOutside,
      onOpen: () => emit(onOpen),
      onClose: () => emit(onClose),
    );
  }
}

class _Popover extends StatefulWidget {
  const _Popover({
    required this.open,
    required this.onOpenChanged,
    required this.anchor,
    required this.content,
    required this.trigger,
    required this.placement,
    required this.openDelay,
    required this.closeDelay,
    required this.dismissOnOutside,
    required this.onOpen,
    required this.onClose,
  });

  final bool open;
  final ValueChanged<bool> onOpenChanged;
  final Widget anchor;
  final Widget content;
  final String trigger;
  final String placement;
  final Duration openDelay;
  final Duration closeDelay;
  final bool dismissOnOutside;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  State<_Popover> createState() => _PopoverState();
}

class _PopoverState extends State<_Popover> {
  final LayerLink _link = LayerLink();
  final FocusNode _anchorFocus = FocusNode();
  OverlayEntry? _entry;

  @override
  void didUpdateWidget(_Popover old) {
    super.didUpdateWidget(old);
    // The bound value is the truth: a state change opens or closes the surface
    // even when nothing touched the trigger.
    if (widget.open != old.open) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.open ? _open() : _close();
      });
    }
  }

  @override
  void dispose() {
    _remove();
    _anchorFocus.dispose();
    super.dispose();
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
  }

  void _open() {
    if (_entry != null) return;
    final box = context.findRenderObject() as RenderBox?;
    final anchorSize = box?.size ?? Size.zero;
    final anchorTopLeft = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    final screen = MediaQuery.of(context).size;

    // Flip when the preferred side has no room. `auto` picks the side with
    // more space; an explicit side still flips rather than rendering
    // off-screen.
    final spaceBelow = screen.height - (anchorTopLeft.dy + anchorSize.height);
    final spaceAbove = anchorTopLeft.dy;
    final below = widget.placement == 'bottom'
        ? spaceBelow > 120 || spaceBelow >= spaceAbove
        : widget.placement == 'top'
            ? !(spaceAbove > 120 || spaceAbove >= spaceBelow)
            : spaceBelow >= spaceAbove;

    _entry = OverlayEntry(
      builder: (_) => Stack(
        children: [
          if (widget.dismissOnOutside)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _close,
              ),
            ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: below ? Alignment.bottomLeft : Alignment.topLeft,
            followerAnchor: below ? Alignment.topLeft : Alignment.bottomLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(6),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: screen.width * 0.9),
                child: widget.content,
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_entry!);
    widget.onOpenChanged(true);
    widget.onOpen();
  }

  void _close() {
    if (_entry == null) return;
    _remove();
    // Focus returns to the trigger, so keyboard users are not dropped at the
    // top of the page.
    _anchorFocus.requestFocus();
    widget.onOpenChanged(false);
    widget.onClose();
  }

  void _toggle() => _entry == null ? _open() : _close();

  @override
  Widget build(BuildContext context) {
    Widget anchor = Focus(focusNode: _anchorFocus, child: widget.anchor);

    switch (widget.trigger) {
      case 'hover':
        anchor = MouseRegion(
          onEnter: (_) => Future.delayed(widget.openDelay, () {
            if (mounted) _open();
          }),
          onExit: (_) => Future.delayed(widget.closeDelay, () {
            if (mounted) _close();
          }),
          child: anchor,
        );
        break;
      case 'focus':
        anchor = Focus(
          onFocusChange: (has) => has ? _open() : _close(),
          child: anchor,
        );
        break;
      case 'manual':
        break;
      default:
        anchor = GestureDetector(onTap: _toggle, child: anchor);
    }

    return CompositedTransformTarget(link: _link, child: anchor);
  }
}
