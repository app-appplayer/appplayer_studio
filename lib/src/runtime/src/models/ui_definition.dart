library ui_definition;

import 'package:flutter_mcp_ui_core/flutter_mcp_ui_core.dart' as core;
import 'app_metadata.dart';

/// Core models for MCP UI DSL.
///
/// This file defines the data structures used by the runtime to parse
/// application / page definitions. The DSL carries a version stamp on the
/// root (resolved via [core.MCPUIDSLVersion]), but the runtime does not
/// gate features on the version today — feature availability is decided
/// by the presence of the relevant block (e.g. `channels`,
/// `permissions`). Version-based negotiation logic will be added when a
/// real breaking-change pivot requires it.

/// Type of UI definition
enum UIDefinitionType {
  /// Complete application with routing
  application,

  /// Single page definition
  page,
}

/// Main UI definition that can be either an application or a page
class UIDefinition {
  final UIDefinitionType type;
  final Map<String, dynamic> properties;
  final Map<String, dynamic>? routes;
  final Map<String, dynamic>? state;
  final Map<String, dynamic>? navigation;
  final Map<String, dynamic>? lifecycle;
  final Map<String, dynamic>? services;
  final Map<String, dynamic>? content;

  /// DSL version tag that appeared in the root `"version"` field,
  /// resolved against [core.MCPUIDSLVersion.supported]. Unknown or
  /// missing stamps collapse to [core.MCPUIDSLVersion.current].
  final String dslVersion;

  /// Permission configuration for client actions.
  final PermissionsConfig? permissions;

  /// Channel definitions for bidirectional communication.
  final Map<String, ChannelConfig>? channels;

  UIDefinition({
    required this.type,
    required this.properties,
    this.routes,
    this.state,
    this.navigation,
    this.lifecycle,
    this.services,
    this.content,
    this.dslVersion = core.MCPUIDSLVersion.current,
    this.permissions,
    this.channels,
  });

  factory UIDefinition.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String?;
    UIDefinitionType type;

    if (typeStr == 'application') {
      type = UIDefinitionType.application;
    } else if (typeStr == 'page') {
      type = UIDefinitionType.page;
    } else {
      // Default to page for backward compatibility
      type = UIDefinitionType.page;
    }

    // For application type, extract top-level properties
    final properties = <String, dynamic>{};
    if (type == UIDefinitionType.application) {
      // Add application-specific properties
      if (json['title'] != null) properties['title'] = json['title'];
      if (json['version'] != null) properties['version'] = json['version'];
      if (json['initialRoute'] != null)
        properties['initialRoute'] = json['initialRoute'];
      if (json['theme'] != null) properties['theme'] = json['theme'];
      // Spec §11 bundle metadata + §11.9 dashboard + §9 templates —
      // passed through verbatim so ApplicationDefinition can materialise
      // DslAppMetadata / DashboardConfig snapshots.
      const passthroughKeys = <String>[
        'id',
        'description',
        'icon',
        'category',
        'publisher',
        'timestamps',
        'screenshots',
        'splash',
        'dashboard',
        'templates',
      ];
      for (final k in passthroughKeys) {
        if (json[k] != null) properties[k] = json[k];
      }
    } else if (type == UIDefinitionType.page) {
      // Add page-specific properties
      if (json['title'] != null) properties['title'] = json['title'];
      if (json['route'] != null) properties['route'] = json['route'];
      if (json['themeOverride'] != null)
        properties['themeOverride'] = json['themeOverride'];
    }

    // Merge with explicit properties if any
    if (json['properties'] != null) {
      properties.addAll(Map<String, dynamic>.from(json['properties'] as Map));
    }

    // Parse v1.1 channels
    Map<String, ChannelConfig>? channels;
    if (json['channels'] != null) {
      channels = {};
      final channelsJson = json['channels'] as Map<String, dynamic>;
      for (final entry in channelsJson.entries) {
        channels[entry.key] =
            ChannelConfig.fromJson(entry.value as Map<String, dynamic>);
      }
    }

