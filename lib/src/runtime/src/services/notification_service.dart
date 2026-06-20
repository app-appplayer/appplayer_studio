import 'package:flutter/material.dart';
import '../runtime/service_registry.dart';
import '../notifications/notification_manager.dart';
import '../notifications/notification_types.dart';
import '../utils/mcp_logger.dart';

/// Service for managing notifications within the runtime
class NotificationService extends RuntimeService {
  NotificationService({
    required NotificationManager notificationManager,
    super.enableDebugMode,
  }) : _manager = notificationManager;

  static final _logger = MCPLogger('NotificationService');

  final NotificationManager _manager;
  final Map<String, NotificationChannel> _channels = {};
  final Map<String, VoidCallback> _actionHandlers = {};

  /// Gets the notification manager
  NotificationManager get manager => _manager;

  /// Shows a notification
  Future<void> showNotification({
    required String id,
    required String title,
    String? body,
    NotificationType type = NotificationType.local,
    String channelId = 'general',
    NotificationImportance priority = NotificationImportance.defaultImportance,
    List<NotificationAction>? actions,
    Map<String, dynamic>? data,
    bool autoCancel = true,
  }) async {
    final notification = MCPNotification(
      id: id,
      title: title,
      body: body,
      type: type,
      channelId: channelId,
      priority: priority,
      actions: actions ?? [],
      data: data ?? {},
      autoCancel: autoCancel,
    );

    await _manager.showNotification(notification);
  }

  /// Schedules a notification
  Future<void> scheduleNotification({
    required String id,
    required String title,
    required DateTime scheduledTime,
    String? body,
    NotificationType type = NotificationType.local,
    String channelId = 'general',
    NotificationImportance priority = NotificationImportance.defaultImportance,
    List<NotificationAction>? actions,
    Map<String, dynamic>? data,
    Duration? repeatInterval,
  }) async {
    final notification = MCPNotification(
      id: id,
      title: title,
      body: body,
      type: type,
      channelId: channelId,
      priority: priority,
      actions: actions ?? [],
      data: data ?? {},
      repeatInterval: repeatInterval,
    );

    await _manager.scheduleNotification(notification, scheduledTime);
  }

  /// Shows a progress notification
  Future<void> showProgressNotification({
    required String id,
    required String title,
    int progress = 0,
    int maxProgress = 100,
    bool indeterminate = false,
    String? body,
    String channelId = 'progress',
    bool ongoing = true,
  }) async {
    final notification = MCPNotification(
      id: id,
      title: title,
      body: body,
      type: NotificationType.local,
      channelId: channelId,
      priority: NotificationImportance.low,
      progress: progress,
      maxProgress: maxProgress,
      indeterminate: indeterminate,
      ongoing: ongoing,
      autoCancel: false,
    );

    await _manager.showNotification(notification);
  }

  /// Updates a progress notification
  Future<void> updateProgress({
    required String id,
    required int progress,
    String? title,
    String? body,
  }) async {
    final currentNotification = _manager.activeNotifications.firstWhere(
        (n) => n.id == id,
        orElse: () => throw ArgumentError('Notification "$id" not found'));

    final updatedNotification = currentNotification.copyWith(
      progress: progress,
      title: title ?? currentNotification.title,
      body: body ?? currentNotification.body,
    );

    await _manager.showNotification(updatedNotification);
  }

  /// Dismisses a notification
  Future<void> dismissNotification(String id) async {
    await _manager.dismissNotification(id);
  }

  /// Dismisses all notifications
  Future<void> dismissAllNotifications() async {
    await _manager.dismissAllNotifications();
  }

  /// Creates a notification channel
  void createChannel({
    required String id,
    required String name,
    String? description,
    NotificationImportance importance =
        NotificationImportance.defaultImportance,
    bool enableSound = true,
    bool enableVibration = true,
    bool enableLights = true,
  }) {
    final channel = NotificationChannel(
      id: id,
      name: name,
      description: description,
      importance: importance,
      enableSound: enableSound,
      enableVibration: enableVibration,
      enableLights: enableLights,
    );

    _channels[id] = channel;
    _manager.addChannel(channel);

    if (enableDebugMode) {
      _logger.debug('Created channel "$id"');
    }
  }

