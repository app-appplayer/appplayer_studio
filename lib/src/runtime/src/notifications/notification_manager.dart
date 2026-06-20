import 'package:flutter/foundation.dart';
import 'notification_types.dart';
import '../utils/mcp_logger.dart';

/// Manages local and system notifications for the MCP UI Runtime
class NotificationManager {
  NotificationManager({
    this.enableDebugMode = kDebugMode,
  }) : _logger =
            MCPLogger('NotificationManager', enableLogging: enableDebugMode);

  final bool enableDebugMode;
  final MCPLogger _logger;

  bool _isInitialized = false;
  final Map<String, MCPNotification> _activeNotifications = {};
  final List<NotificationListener> _listeners = [];
  final List<NotificationChannel> _channels = [];

  /// Gets whether the notification manager is initialized
  bool get isInitialized => _isInitialized;

  /// Gets all active notifications
  List<MCPNotification> get activeNotifications =>
      _activeNotifications.values.toList();

  /// Gets all notification channels
  List<NotificationChannel> get channels => List.unmodifiable(_channels);

  /// Initializes the notification manager
  Future<void> initialize({
    List<NotificationChannel>? channels,
    bool requestPermissions = true,
  }) async {
    if (_isInitialized) {
      throw StateError('NotificationManager is already initialized');
    }

    // Setup default channels
    if (channels != null) {
      _channels.addAll(channels);
    } else {
      _setupDefaultChannels();
    }

    // Request permissions if needed
    if (requestPermissions) {
      await _requestPermissions();
    }

    _isInitialized = true;

    _logger.info('Initialized with ${_channels.length} channels');
  }

  /// Shows a local notification
  Future<void> showNotification(MCPNotification notification) async {
    if (!_isInitialized) {
      throw StateError(
          'NotificationManager must be initialized before showing notifications');
    }

    try {
      // Store the notification
      _activeNotifications[notification.id] = notification;

      // Show based on type
      switch (notification.type) {
        case NotificationType.local:
          await _showLocalNotification(notification);
          break;
        case NotificationType.system:
          await _showSystemNotification(notification);
          break;
        case NotificationType.inApp:
          await _showInAppNotification(notification);
          break;
      }

      // Notify listeners
      _notifyListeners(NotificationEvent.shown, notification);

      _logger.debug('Showed notification "${notification.id}"');
    } catch (error) {
      _logger.error('Error showing notification "${notification.id}"', error);
      rethrow;
    }
  }

  /// Schedules a notification for future delivery
  Future<void> scheduleNotification(
    MCPNotification notification,
    DateTime scheduledTime,
  ) async {
    if (!_isInitialized) {
      throw StateError(
          'NotificationManager must be initialized before scheduling notifications');
    }

    try {
      // Store the notification with scheduled time
      final scheduledNotification = notification.copyWith(
        scheduledTime: scheduledTime,
      );
      _activeNotifications[notification.id] = scheduledNotification;

      // Schedule based on type
      switch (notification.type) {
        case NotificationType.local:
        case NotificationType.system:
          await _scheduleSystemNotification(scheduledNotification);
          break;
        case NotificationType.inApp:
          // In-app notifications are handled differently
          await _scheduleInAppNotification(scheduledNotification);
          break;
      }

      // Notify listeners
      _notifyListeners(NotificationEvent.scheduled, scheduledNotification);

      if (enableDebugMode) {
        _logger.debug(
            'Scheduled notification "${notification.id}" for $scheduledTime');
      }
    } catch (error) {
      if (enableDebugMode) {
        _logger.error(
            'Error scheduling notification "${notification.id}": $error');
      }
      rethrow;
    }
  }

  /// Dismisses a notification
  Future<void> dismissNotification(String notificationId) async {
    final notification = _activeNotifications.remove(notificationId);
    if (notification != null) {
      try {
        await _dismissSystemNotification(notificationId);

        // Notify listeners
        _notifyListeners(NotificationEvent.dismissed, notification);

        if (enableDebugMode) {
          _logger.debug(
              'Dismissed notification "$notificationId"');
        }
      } catch (error) {
        if (enableDebugMode) {
          _logger.error(
              'Error dismissing notification "$notificationId": $error');
        }
      }
    }
  }

  /// Dismisses all notifications
  Future<void> dismissAllNotifications() async {
    final notificationIds = _activeNotifications.keys.toList();

    for (final id in notificationIds) {
      await dismissNotification(id);
    }

    if (enableDebugMode) {
      _logger.debug('Dismissed all notifications');
    }
  }

  /// Adds a notification channel
  void addChannel(NotificationChannel channel) {
    _channels.add(channel);

    if (enableDebugMode) {
      _logger.debug('Added channel "${channel.id}"');
    }
  }