    return UIDefinition(
      type: type,
      properties: properties,
      routes: json['routes'] != null
          ? Map<String, dynamic>.from(json['routes'] as Map)
          : null,
      state: json['state'] != null
          ? Map<String, dynamic>.from(json['state'] as Map)
          : (json['initialState'] != null
              ? {
                  'initial':
                      Map<String, dynamic>.from(json['initialState'] as Map)
                }
              : null),
      navigation: json['navigation'] != null
          ? Map<String, dynamic>.from(json['navigation'] as Map)
          : null,
      lifecycle: json['lifecycle'] != null
          ? Map<String, dynamic>.from(json['lifecycle'] as Map)
          : null,
      services: json['services'] != null
          ? Map<String, dynamic>.from(json['services'] as Map)
          : null,
      content: json['content'] != null
          ? Map<String, dynamic>.from(json['content'] as Map)
          : null,
      dslVersion: core.MCPUIDSLVersion.resolve(json['version']),
      permissions: json['permissions'] != null
          ? PermissionsConfig.fromJson(
              json['permissions'] as Map<String, dynamic>)
          : null,
      channels: channels,
    );
  }

  Map<String, dynamic> toJson() {
    Map<String, dynamic>? channelsJson;
    if (channels != null) {
      channelsJson = {};
      for (final entry in channels!.entries) {
        channelsJson[entry.key] = entry.value.toJson();
      }
    }

    return {
      'type': type == UIDefinitionType.application ? 'application' : 'page',
      'version': dslVersion,
      'properties': properties,
      if (routes != null) 'routes': routes,
      if (state != null) 'state': state,
      if (navigation != null) 'navigation': navigation,
      if (lifecycle != null) 'lifecycle': lifecycle,
      if (services != null) 'services': services,
      if (content != null) 'content': content,
      if (permissions != null) 'permissions': permissions!.toJson(),
      if (channelsJson != null) 'channels': channelsJson,
    };
  }
}

/// Application definition according to spec
class ApplicationDefinition extends core.ApplicationConfig {
  final NavigationDefinition? navigationDef;
  final LifecycleDefinition? lifecycleDef;
  final ServicesDefinition? servicesDef;

  /// Bundle metadata (spec §11): icon, description, publisher, etc.
  /// Parsed from the DSL root — null when none of the optional §11
  /// fields are present.
  final DslAppMetadata? metadata;

  /// Spec §11.9 dashboard rendering configuration. Null when the app
  /// does not declare a compact dashboard view; embedders should fall
  /// back to a default card from [metadata].
  final core.DashboardConfig? dashboard;

  /// Templates declared at the application root (spec §9 / §11.9.4)
  /// kept as raw JSON so the renderer's template resolver can read them
  /// during both full and dashboard rendering modes.
  final Map<String, dynamic>? templates;

  ApplicationDefinition({
    required super.title,
    required super.version,
    required super.initialRoute,
    required super.routes,
    super.theme,
    Map<String, dynamic>? initialState,
    this.navigationDef,
    this.lifecycleDef,
    this.servicesDef,
    this.metadata,
    this.dashboard,
    this.templates,
  }) : super(
          state: initialState != null ? {'initial': initialState} : null,
          navigation: navigationDef?.toJson(),
          lifecycle: lifecycleDef?.toJson(),
          services: servicesDef?.toJson(),
        );

