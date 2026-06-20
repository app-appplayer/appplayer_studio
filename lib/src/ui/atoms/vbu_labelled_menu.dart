import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.dart';

/// Form row with a label + value-display container that opens a custom
/// `showMenu` overlay on tap. Mirrors the pattern from `vbe`'s compact
/// dropdown (`memory feedback_vibe_dropdown_pattern`) — never relies on
/// Material's [DropdownButton] / [DropdownMenu] which surface different
/// visuals.
///
/// Generic over [T]; pass [labels] to override how each option renders
/// (defaults to `value.toString()`).
class VbuLabelledMenu<T> extends StatelessWidget {
  const VbuLabelledMenu({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.labels = const <Never, String>{},
    this.labelWidth = 92,
  });

  final String label;
  final T value;
  final List<T> options;
  final Map<T, String> labels;
  final ValueChanged<T> onChanged;
  final double labelWidth;

  String _labelOf(T v) => labels[v] ?? '$v';

  Future<void> _open(BuildContext context, GlobalKey anchorKey) async {
    final c = VbuTokens.colorOf(context);
    final box = anchorKey.currentContext?.findRenderObject();
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
    final selected = await showMenu<T>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      menuPadding: EdgeInsets.zero,
      color: c.elevated,
      constraints: BoxConstraints(minWidth: size.width, maxWidth: size.width),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
        side: BorderSide(color: c.borderStrong),
      ),
      position: RelativeRect.fromRect(anchor, Offset.zero & overlaySize),
      items: <PopupMenuEntry<T>>[
        for (final opt in options)
          PopupMenuItem<T>(
            value: opt,
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              _labelOf(opt),
              style: vbuMono(
                size: 11,
                color: opt == value ? c.mint : c.textPrimary,
              ),
            ),
          ),
      ],
    );
    if (selected != null && selected != value) onChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final anchorKey = GlobalKey();
    return Row(
      children: <Widget>[
        SizedBox(
          width: labelWidth,
          child: Text(label, style: vbuMono(size: 11, color: c.textSecondary)),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _open(context, anchorKey),
            child: Container(
              key: anchorKey,
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(VbuTokens.radiusMd),
                border: Border.all(color: c.borderDefault),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _labelOf(value),
                      style: vbuMono(size: 12, color: c.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(Icons.expand_more, size: 14, color: c.textSecondary),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
