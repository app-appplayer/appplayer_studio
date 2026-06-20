import 'package:flutter/material.dart';

import '../tokens.dart';

/// Three-dot pulsing "thinking…" indicator. vibe-derived atom — used
/// while an LLM dispatch is in flight. Hosts can change [label] (e.g.
/// 'compiling…', 'generating…') or pass an empty string to surface only
/// the dots.
class VbuBusyIndicator extends StatefulWidget {
  const VbuBusyIndicator({
    super.key,
    this.label = 'thinking…',
    this.dotColor,
    this.cycleDuration = const Duration(milliseconds: 1200),
  });

  final String label;
  final Color? dotColor;
  final Duration cycleDuration;

  @override
  State<VbuBusyIndicator> createState() => _VbuBusyIndicatorState();
}

class _VbuBusyIndicatorState extends State<VbuBusyIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.cycleDuration)
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Smooth dot phase so the three dots pulse at offset times
  /// (0, 1/3, 2/3 of the cycle).
  double _phase(double t, int i) {
    final p = (t - i / 3) % 1.0;
    return p < 0.5 ? p * 2 : (1 - p) * 2;
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    final dotColor = widget.dotColor ?? c.mint;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: <Widget>[
          AnimatedBuilder(
            animation: _ctrl,
            builder: (ctx, _) {
              final t = _ctrl.value;
              return Row(
                children: <Widget>[
                  for (var i = 0; i < 3; i++) ...<Widget>[
                    Opacity(
                      opacity: 0.3 + 0.7 * _phase(t, i),
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: dotColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    if (i < 2) const SizedBox(width: 4),
                  ],
                ],
              );
            },
          ),
          if (widget.label.isNotEmpty) ...<Widget>[
            const SizedBox(width: 10),
            Text(
              widget.label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: c.textTertiary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