  factory ApplicationDefinition.fromUIDefinition(UIDefinition definition) {
    if (definition.type != UIDefinitionType.application) {
      throw ArgumentError('UI definition is not an application type');
    }

    final props = definition.properties;
    final routes = definition.routes;

    if (routes == null || routes.isEmpty) {
      throw ArgumentError('Application must have routes defined');
    }

    return ApplicationDefinition(
      title: props['title'] as String? ?? 'MCP Application',
      version: props['version'] as String? ?? '1.0.0',
      initialRoute: props['initialRoute'] as String? ?? '/',
      routes: Map<String, String>.from(routes),
      theme: props['theme'] as Map<String, dynamic>?,
      initialState: definition.state?['initial'] != null
          ? Map<String, dynamic>.from(definition.state!['initial'] as Map)
          : null,
      navigationDef: definition.navigation != null
          ? NavigationDefinition.fromJson(definition.navigation!)
          : null,
      lifecycleDef: definition.lifecycle != null
          ? LifecycleDefinition.fromJson(definition.lifecycle!)
          : null,
      servicesDef: definition.services != null
          ? ServicesDefinition.fromJson(definition.services!)
          : null,
      metadata: _parseMetadata(props),
      dashboard: props['dashboard'] is Map<String, dynamic>
          ? core.DashboardConfig.fromJson(
              props['dashboard'] as Map<String, dynamic>)
          : null,
      templates: props['templates'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(props['templates'] as Map)
          : null,
    );
  }

  /// Picks the §11 metadata fields off the DSL root. Returns null when
  /// no metadata-bearing field is present so embedders can distinguish
  /// "no metadata declared" from "empty metadata".
  static DslAppMetadata? _parseMetadata(Map<String, dynamic> props) {
    const metadataKeys = <String>{
      'id',
      'description',
      'icon',
      'category',
      'publisher',
      'timestamps',
      'screenshots',
      'splash',
    };
    final hasAny = metadataKeys.any(props.containsKey);
    if (!hasAny) return null;
    return DslAppMetadata.fromJson(props);
  }

  NavigationDefinition? get navigationDefinition => navigationDef;
  LifecycleDefinition? get lifecycleDefinition => lifecycleDef;
  ServicesDefinition? get servicesDefinition => servicesDef;

  @override
  Map<String, dynamic>? get initialState => state?['initial'] != null
      ? Map<String, dynamic>.from(state!['initial'] as Map)
      : null;
}

/// Page definition according to spec
class PageDefinition extends core.PageConfig {
  final LifecycleDefinition? lifecycleDef;

  /// Channels declared at page scope (spec §4.13 + §Channel Lifecycle).
  /// Populated by [fromUIDefinition]; registered into the runtime's
  /// channel manager when the page becomes active and disposed when it
  /// unmounts (if `autoDispose` is true).
  final Map<String, ChannelConfig>? channels;

  PageDefinition({
    super.title,
    super.route,
    required super.content,
    super.themeOverride,
    Map<String, dynamic>? initialState,
    this.lifecycleDef,
    this.channels,
  }) : super(
          state: initialState != null ? {'initial': initialState} : null,
          lifecycle: lifecycleDef?.toJson(),
        );

  factory PageDefinition.fromUIDefinition(UIDefinition definition) {
    if (definition.type != UIDefinitionType.page) {
      throw ArgumentError('UI definition is not a page type');
    }

    final props = definition.properties;
    final content = definition.content;

    if (content == null || content.isEmpty) {
      throw ArgumentError('Page must have content defined');
    }

    return PageDefinition(
      title: props['title'] as String?,
      route: props['route'] as String?,
      content: content,
      themeOverride: props['themeOverride'] as Map<String, dynamic>?,
      initialState: definition.state?['initial'] != null
          ? Map<String, dynamic>.from(definition.state!['initial'] as Map)
          : null,
      lifecycleDef: definition.lifecycle != null
          ? LifecycleDefinition.fromJson(definition.lifecycle!)
          : null,
      channels: definition.channels,
    );
  }

  LifecycleDefinition? get lifecycleDefinition => lifecycleDef;

  @override
  Map<String, dynamic>? get initialState => state?['initial'] != null
      ? Map<String, dynamic>.from(state!['initial'] as Map)
      : null;
}

/// Navigation definition
class NavigationDefinition {
  final String type; // drawer, tabs, bottom
  final List<NavigationItem> items;

  NavigationDefinition({
    required this.type,
    required this.items,
  });

  factory NavigationDefinition.fromJson(Map<String, dynamic> json) {
    // Support both 'items' and 'tabs' for backward compatibility
    final itemsList =
        json['items'] as List<dynamic>? ?? json['tabs'] as List<dynamic>? ?? [];

    return NavigationDefinition(
      type: json['type'] as String? ?? 'drawer',
      items: itemsList
          .map((item) => NavigationItem.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      'items': items.map((item) => item.toJson()).toList(),
    };
  }
}

/// Navigation item
class NavigationItem {
  final String title;
  final String route;
  final String? icon;

  NavigationItem({
    required this.title,
    required this.route,
    this.icon,
  });

  factory NavigationItem.fromJson(Map<String, dynamic> json) {
    return NavigationItem(
      title: (json['title'] ?? json['label']) as String,
      route: json['route'] as String,
      icon: json['icon'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'route': route,
      if (icon != null) 'icon': icon,
    };
  }
}

/// Lifecycle definition
class LifecycleDefinition {
  final List<Map<String, dynamic>>? onInitialize;
  final List<Map<String, dynamic>>? onReady;
  final List<Map<String, dynamic>>? onMount;
  final List<Map<String, dynamic>>? onUnmount;
  final List<Map<String, dynamic>>? onDestroy;
  final List<Map<String, dynamic>>? onEnter;
  final List<Map<String, dynamic>>? onLeave;
  final List<Map<String, dynamic>>? onResume;
  final List<Map<String, dynamic>>? onPause;

