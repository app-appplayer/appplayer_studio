import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import '../utils/mcp_logger.dart';

/// Live region types for accessibility announcements
/// according to MCP UI DSL v1.0 specification
enum LiveRegionType {
  /// Polite announcements - wait for current speech to finish
  polite,

  /// Assertive announcements - interrupt current speech
  assertive,

  /// Status updates only
  status,

  /// Alert messages
  alert,
}

/// Live region manager for accessibility announcements
class LiveRegionManager {
  static LiveRegionManager? _instance;
  static LiveRegionManager get instance => _instance ??= LiveRegionManager._();

  LiveRegionManager._();

  final MCPLogger _logger = MCPLogger('LiveRegionManager');
  final Map<String, StreamController<String>> _regionControllers = {};
  final Map<String, LiveRegionType> _regionTypes = {};

  /// Create a live region
  void createRegion(String id, LiveRegionType type) {
    if (_regionControllers.containsKey(id)) {
      _logger.warning('Live region already exists: $id');
      return;
    }

    _regionControllers[id] = StreamController<String>.broadcast();
    _regionTypes[id] = type;

    _logger.debug('Created live region: $id (type: ${type.name})');
  }

  /// Remove a live region
  void removeRegion(String id) {
    final controller = _regionControllers.remove(id);
    controller?.close();
    _regionTypes.remove(id);

    _logger.debug('Removed live region: $id');
  }

  /// Announce to a live region
  void announce(String regionId, String message) {
    final controller = _regionControllers[regionId];
    if (controller == null) {
      _logger.warning('Live region not found: $regionId');
      return;
    }

    controller.add(message);

    // Also announce via SemanticsService for immediate feedback
    final type = _regionTypes[regionId] ?? LiveRegionType.polite;
    _announceToSemantics(message, type);

    _logger.debug('Announced to region $regionId: $message');
  }

  /// Get stream for a live region
  Stream<String>? getRegionStream(String id) {
    return _regionControllers[id]?.stream;
  }

  /// Announce directly to semantics
  void _announceToSemantics(String message, LiveRegionType type) {
    switch (type) {
      case LiveRegionType.assertive:
      case LiveRegionType.alert:
        // Use assertive announcement
        SemanticsService.announce(message, TextDirection.ltr,
            assertiveness: Assertiveness.assertive);
        break;
      case LiveRegionType.polite:
      case LiveRegionType.status:
        // Use polite announcement
        SemanticsService.announce(message, TextDirection.ltr);
        break;
    }
  }

  /// Clear all regions
  void clear() {
    for (final controller in _regionControllers.values) {
      controller.close();
    }
    _regionControllers.clear();
    _regionTypes.clear();
  }
}

/// Live region widget for dynamic content announcements
class LiveRegion extends StatefulWidget {
  final String regionId;
  final LiveRegionType type;
  final Widget child;
  final bool announceInitialValue;
  final String? initialValue;

  const LiveRegion({
    super.key,
    required this.regionId,
    this.type = LiveRegionType.polite,
    required this.child,
    this.announceInitialValue = false,
    this.initialValue,
  });

  @override
  State<LiveRegion> createState() => _LiveRegionState();
}

class _LiveRegionState extends State<LiveRegion> {
  late StreamSubscription<String> _subscription;
  String? _lastAnnouncement;

  @override
  void initState() {
    super.initState();

    // Create region
    LiveRegionManager.instance.createRegion(widget.regionId, widget.type);

    // Subscribe to announcements
    final stream = LiveRegionManager.instance.getRegionStream(widget.regionId);
    if (stream != null) {
      _subscription = stream.listen((message) {
        if (mounted) {
          setState(() {
            _lastAnnouncement = message;
          });
        }
      });
    }

    // Announce initial value if requested
    if (widget.announceInitialValue && widget.initialValue != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        LiveRegionManager.instance
            .announce(widget.regionId, widget.initialValue!);
      });
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    LiveRegionManager.instance.removeRegion(widget.regionId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: _lastAnnouncement,
      child: widget.child,
    );
  }
}

