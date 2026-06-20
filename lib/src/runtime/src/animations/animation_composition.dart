import 'package:flutter/material.dart';

/// Animation composition utilities for MCP UI DSL v1.1.
///
/// Supports three composition modes:
/// - **parallel**: Multiple animations run simultaneously
/// - **sequence**: Animations run one after another
/// - **stagger**: Animations start at regular intervals with overlap
class AnimationComposition {
  /// Run multiple animated widgets in parallel (simultaneously).
  ///
  /// All provided widgets are displayed at once in a Stack, allowing
  /// their animations to play concurrently.
  static Widget parallel(List<Widget> animations) {
    if (animations.isEmpty) return const SizedBox.shrink();
    if (animations.length == 1) return animations.first;

    return Stack(
      children: animations,
    );
  }

  /// Run animations in sequence, one after another.
  ///
  /// Each builder creates a widget that animates for the corresponding
  /// duration. The next animation starts only after the previous one completes.
  ///
  /// [builders] - List of widget builder functions for each step.
  /// [durations] - Duration for each animation step.
  static Widget sequence(
    List<Widget Function()> builders,
    List<Duration> durations,
  ) {
    if (builders.isEmpty) return const SizedBox.shrink();

    return _SequenceAnimationWidget(
      builders: builders,
      durations: durations,
    );
  }

  /// Run animations with staggered start times.
  ///
  /// Each animation starts after the specified interval from the previous one,
  /// creating a cascading/wave effect.
  ///
  /// [builders] - List of widget builder functions for each step.
  /// [interval] - Delay between the start of each successive animation.
  static Widget stagger(
    List<Widget Function()> builders,
    Duration interval,
  ) {
    if (builders.isEmpty) return const SizedBox.shrink();

    return _StaggerAnimationWidget(
      builders: builders,
      interval: interval,
    );
  }
}

/// Internal widget that plays animations in sequence
class _SequenceAnimationWidget extends StatefulWidget {
  final List<Widget Function()> builders;
  final List<Duration> durations;

  const _SequenceAnimationWidget({
    required this.builders,
    required this.durations,
  });

  @override
  State<_SequenceAnimationWidget> createState() =>
      _SequenceAnimationWidgetState();
}

class _SequenceAnimationWidgetState extends State<_SequenceAnimationWidget> {
  int _currentIndex = 0;
  late List<Widget> _builtWidgets;

  @override
  void initState() {
    super.initState();
    _builtWidgets = [widget.builders[0]()];
    _scheduleNext();
  }

  void _scheduleNext() {
    if (_currentIndex >= widget.builders.length - 1) return;

    final duration = _currentIndex < widget.durations.length
        ? widget.durations[_currentIndex]
        : const Duration(milliseconds: 300);

    Future.delayed(duration, () {
      if (!mounted) return;
      setState(() {
        _currentIndex++;
        _builtWidgets = [widget.builders[_currentIndex]()];
      });
      _scheduleNext();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_builtWidgets.isEmpty) return const SizedBox.shrink();
    return _builtWidgets.first;
  }
}

/// Internal widget that plays animations with staggered start times
class _StaggerAnimationWidget extends StatefulWidget {
  final List<Widget Function()> builders;
  final Duration interval;

  const _StaggerAnimationWidget({
    required this.builders,
    required this.interval,
  });

  @override
  State<_StaggerAnimationWidget> createState() =>
      _StaggerAnimationWidgetState();
}

class _StaggerAnimationWidgetState extends State<_StaggerAnimationWidget> {
  final List<Widget> _visibleWidgets = [];

  @override
  void initState() {
    super.initState();
    _startStaggering();
  }

  void _startStaggering() {
    for (int i = 0; i < widget.builders.length; i++) {
      final delay = widget.interval * i;
      Future.delayed(delay, () {
        if (!mounted) return;
        setState(() {
          _visibleWidgets.add(widget.builders[i]());
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_visibleWidgets.isEmpty) return const SizedBox.shrink();

    return Stack(
      children: _visibleWidgets,
    );
  }
}