  LifecycleDefinition({
    this.onInitialize,
    this.onReady,
    this.onMount,
    this.onUnmount,
    this.onDestroy,
    this.onEnter,
    this.onLeave,
    this.onResume,
    this.onPause,
  });

  factory LifecycleDefinition.fromJson(Map<String, dynamic> json) {
    return LifecycleDefinition(
      onInitialize: _parseActions(json['onInitialize']),
      onReady: _parseActions(json['onReady']),
      onMount: _parseActions(json['onMount']),
      onUnmount: _parseActions(json['onUnmount']),
      onDestroy: _parseActions(json['onDestroy']),
      onEnter: _parseActions(json['onEnter']),
      onLeave: _parseActions(json['onLeave']),
      onResume: _parseActions(json['onResume']),
      onPause: _parseActions(json['onPause']),
    );
  }

  static List<Map<String, dynamic>>? _parseActions(dynamic actions) {
    if (actions == null) return null;
    if (actions is List) {
      return actions.cast<Map<String, dynamic>>();
    }
    return null;
  }

  Map<String, dynamic> toJson() {
    return {
      if (onInitialize != null) 'onInitialize': onInitialize,
      if (onReady != null) 'onReady': onReady,
      if (onMount != null) 'onMount': onMount,
      if (onUnmount != null) 'onUnmount': onUnmount,
      if (onDestroy != null) 'onDestroy': onDestroy,
      if (onEnter != null) 'onEnter': onEnter,
      if (onLeave != null) 'onLeave': onLeave,
      if (onResume != null) 'onResume': onResume,
      if (onPause != null) 'onPause': onPause,
    };
  }
}

/// Services definition
class ServicesDefinition {
  final Map<String, dynamic>? state;
  final Map<String, dynamic>? navigation;
  final Map<String, dynamic>? dialog;
  final Map<String, dynamic>? notification;
  final Map<String, dynamic>? backgroundServices;

  ServicesDefinition({
    this.state,
    this.navigation,
    this.dialog,
    this.notification,
    this.backgroundServices,
  });

  factory ServicesDefinition.fromJson(Map<String, dynamic> json) {
    return ServicesDefinition(
      state: json['state'] as Map<String, dynamic>?,
      navigation: json['navigation'] as Map<String, dynamic>?,
      dialog: json['dialog'] as Map<String, dynamic>?,
      notification: json['notification'] as Map<String, dynamic>?,
      backgroundServices: json['backgroundServices'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (state != null) 'state': state,
      if (navigation != null) 'navigation': navigation,
      if (dialog != null) 'dialog': dialog,
      if (notification != null) 'notification': notification,
      if (backgroundServices != null) 'backgroundServices': backgroundServices,
    };
  }
}

/// Background service definition
class BackgroundServiceDefinition {
  final String id;
  final BackgroundServiceType type;
  final String tool;
  final Map<String, dynamic>? params;
  final int? interval; // for periodic
  final String? schedule; // for scheduled
  final List<String>? events; // for event-based
  final String? event; // single event pattern for event-based
  final Map<String, dynamic>? constraints;
  final bool runInBackground;
  final String priority;
  final String? resultPath; // path to store result in state
  final bool? retryOnError; // retry on error
  final int? retryDelay; // delay between retries in ms
  final bool? stopOnError; // stop service on persistent error

  BackgroundServiceDefinition({
    required this.id,
    required this.type,
    required this.tool,
    this.params,
    this.interval,
    this.schedule,
    this.events,
    this.event,
    this.constraints,
    this.runInBackground = true,
    this.priority = 'normal',
    this.resultPath,
    this.retryOnError,
    this.retryDelay,
    this.stopOnError,
  });

