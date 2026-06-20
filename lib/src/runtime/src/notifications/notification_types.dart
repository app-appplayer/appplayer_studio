/// Types of notifications supported by the runtime
enum NotificationType {
  /// Local notifications (shown by the app)
  local,

  /// System notifications (shown by the OS)
  system,

  /// In-app notifications (SnackBar, Dialog, etc.)
  inApp,
}

/// Importance levels for notifications
enum NotificationImportance {
  /// Low importance - minimal interruption
  low,

  /// Default importance - normal notifications
  defaultImportance,

  /// High importance - important notifications
  high,

  /// Max importance - critical alerts
  max,
}

/// Events that can occur with notifications
enum NotificationEvent {
  /// Notification was shown
  shown,

  /// Notification was scheduled
  scheduled,

  /// Notification was dismissed
  dismissed,

  /// Notification was tapped
  tapped,

  /// Notification action was tapped
  actionTapped,
}

/// Represents a notification channel for organizing notifications
class NotificationChannel {
  const NotificationChannel({
    required this.id,
    required this.name,
    this.description,
    this.importance = NotificationImportance.defaultImportance,
    this.enableSound = true,
    this.enableVibration = true,
    this.enableLights = true,
    this.lightColor,
    this.vibrationPattern,
  });

  /// Unique identifier for this channel
  final String id;

  /// Human-readable name for this channel
  final String name;

  /// Optional description of this channel
  final String? description;

  /// Importance level for notifications in this channel
  final NotificationImportance importance;

  /// Whether to play sound for notifications in this channel
  final bool enableSound;

  /// Whether to vibrate for notifications in this channel
  final bool enableVibration;

  /// Whether to show lights for notifications in this channel
  final bool enableLights;

  /// Color of the notification light
  final int? lightColor;

  /// Custom vibration pattern (milliseconds)
  final List<int>? vibrationPattern;