  /// Gets a notification channel by ID
  NotificationChannel? getChannel(String channelId) {
    try {
      return _channels.firstWhere((channel) => channel.id == channelId);
    } catch (error) {
      return null;
    }
  }

  /// Adds a notification listener
  void addListener(NotificationListener listener) {
    _listeners.add(listener);
  }

  /// Removes a notification listener
  void removeListener(NotificationListener listener) {
    _listeners.remove(listener);
  }

  /// Handles notification action (when user taps action button)
  Future<void> handleNotificationAction(
    String notificationId,
    String actionId,
  ) async {
    final notification = _activeNotifications[notificationId];
    if (notification != null) {
      // Verify action exists
      notification.actions.firstWhere(
        (action) => action.id == actionId,
        orElse: () => throw ArgumentError('Action "$actionId" not found'),
      );

      // Notify listeners
      _notifyListeners(NotificationEvent.actionTapped, notification, actionId);

      if (enableDebugMode) {
        _logger.debug(
            'Handled action "$actionId" for notification "$notificationId"');
      }
    }
  }

  /// Handles notification tap (when user taps the notification itself)
  Future<void> handleNotificationTap(String notificationId) async {
    final notification = _activeNotifications[notificationId];
    if (notification != null) {
      // Notify listeners
      _notifyListeners(NotificationEvent.tapped, notification);

      if (enableDebugMode) {
        _logger.debug(
            'Handled tap for notification "$notificationId"');
      }
    }
  }

  /// Sets up default notification channels
  void _setupDefaultChannels() {
    _channels.addAll([
      const NotificationChannel(
        id: 'general',
        name: 'General Notifications',
        description: 'General application notifications',
        importance: NotificationImportance.defaultImportance,
      ),
      const NotificationChannel(
        id: 'alerts',
        name: 'Alert Notifications',
        description: 'Important alerts and warnings',
        importance: NotificationImportance.high,
      ),
      const NotificationChannel(
        id: 'updates',
        name: 'Updates',
        description: 'Application and content updates',
        importance: NotificationImportance.low,
      ),
    ]);
  }

  /// Requests notification permissions from the system
  Future<bool> _requestPermissions() async {
    try {
      // This would integrate with actual permission APIs
      // For now, return true as a placeholder
      if (enableDebugMode) {
        _logger.debug('Requested notification permissions');
      }
      return true;
    } catch (error) {
      if (enableDebugMode) {
        _logger.error('Error requesting permissions: $error');
      }
      return false;
    }
  }

  /// Shows a local notification
  Future<void> _showLocalNotification(MCPNotification notification) async {
    // Implementation would integrate with local notification plugin
    if (enableDebugMode) {
      _logger.debug(
          'Showing local notification: ${notification.title}');
    }
  }

  /// Shows a system notification
  Future<void> _showSystemNotification(MCPNotification notification) async {
    // Implementation would integrate with system notification APIs
    if (enableDebugMode) {
      _logger.debug(
          'Showing system notification: ${notification.title}');
    }
  }

  /// Shows an in-app notification (like SnackBar)
  Future<void> _showInAppNotification(MCPNotification notification) async {
    // Implementation would integrate with in-app notification UI
    if (enableDebugMode) {
      _logger.debug(
          'Showing in-app notification: ${notification.title}');
    }
  }

  /// Schedules a system notification
  Future<void> _scheduleSystemNotification(MCPNotification notification) async {
    // Implementation would integrate with system scheduling APIs
    if (enableDebugMode) {
      _logger.debug(
          'Scheduled system notification: ${notification.title}');
    }
  }

  /// Schedules an in-app notification
  Future<void> _scheduleInAppNotification(MCPNotification notification) async {
    if (notification.scheduledTime == null) return;

    final delay = notification.scheduledTime!.difference(DateTime.now());
    if (delay.isNegative) return;

    Future.delayed(delay, () async {
      if (_activeNotifications.containsKey(notification.id)) {
        await _showInAppNotification(notification);
      }
    });
  }

  /// Dismisses a system notification
  Future<void> _dismissSystemNotification(String notificationId) async {
    // Implementation would integrate with system notification APIs
    if (enableDebugMode) {
      _logger.debug(
          'Dismissed system notification: $notificationId');
    }
  }

  /// Notifies all listeners of notification events
  void _notifyListeners(
    NotificationEvent event,
    MCPNotification notification, [
    String? actionId,
  ]) {
    for (final listener in _listeners) {
      try {
        listener(event, notification, actionId);
      } catch (error) {
        if (enableDebugMode) {
          _logger.error('Error in listener: $error');
        }
      }
    }
  }

  /// Disposes the notification manager and cleans up resources
  Future<void> dispose() async {
    await dismissAllNotifications();
    _listeners.clear();
    _channels.clear();
    _isInitialized = false;

    if (enableDebugMode) {
      _logger.debug('Disposed');
    }
  }
}