  factory BackgroundServiceDefinition.fromJson(
      String id, Map<String, dynamic> json) {
    // Spec § 1.2.1 ServiceDefinition uses `kind` with values
    // `polling` / `subscription`. The runtime keeps its richer
    // `type` enum (`periodic` / `scheduled` / `continuous` /
    // `event` / `oneoff`) and accepts either field — kind takes
    // priority because it is the spec-canonical name.
    final kindStr = json['kind'] as String?;
    final typeStr = (kindStr ?? json['type']) as String;
    BackgroundServiceType type;

    switch (typeStr) {
      case 'periodic':
      case 'polling':
        type = BackgroundServiceType.periodic;
        break;
      case 'scheduled':
        type = BackgroundServiceType.scheduled;
        break;
      case 'continuous':
      case 'subscription':
        type = BackgroundServiceType.continuous;
        break;
      case 'event':
        type = BackgroundServiceType.event;
        break;
      case 'oneoff':
        type = BackgroundServiceType.oneoff;
        break;
      default:
        throw ArgumentError('Unknown background service kind/type: $typeStr');
    }

    return BackgroundServiceDefinition(
      id: id,
      type: type,
      tool: json['tool'] as String,
      params: json['params'] as Map<String, dynamic>?,
      interval: json['interval'] as int?,
      schedule: json['schedule'] as String?,
      events: (json['events'] as List<dynamic>?)?.cast<String>(),
      event: json['event'] as String?,
      constraints: json['constraints'] as Map<String, dynamic>?,
      runInBackground: json['runInBackground'] as bool? ?? true,
      priority: json['priority'] as String? ?? 'normal',
      resultPath: json['resultPath'] as String?,
      retryOnError: json['retryOnError'] as bool?,
      retryDelay: json['retryDelay'] as int?,
      stopOnError: json['stopOnError'] as bool?,
    );
  }
}

/// Types of background services
enum BackgroundServiceType {
  periodic, // Runs at regular intervals
  scheduled, // Runs at specific times (cron-like)
  continuous, // Runs continuously
  event, // Triggered by events
  oneoff, // Runs once after delay
}

// ============================================================================
// v1.1 Definitions
// ============================================================================

/// v1.1: Permission configuration for client actions
class PermissionsConfig {
  /// File read permission settings
  final FilePermissionConfig? fileRead;

  /// File write permission settings
  final FilePermissionConfig? fileWrite;

  /// HTTP permission settings
  final HttpPermissionConfig? http;

  /// Shell execution permission settings
  final ShellPermissionConfig? shell;

  /// Clipboard permission settings
  final bool? clipboard;

  /// Notification permission settings
  final bool? notification;

  /// System info permission settings
  final bool? systemInfo;

  PermissionsConfig({
    this.fileRead,
    this.fileWrite,
    this.http,
    this.shell,
    this.clipboard,
    this.notification,
    this.systemInfo,
  });

  /// Accept both dotted spec naming (e.g., 'network.http', 'system.clipboard')
  /// and short implementation naming (e.g., 'http', 'clipboard')
  factory PermissionsConfig.fromJson(Map<String, dynamic> json) {
    return PermissionsConfig(
      fileRead: (json['file.read'] ?? json['fileRead']) != null
          ? FilePermissionConfig.fromJson(
              (json['file.read'] ?? json['fileRead']) as Map<String, dynamic>)
          : null,
      fileWrite: (json['file.write'] ?? json['fileWrite']) != null
          ? FilePermissionConfig.fromJson(
              (json['file.write'] ?? json['fileWrite']) as Map<String, dynamic>)
          : null,
      http: (json['network.http'] ?? json['http']) != null
          ? HttpPermissionConfig.fromJson(
              (json['network.http'] ?? json['http']) as Map<String, dynamic>)
          : null,
      shell: (json['system.exec'] ?? json['shell']) != null
          ? ShellPermissionConfig.fromJson(
              (json['system.exec'] ?? json['shell']) as Map<String, dynamic>)
          : null,
      clipboard: (json['system.clipboard'] ?? json['clipboard']) as bool?,
      notification: json['notification'] as bool?,
      systemInfo: (json['system.info'] ?? json['systemInfo']) as bool?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (fileRead != null) 'file.read': fileRead!.toJson(),
      if (fileWrite != null) 'file.write': fileWrite!.toJson(),
      if (http != null) 'http': http!.toJson(),
      if (shell != null) 'shell': shell!.toJson(),
      if (clipboard != null) 'clipboard': clipboard,
      if (notification != null) 'notification': notification,
      if (systemInfo != null) 'systemInfo': systemInfo,
    };
  }
}

/// File permission configuration
class FilePermissionConfig {
  /// Allowed paths for file access
  final List<String>? allowedPaths;