/// Status live region for form validation and status updates
class StatusLiveRegion extends StatelessWidget {
  final String message;
  final LiveRegionType type;
  final Duration? autoDismiss;
  final VoidCallback? onDismiss;

  const StatusLiveRegion({
    super.key,
    required this.message,
    this.type = LiveRegionType.status,
    this.autoDismiss,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    // Announce immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SemanticsService.announce(
        message,
        TextDirection.ltr,
        assertiveness: type == LiveRegionType.assertive
            ? Assertiveness.assertive
            : Assertiveness.polite,
      );

      // Auto dismiss if specified
      if (autoDismiss != null && onDismiss != null) {
        Future.delayed(autoDismiss!, onDismiss!);
      }
    });

    return Semantics(
      liveRegion: true,
      label: message,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _getBackgroundColor(type),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              _getIcon(type),
              color: _getTextColor(type),
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: _getTextColor(type),
                  fontSize: 14,
                ),
              ),
            ),
            if (onDismiss != null)
              IconButton(
                icon: Icon(
                  Icons.close,
                  color: _getTextColor(type),
                  size: 18,
                ),
                onPressed: onDismiss,
                tooltip: 'Dismiss',
              ),
          ],
        ),
      ),
    );
  }

  Color _getBackgroundColor(LiveRegionType type) {
    switch (type) {
      case LiveRegionType.alert:
        return Colors.red.shade50;
      case LiveRegionType.status:
        return Colors.blue.shade50;
      default:
        return Colors.grey.shade100;
    }
  }

  Color _getTextColor(LiveRegionType type) {
    switch (type) {
      case LiveRegionType.alert:
        return Colors.red.shade700;
      case LiveRegionType.status:
        return Colors.blue.shade700;
      default:
        return Colors.grey.shade700;
    }
  }

  IconData _getIcon(LiveRegionType type) {
    switch (type) {
      case LiveRegionType.alert:
        return Icons.error_outline;
      case LiveRegionType.status:
        return Icons.info_outline;
      default:
        return Icons.announcement;
    }
  }
}

/// Live region builder for dynamic content
class LiveRegionBuilder extends StatefulWidget {
  final String regionId;
  final LiveRegionType type;
  final Widget Function(BuildContext context, String? announcement) builder;

  const LiveRegionBuilder({
    super.key,
    required this.regionId,
    this.type = LiveRegionType.polite,
    required this.builder,
  });

  @override
  State<LiveRegionBuilder> createState() => _LiveRegionBuilderState();
}

class _LiveRegionBuilderState extends State<LiveRegionBuilder> {
  late StreamSubscription<String> _subscription;
  String? _currentAnnouncement;