  @override
  String toString() {
    return 'NotificationChannel(id: $id, name: $name, importance: $importance)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NotificationChannel && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Represents an action that can be performed on a notification
class NotificationAction {
  const NotificationAction({
    required this.id,
    required this.title,
    this.icon,
    this.isDestructive = false,
    this.isAuthenticationRequired = false,
  });

  /// Unique identifier for this action
  final String id;

  /// Title displayed for this action
  final String title;

  /// Optional icon for this action
  final String? icon;

  /// Whether this action is destructive (shown in red)
  final bool isDestructive;

  /// Whether authentication is required to perform this action
  final bool isAuthenticationRequired;

  @override
  String toString() {
    return 'NotificationAction(id: $id, title: $title)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NotificationAction && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Represents a notification in the MCP UI Runtime
class MCPNotification {
  const MCPNotification({
    required this.id,
    required this.title,
    this.body,
    this.type = NotificationType.local,
    this.channelId = 'general',
    this.priority = NotificationImportance.defaultImportance,
    this.actions = const [],
    this.data = const {},
    this.sound,
    this.vibrationPattern,
    this.enableLights = true,
    this.lightColor,
    this.largeIcon,
    this.bigPicture,
    this.progress,
    this.maxProgress,
    this.indeterminate = false,
    this.ongoing = false,
    this.autoCancel = true,
    this.scheduledTime,
    this.repeatInterval,
    this.timeoutAfter,
  });

  /// Unique identifier for this notification
  final String id;

  /// Title of the notification
  final String title;

  /// Body text of the notification
  final String? body;

  /// Type of notification
  final NotificationType type;

  /// ID of the notification channel
  final String channelId;

  /// Priority/importance of this notification
  final NotificationImportance priority;

  /// Actions that can be performed on this notification
  final List<NotificationAction> actions;

  /// Additional data associated with this notification
  final Map<String, dynamic> data;

  /// Sound to play (path or identifier)
  final String? sound;

  /// Custom vibration pattern
  final List<int>? vibrationPattern;

  /// Whether to enable notification lights
  final bool enableLights;

  /// Color of the notification light
  final int? lightColor;

  /// Large icon for the notification
  final String? largeIcon;

  /// Big picture for expanded notification
  final String? bigPicture;

  /// Current progress (for progress notifications)
  final int? progress;

  /// Maximum progress value
  final int? maxProgress;

  /// Whether progress is indeterminate
  final bool indeterminate;

  /// Whether notification is ongoing (can't be dismissed by user)
  final bool ongoing;

  /// Whether notification is automatically cancelled when tapped
  final bool autoCancel;

  /// When this notification should be shown (for scheduled notifications)
  final DateTime? scheduledTime;

  /// Interval for repeating notifications
  final Duration? repeatInterval;

  /// How long to show the notification before auto-dismissing
  final Duration? timeoutAfter;

  /// Creates a copy of this notification with modified properties
  MCPNotification copyWith({
    String? id,
    String? title,
    String? body,
    NotificationType? type,
    String? channelId,
    NotificationImportance? priority,
    List<NotificationAction>? actions,
    Map<String, dynamic>? data,
    String? sound,
    List<int>? vibrationPattern,
    bool? enableLights,
    int? lightColor,
    String? largeIcon,
    String? bigPicture,
    int? progress,
    int? maxProgress,
    bool? indeterminate,
    bool? ongoing,
    bool? autoCancel,
    DateTime? scheduledTime,
    Duration? repeatInterval,
    Duration? timeoutAfter,
  }) {
    return MCPNotification(
      id: id ?? this.id,
      title: title ?? this.title,
      body: body ?? this.body,
      type: type ?? this.type,
      channelId: channelId ?? this.channelId,
      priority: priority ?? this.priority,
      actions: actions ?? this.actions,
      data: data ?? this.data,
      sound: sound ?? this.sound,
      vibrationPattern: vibrationPattern ?? this.vibrationPattern,
      enableLights: enableLights ?? this.enableLights,
      lightColor: lightColor ?? this.lightColor,
      largeIcon: largeIcon ?? this.largeIcon,
      bigPicture: bigPicture ?? this.bigPicture,
      progress: progress ?? this.progress,
      maxProgress: maxProgress ?? this.maxProgress,
      indeterminate: indeterminate ?? this.indeterminate,
      ongoing: ongoing ?? this.ongoing,
      autoCancel: autoCancel ?? this.autoCancel,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      repeatInterval: repeatInterval ?? this.repeatInterval,
      timeoutAfter: timeoutAfter ?? this.timeoutAfter,
    );
  }

  /// Creates a notification from a JSON configuration
  factory MCPNotification.fromJson(Map<String, dynamic> json) {
    return MCPNotification(
      id: json['id'] as String,
      title: json['title'] as String,
      body: json['body'] as String?,
      type: _parseNotificationType(json['type'] as String?),
      channelId: json['channelId'] as String? ?? 'general',
      priority: _parseNotificationImportance(json['priority'] as String?),
      actions: (json['actions'] as List<dynamic>?)
              ?.map((action) => NotificationActionJson.fromJson(
                  action as Map<String, dynamic>))
              .toList() ??
          [],
      data: json['data'] as Map<String, dynamic>? ?? {},
      sound: json['sound'] as String?,
      vibrationPattern:
          (json['vibrationPattern'] as List<dynamic>?)?.cast<int>(),
      enableLights: json['enableLights'] as bool? ?? true,
      lightColor: json['lightColor'] as int?,
      largeIcon: json['largeIcon'] as String?,
      bigPicture: json['bigPicture'] as String?,
      progress: json['progress'] as int?,
      maxProgress: json['maxProgress'] as int?,
      indeterminate: json['indeterminate'] as bool? ?? false,
      ongoing: json['ongoing'] as bool? ?? false,
      autoCancel: json['autoCancel'] as bool? ?? true,
      scheduledTime: json['scheduledTime'] != null
          ? DateTime.parse(json['scheduledTime'] as String)
          : null,
      repeatInterval: json['repeatInterval'] != null
          ? Duration(milliseconds: json['repeatInterval'] as int)
          : null,
      timeoutAfter: json['timeoutAfter'] != null
          ? Duration(milliseconds: json['timeoutAfter'] as int)
          : null,
    );
  }

  /// Converts this notification to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'body': body,
      'type': type.name,
      'channelId': channelId,
      'priority': priority.name,
      'actions': actions.map((action) => action.toJson()).toList(),
      'data': data,
      'sound': sound,
      'vibrationPattern': vibrationPattern,
      'enableLights': enableLights,
      'lightColor': lightColor,
      'largeIcon': largeIcon,
      'bigPicture': bigPicture,
      'progress': progress,
      'maxProgress': maxProgress,
      'indeterminate': indeterminate,
      'ongoing': ongoing,
      'autoCancel': autoCancel,
      'scheduledTime': scheduledTime?.toIso8601String(),
      'repeatInterval': repeatInterval?.inMilliseconds,
      'timeoutAfter': timeoutAfter?.inMilliseconds,
    };
  }

  static NotificationType _parseNotificationType(String? type) {
    switch (type?.toLowerCase()) {
      case 'system':
        return NotificationType.system;
      case 'inapp':
      case 'in_app':
        return NotificationType.inApp;
      default:
        return NotificationType.local;
    }
  }

  static NotificationImportance _parseNotificationImportance(
      String? importance) {
    switch (importance?.toLowerCase()) {
      case 'low':
        return NotificationImportance.low;
      case 'high':
        return NotificationImportance.high;
      case 'max':
      case 'maximum':
        return NotificationImportance.max;
      default:
        return NotificationImportance.defaultImportance;
    }
  }

  @override
  String toString() {
    return 'MCPNotification(id: $id, title: $title, type: $type)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is MCPNotification && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Extension methods for NotificationAction
extension NotificationActionJson on NotificationAction {
  /// Creates a notification action from JSON
  static NotificationAction fromJson(Map<String, dynamic> json) {
    return NotificationAction(
      id: json['id'] as String,
      title: json['title'] as String,
      icon: json['icon'] as String?,
      isDestructive: json['isDestructive'] as bool? ?? false,
      isAuthenticationRequired:
          json['isAuthenticationRequired'] as bool? ?? false,
    );
  }

  /// Converts this action to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'icon': icon,
      'isDestructive': isDestructive,
      'isAuthenticationRequired': isAuthenticationRequired,
    };
  }
}

/// Callback type for notification events
typedef NotificationListener = void Function(
  NotificationEvent event,
  MCPNotification notification,
  String? actionId,
);