  /// Allowed file extensions
  final List<String>? allowedExtensions;

  /// Maximum file size in bytes (for write)
  final int? maxSize;

  /// Whether to require user confirmation
  final bool? requireConfirmation;

  FilePermissionConfig({
    this.allowedPaths,
    this.allowedExtensions,
    this.maxSize,
    this.requireConfirmation,
  });

  factory FilePermissionConfig.fromJson(Map<String, dynamic> json) {
    return FilePermissionConfig(
      allowedPaths: (json['allowedPaths'] as List<dynamic>?)?.cast<String>(),
      allowedExtensions:
          (json['allowedExtensions'] as List<dynamic>?)?.cast<String>(),
      maxSize: json['maxSize'] as int?,
      requireConfirmation: json['requireConfirmation'] as bool?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (allowedPaths != null) 'allowedPaths': allowedPaths,
      if (allowedExtensions != null) 'allowedExtensions': allowedExtensions,
      if (maxSize != null) 'maxSize': maxSize,
      if (requireConfirmation != null) 'requireConfirmation': requireConfirmation,
    };
  }
}

/// HTTP permission configuration
class HttpPermissionConfig {
  /// Allowed domains for HTTP requests
  final List<String>? allowedDomains;

  /// Blocked domains
  final List<String>? blockedDomains;

  /// Allowed HTTP methods
  final List<String>? allowedMethods;

  /// Whether to block localhost by default
  final bool blockLocalhost;

  HttpPermissionConfig({
    this.allowedDomains,
    this.blockedDomains,
    this.allowedMethods,
    this.blockLocalhost = true,
  });

  factory HttpPermissionConfig.fromJson(Map<String, dynamic> json) {
    return HttpPermissionConfig(
      allowedDomains:
          (json['allowedDomains'] as List<dynamic>?)?.cast<String>(),
      blockedDomains:
          (json['blockedDomains'] as List<dynamic>?)?.cast<String>(),
      allowedMethods:
          (json['allowedMethods'] as List<dynamic>?)?.cast<String>(),
      blockLocalhost: json['blockLocalhost'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (allowedDomains != null) 'allowedDomains': allowedDomains,
      if (blockedDomains != null) 'blockedDomains': blockedDomains,
      if (allowedMethods != null) 'allowedMethods': allowedMethods,
      'blockLocalhost': blockLocalhost,
    };
  }
}

/// Shell execution permission configuration
class ShellPermissionConfig {
  /// Allowed commands (exact match or prefix)
  final List<String>? allowedCommands;

  /// Allowed working directories
  final List<String>? allowedWorkingDirs;

  /// Maximum execution timeout in milliseconds
  final int? timeout;

  /// Whether to require user confirmation
  final bool requireConfirmation;

  /// Denied argument values (PM-13)
  final List<String>? denyArgs;

  /// Allowed argument regex patterns (PM-13)
  final List<String>? allowArgPatterns;

  ShellPermissionConfig({
    this.allowedCommands,
    this.allowedWorkingDirs,
    this.timeout,
    this.requireConfirmation = true,
    this.denyArgs,
    this.allowArgPatterns,
  });

  factory ShellPermissionConfig.fromJson(Map<String, dynamic> json) {
    // Support nested args config: { "args": { "deny": [...], "allowPatterns": [...] } }
    final argsConfig = json['args'] as Map<String, dynamic>?;

    return ShellPermissionConfig(
      allowedCommands:
          (json['allowedCommands'] as List<dynamic>?)?.cast<String>(),
      allowedWorkingDirs:
          (json['allowedWorkingDirs'] as List<dynamic>?)?.cast<String>(),
      timeout: json['timeout'] as int?,
      requireConfirmation: json['requireConfirmation'] as bool? ?? true,
      denyArgs: (argsConfig?['deny'] as List<dynamic>?)?.cast<String>() ??
          (json['denyArgs'] as List<dynamic>?)?.cast<String>(),
      allowArgPatterns:
          (argsConfig?['allowPatterns'] as List<dynamic>?)?.cast<String>() ??
              (json['allowArgPatterns'] as List<dynamic>?)?.cast<String>(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (allowedCommands != null) 'allowedCommands': allowedCommands,
      if (allowedWorkingDirs != null) 'allowedWorkingDirs': allowedWorkingDirs,
      if (timeout != null) 'timeout': timeout,
      'requireConfirmation': requireConfirmation,
      if (denyArgs != null || allowArgPatterns != null)
        'args': {
          if (denyArgs != null) 'deny': denyArgs,
          if (allowArgPatterns != null) 'allowPatterns': allowArgPatterns,
        },
    };
  }
}

/// v1.1: Channel configuration for bidirectional communication
class ChannelConfig {
  /// Channel type (watchFile, watchDirectory, systemMonitor, poll)
  final String type;