  @override
  void initState() {
    super.initState();

    // Create region
    LiveRegionManager.instance.createRegion(widget.regionId, widget.type);

    // Subscribe to announcements
    final stream = LiveRegionManager.instance.getRegionStream(widget.regionId);
    if (stream != null) {
      _subscription = stream.listen((message) {
        if (mounted) {
          setState(() {
            _currentAnnouncement = message;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    LiveRegionManager.instance.removeRegion(widget.regionId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: _currentAnnouncement,
      child: widget.builder(context, _currentAnnouncement),
    );
  }
}

/// Progress indicator with live region announcements
class AccessibleProgressIndicator extends StatefulWidget {
  final double? value;
  final String? label;
  final bool announceProgress;
  final Duration announcementInterval;

  const AccessibleProgressIndicator({
    super.key,
    this.value,
    this.label,
    this.announceProgress = true,
    this.announcementInterval = const Duration(seconds: 5),
  });

  @override
  State<AccessibleProgressIndicator> createState() =>
      _AccessibleProgressIndicatorState();
}

class _AccessibleProgressIndicatorState
    extends State<AccessibleProgressIndicator> {
  Timer? _announcementTimer;
  double? _lastAnnouncedValue;

  @override
  void initState() {
    super.initState();

    if (widget.announceProgress && widget.value != null) {
      _startAnnouncementTimer();
    }
  }

  @override
  void didUpdateWidget(AccessibleProgressIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.value != oldWidget.value) {
      if (widget.announceProgress && widget.value != null) {
        _startAnnouncementTimer();
      } else {
        _stopAnnouncementTimer();
      }
    }
  }

  void _startAnnouncementTimer() {
    _stopAnnouncementTimer();

    _announcementTimer = Timer.periodic(widget.announcementInterval, (_) {
      if (widget.value != null && widget.value != _lastAnnouncedValue) {
        final percentage = (widget.value! * 100).round();
        final message = '${widget.label ?? 'Progress'}: $percentage%';

        SemanticsService.announce(message, TextDirection.ltr);
        _lastAnnouncedValue = widget.value;
      }
    });

    // Announce immediately
    if (widget.value != null) {
      final percentage = (widget.value! * 100).round();
      final message = '${widget.label ?? 'Progress'}: $percentage%';
      SemanticsService.announce(message, TextDirection.ltr);
      _lastAnnouncedValue = widget.value;
    }
  }

  void _stopAnnouncementTimer() {
    _announcementTimer?.cancel();
    _announcementTimer = null;
  }

  @override
  void dispose() {
    _stopAnnouncementTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progressIndicator = widget.value != null
        ? LinearProgressIndicator(value: widget.value)
        : const LinearProgressIndicator();

    return Semantics(
      label: widget.label ?? 'Progress indicator',
      value: widget.value != null
          ? '${(widget.value! * 100).round()}%'
          : 'Loading',
      child: progressIndicator,
    );
  }
}

/// Form field with live validation announcements
class AccessibleFormField extends StatefulWidget {
  final String fieldId;
  final String label;
  final TextEditingController? controller;
  final String? Function(String?)? validator;
  final bool announceErrors;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final bool obscureText;

  const AccessibleFormField({
    super.key,
    required this.fieldId,
    required this.label,
    this.controller,
    this.validator,
    this.announceErrors = true,
    this.decoration,
    this.keyboardType,
    this.obscureText = false,
  });

  @override
  State<AccessibleFormField> createState() => _AccessibleFormFieldState();
}

class _AccessibleFormFieldState extends State<AccessibleFormField> {
  late TextEditingController _controller;
  String? _errorText;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();

    // Create live region for errors
    if (widget.announceErrors) {
      LiveRegionManager.instance.createRegion(
        '${widget.fieldId}_error',
        LiveRegionType.assertive,
      );
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller.dispose();
    }
    _focusNode.dispose();

    if (widget.announceErrors) {
      LiveRegionManager.instance.removeRegion('${widget.fieldId}_error');
    }

    super.dispose();
  }

  void _validate(String value) {
    if (widget.validator != null) {
      final error = widget.validator!(value);

      if (error != _errorText) {
        setState(() {
          _errorText = error;
        });

        // Announce error changes
        if (widget.announceErrors && _focusNode.hasFocus) {
          if (error != null) {
            LiveRegionManager.instance.announce(
              '${widget.fieldId}_error',
              'Error: $error',
            );
          } else if (_errorText != null) {
            LiveRegionManager.instance.announce(
              '${widget.fieldId}_error',
              'Error cleared',
            );
          }
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      hint: _errorText,
      textField: true,
      child: TextFormField(
        controller: _controller,
        focusNode: _focusNode,
        decoration: (widget.decoration ?? const InputDecoration()).copyWith(
          labelText: widget.label,
          errorText: _errorText,
        ),
        keyboardType: widget.keyboardType,
        obscureText: widget.obscureText,
        onChanged: _validate,
        validator: widget.validator,
      ),
    );
  }
}
