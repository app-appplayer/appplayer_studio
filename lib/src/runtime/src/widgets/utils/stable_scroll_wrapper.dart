import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A wrapper widget that ensures scrollable widgets are rendered in a stable state
/// This helps prevent viewport-related assertion errors during testing
class StableScrollWrapper extends StatefulWidget {
  const StableScrollWrapper({
    super.key,
    required this.child,
    this.initialDelay = const Duration(milliseconds: 16),
  });

  final Widget child;
  final Duration initialDelay;

  @override
  State<StableScrollWrapper> createState() => _StableScrollWrapperState();
}

class _StableScrollWrapperState extends State<StableScrollWrapper> {
  bool _isReady = false;

  @override
  void initState() {
    super.initState();

    // Schedule a frame to ensure the widget tree is stable
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {
          _isReady = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady) {
      // Return a placeholder that doesn't use viewport
      return const SizedBox(
        width: double.infinity,
        height: 200,
        child: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return widget.child;
  }
}

/// Extension to check if we're in a test environment
extension TestEnvironment on BuildContext {
  bool get isInTestEnvironment {
    // Check if we're running in a test environment
    return SchedulerBinding.instance.runtimeType.toString().contains('Test');
  }
}