  /// Channel-specific parameters
  final Map<String, dynamic>? params;

  /// Action to execute when the channel emits a payload
  /// (spec § 8.6.4 canonical name; legacy bundles emitted `onData`).
  final Map<String, dynamic>? onMessage;

  /// Action to execute on error
  final Map<String, dynamic>? onError;

  /// Action to execute when the channel transitions to `connected`
  /// (spec § 8.6.4).
  final Map<String, dynamic>? onConnect;

  /// Action to execute when the channel transitions to `disconnected`
  /// (spec § 8.6.4 — graceful or error-driven).
  final Map<String, dynamic>? onDisconnect;

  /// Legacy alias of [onMessage]. Older bundles emitted `onData`; new
  /// code reads [onMessage].
  Map<String, dynamic>? get onData => onMessage;

  /// State path to store channel data
  final String? statePath;

  /// Whether channel is initially active (from lifecycle.autoStart or autoStart)
  final bool autoStart;

  /// Whether channel is automatically cleaned up when screen is destroyed
  /// (from lifecycle.autoDispose or autoDispose, default: true per spec)
  final bool autoDispose;

  /// Backpressure configuration for high-frequency channels
  final Map<String, dynamic>? backpressure;

  /// Full lifecycle configuration map (autoStart, autoDispose, restartOnError, etc.)
  final Map<String, dynamic>? lifecycle;

  ChannelConfig({
    required this.type,
    this.params,
    this.onMessage,
    this.onError,
    this.onConnect,
    this.onDisconnect,
    this.statePath,
    this.autoStart = false,
    this.autoDispose = false,
    this.backpressure,
    this.lifecycle,
  });

  factory ChannelConfig.fromJson(Map<String, dynamic> json) {
    // Support both flat format and lifecycle sub-object format (spec §Channel Lifecycle)
    final lifecycle = json['lifecycle'] as Map<String, dynamic>?;
    final autoStart =
        lifecycle?['autoStart'] as bool? ?? json['autoStart'] as bool? ?? false;
    final autoDispose =
        lifecycle?['autoDispose'] as bool? ?? json['autoDispose'] as bool? ?? false;

    // Merge lifecycle fields into params for channel_manager to read (backward compat)
    Map<String, dynamic>? params = json['params'] as Map<String, dynamic>?;
    if (lifecycle != null) {
      params = {...?params, ...lifecycle};
    }

    return ChannelConfig(
      type: json['type'] as String,
      params: params,
      // Spec § 8.6.4 canonical is `onMessage`. Older bundles use `onData`.
      onMessage: (json['onMessage'] ?? json['onData']) as Map<String, dynamic>?,
      onError: json['onError'] as Map<String, dynamic>?,
      onConnect: json['onConnect'] as Map<String, dynamic>?,
      onDisconnect: json['onDisconnect'] as Map<String, dynamic>?,
      statePath: json['statePath'] as String?,
      autoStart: autoStart,
      autoDispose: autoDispose,
      backpressure: json['backpressure'] as Map<String, dynamic>?,
      lifecycle: lifecycle,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      if (params != null) 'params': params,
      if (onMessage != null) 'onMessage': onMessage,
      if (onError != null) 'onError': onError,
      if (onConnect != null) 'onConnect': onConnect,
      if (onDisconnect != null) 'onDisconnect': onDisconnect,
      if (statePath != null) 'statePath': statePath,
      'autoStart': autoStart,
      'autoDispose': autoDispose,
      if (backpressure != null) 'backpressure': backpressure,
      if (lifecycle != null) 'lifecycle': lifecycle,
    };
  }
}