  /// Registers an action handler
  void registerActionHandler(String actionId, VoidCallback handler) {
    _actionHandlers[actionId] = handler;

    if (enableDebugMode) {
      _logger.debug(
          'Registered action handler for "$actionId"');
    }
  }

  /// Shows a simple info notification
  Future<void> showInfo(String message, {String? title}) async {
    await showNotification(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title ?? 'Information',
      body: message,
      type: NotificationType.inApp,
      priority: NotificationImportance.low,
    );
  }

  /// Shows a success notification
  Future<void> showSuccess(String message, {String? title}) async {
    await showNotification(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title ?? 'Success',
      body: message,
      type: NotificationType.inApp,
      priority: NotificationImportance.defaultImportance,
    );
  }

  /// Shows an error notification
  Future<void> showError(String message, {String? title}) async {
    await showNotification(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title ?? 'Error',
      body: message,
      type: NotificationType.inApp,
      priority: NotificationImportance.high,
    );
  }

  /// Shows a warning notification
  Future<void> showWarning(String message, {String? title}) async {
    await showNotification(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title ?? 'Warning',
      body: message,
      type: NotificationType.inApp,
      priority: NotificationImportance.high,
    );
  }

  @override
  Future<void> onInitialize(Map<String, dynamic> config) async {
    // Setup channels from config
    final channelsConfig = config['channels'] as List<dynamic>?;
    if (channelsConfig != null) {
      for (final channelConfig in channelsConfig) {
        if (channelConfig is Map<String, dynamic>) {
          createChannel(
            id: channelConfig['id'] as String,
            name: channelConfig['name'] as String,
            description: channelConfig['description'] as String?,
            importance:
                _parseImportance(channelConfig['importance'] as String?),
            enableSound: channelConfig['enableSound'] as bool? ?? true,
            enableVibration: channelConfig['enableVibration'] as bool? ?? true,
            enableLights: channelConfig['enableLights'] as bool? ?? true,
          );
        }
      }
    }

    // Initialize the manager
    await _manager.initialize(
      channels: _channels.values.toList(),
      requestPermissions: config['requestPermissions'] as bool? ?? true,
    );

    // Setup notification listener
    _manager.addListener(_handleNotificationEvent);

    if (enableDebugMode) {
      _logger.debug(
          'Initialized with ${_channels.length} channels');
    }
  }

  @override
  Future<void> onDispose() async {
    await _manager.dispose();
    _channels.clear();
    _actionHandlers.clear();
  }

  /// Handles notification events
  void _handleNotificationEvent(
    NotificationEvent event,
    MCPNotification notification,
    String? actionId,
  ) {
    if (enableDebugMode) {
      _logger.debug(
          'Event "$event" for notification "${notification.id}"');
    }

    // Handle action tap
    if (event == NotificationEvent.actionTapped && actionId != null) {
      final handler = _actionHandlers[actionId];
      if (handler != null) {
        handler();
      } else if (enableDebugMode) {
        _logger.debug(
            'No handler registered for action "$actionId"');
      }
    }

    // Handle notification tap
    if (event == NotificationEvent.tapped) {
      // Could navigate to specific screen based on notification data
      final route = notification.data['route'] as String?;
      if (route != null && enableDebugMode) {
        _logger.debug('Would navigate to route "$route"');
      }
    }
  }

  /// Parses notification importance from string
  NotificationImportance _parseImportance(String? importance) {
    switch (importance?.toLowerCase()) {
      case 'low':
        return NotificationImportance.low;
      case 'high':
        return NotificationImportance.high;
      case 'max':
        return NotificationImportance.max;
      default:
        return NotificationImportance.defaultImportance;
    }
  }
}
