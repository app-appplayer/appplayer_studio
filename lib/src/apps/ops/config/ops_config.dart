import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart' show systemWorkspaceSlot;
import 'ops_error.dart';

/// Root configuration for makemind Ops.
///
/// Loaded from `~/.makemind-ops/config.yaml` (or platform appSupportDirectory).
/// See `docs/03_DDD/core-config.md` for the design specification.
class OpsConfig {
  OpsConfig({
    required this.version,
    required this.appName,
    required this.activeWorkspace,
    required this.workspacesRoot,
    required this.llm,
    required this.mcp,
    required this.browser,
    required this.storage,
    required this.channel,
    required this.security,
    this.systemAgent = const SystemAgentSettings.defaults(),
    this.themeMode = 'dark',
    this.loadedFromDisk = true,
  });

  /// Default product name. Overridden by `appName` in config.yaml so each
  /// install can rebrand the AppBar / window title.
  static const String defaultAppName = 'makemind Ops';

  /// Allowed [themeMode] values.
  static const List<String> themeModes = ['system', 'light', 'dark'];

  final String version;
  final String appName;
  final String activeWorkspace;
  final String workspacesRoot;
  final LlmSettings llm;
  final McpSettings mcp;
  final BrowserSettings browser;
  final StorageSettings storage;
  final ChannelSettings channel;
  final SecuritySettings security;

  /// System administrator agent — runs the chat pane and orchestrates Ops
  /// MCP tool invocations on the user's behalf.
  final SystemAgentSettings systemAgent;

  /// `'system' | 'light' | 'dark'`. Resolved by [opsThemeModeProvider]
  /// into a [ThemeMode] for the MaterialApp.
  final String themeMode;

  /// True iff this instance was parsed from an existing `config.yaml`.
  /// A brand-new install (no config file) returns false so the shell can
  /// route to the first-run wizard; an already-configured install with an
  /// empty `activeWorkspace` is NOT a first run — the ShellPage handles
  /// the empty-workspace state on its own.
  final bool loadedFromDisk;

  bool get isFirstRun => !loadedFromDisk;

  static OpsConfig firstRun() => OpsConfig(
    version: DateTime.now().toIso8601String(),
    appName: defaultAppName,
    activeWorkspace: '',
    workspacesRoot: './workspaces',
    llm: const LlmSettings.empty(),
    mcp: const McpSettings.defaults(),
    browser: const BrowserSettings.defaults(),
    storage: const StorageSettings.defaults(),
    channel: const ChannelSettings.empty(),
    security: const SecuritySettings.defaults(),
    loadedFromDisk: false,
  );

  static Future<OpsConfig> load({String? path}) async {
    final resolved = path ?? _defaultPath();
    final file = File(resolved);
    if (!await file.exists()) return firstRun();

    final String raw;
    try {
      raw = await file.readAsString();
    } on FileSystemException catch (e) {
      throw OpsError(
        code: 'E1001',
        message: 'Failed to read config file: $resolved',
        detail: e.message,
      );
    }

    final Object? yaml;
    try {
      yaml = loadYaml(raw);
    } on YamlException catch (e) {
      throw OpsError(
        code: 'E1002',
        message: 'Invalid YAML',
        detail: e.toString(),
      );
    }
    if (yaml is! YamlMap) {
      throw OpsError(code: 'E1002', message: 'Config root must be a map');
    }

    final cfg = OpsConfig(
      version: (yaml['version'] as String?) ?? DateTime.now().toIso8601String(),
      appName:
          ((yaml['appName'] as String?)?.trim().isNotEmpty ?? false)
              ? (yaml['appName'] as String).trim()
              : defaultAppName,
      activeWorkspace: (yaml['activeWorkspace'] as String?) ?? '',
      workspacesRoot: (yaml['workspacesRoot'] as String?) ?? './workspaces',
      llm: LlmSettings.fromYaml(yaml['llm']),
      mcp: McpSettings.fromYaml(yaml['mcp']),
      browser: BrowserSettings.fromYaml(yaml['browser']),
      storage: StorageSettings.fromYaml(yaml['storage']),
      channel: ChannelSettings.fromYaml(yaml['channel']),
      security: SecuritySettings.fromYaml(yaml['security']),
      systemAgent: SystemAgentSettings.fromYaml(yaml['systemAgent']),
      themeMode: _coerceThemeMode(yaml['themeMode']),
    );

    cfg._validate();
    return cfg;
  }

  static String _coerceThemeMode(Object? raw) {
    final s = (raw as String?)?.trim().toLowerCase();
    return themeModes.contains(s) ? s! : 'dark';
  }

  void _validate() {
    final errors = <String>[];
    if (activeWorkspace.isEmpty) {
      // first-run state; skip deep validation
      return;
    }
    // The reserved `_system` slot (ws_paths.systemWorkspaceSlot) is the
    // runtime default active workspace when no project workspace is bound;
    // it is a first-class workspace identifier (free-form runtime dir, not a
    // bundle) so it must be accepted at rest alongside `<type>/<slug>` ids.
    if (activeWorkspace != systemWorkspaceSlot &&
        !activeWorkspace.contains('/')) {
      errors.add('activeWorkspace must be "<type>/<slug>" or "_system"');
    }
    // LLM provider is optional — external MCP-only deployments have no
    // internal provider, and the app still works for tool-call routing.
    // Validate only if the user opted in with a non-empty defaultProvider.
    if (llm.defaultProvider.isNotEmpty) {
      if (!llm.providers.containsKey(llm.defaultProvider)) {
        errors.add(
          'llm.defaultProvider "${llm.defaultProvider}" not in providers',
        );
      }
    }
    if (errors.isNotEmpty) {
      throw OpsError(
        code: 'E1002',
        message: 'Config validation failed',
        detail: errors.join('; '),
      );
    }
  }

  static String _defaultPath() {
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/.makemind-ops/config.yaml';
  }

  Map<String, dynamic> toJson() => {
    'version': version,
    'appName': appName,
    'activeWorkspace': activeWorkspace,
    'workspacesRoot': workspacesRoot,
    'llm': llm.toJson(),
    'mcp': mcp.toJson(),
    'browser': browser.toJson(),
    'storage': storage.toJson(),
    'channel': channel.toJson(),
    'security': security.toJson(),
    'systemAgent': systemAgent.toJson(),
    'themeMode': themeMode,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Serialize to YAML and write atomically. Secrets referenced via
  /// `${ENV}` / `kc:alias` / `file:path` are preserved verbatim — actual
  /// values live in keychain / encrypted files, not this config.
  Future<void> save({String? path}) async {
    final resolved = path ?? _defaultPath();
    final file = File(resolved);
    await file.parent.create(recursive: true);
    final yaml = _toYaml(toJson(), indent: 0);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(yaml, flush: true);
    await tmp.rename(file.path);
  }

  static String _toYaml(Object? node, {required int indent}) {
    final buf = StringBuffer();
    if (node is Map) {
      node.forEach((k, v) {
        buf.write('${'  ' * indent}$k:');
        if (v is Map && v.isEmpty) {
          buf.writeln(' {}');
        } else if (v is List && v.isEmpty) {
          buf.writeln(' []');
        } else if (v is Map || v is List) {
          buf.writeln();
          buf.write(_toYaml(v, indent: indent + 1));
        } else {
          buf.writeln(' ${_yamlScalar(v)}');
        }
      });
    } else if (node is List) {
      for (final item in node) {
        if (item is Map || item is List) {
          buf.writeln('${'  ' * indent}-');
          buf.write(_toYaml(item, indent: indent + 1));
        } else {
          buf.writeln('${'  ' * indent}- ${_yamlScalar(item)}');
        }
      }
    } else {
      buf.writeln('${'  ' * indent}${_yamlScalar(node)}');
    }
    return buf.toString();
  }

  static String _yamlScalar(Object? v) {
    if (v == null) return 'null';
    if (v is bool || v is num) return v.toString();
    final s = v.toString();
    // Quote strings that contain YAML-significant chars or look like refs.
    if (s.isEmpty ||
        s.contains(':') ||
        s.contains('#') ||
        s.contains('\n') ||
        s.startsWith(' ') ||
        s.endsWith(' ') ||
        RegExp(r'^[\[\]\{\}\,\&\*\?\|\>\!\%\@\`]').hasMatch(s)) {
      return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    }
    return s;
  }
}

class LlmSettings {
  const LlmSettings({
    required this.defaultProvider,
    required this.providers,
    this.timeoutSeconds = 60,
  });
  const LlmSettings.empty()
    : defaultProvider = '',
      providers = const {},
      timeoutSeconds = 60;

  final String defaultProvider;
  final Map<String, LlmProviderSettings> providers;
  final int timeoutSeconds;

  static LlmSettings fromYaml(Object? y) {
    if (y is! YamlMap) return const LlmSettings.empty();
    final provs = <String, LlmProviderSettings>{};
    final rawProvs = y['providers'];
    if (rawProvs is YamlMap) {
      for (final entry in rawProvs.entries) {
        provs[entry.key as String] = LlmProviderSettings.fromYaml(entry.value);
      }
    }
    return LlmSettings(
      defaultProvider: (y['defaultProvider'] as String?) ?? '',
      providers: provs,
      timeoutSeconds: (y['timeoutSeconds'] as int?) ?? 60,
    );
  }

  Map<String, dynamic> toJson() => {
    'defaultProvider': defaultProvider,
    'providers': {for (final e in providers.entries) e.key: e.value.toJson()},
    'timeoutSeconds': timeoutSeconds,
  };
}

class LlmProviderSettings {
  const LlmProviderSettings({
    required this.apiKey,
    required this.model,
    this.maxTokens = 4096,
  });
  final String apiKey;
  final String model;
  final int maxTokens;

  static LlmProviderSettings fromYaml(Object? y) {
    if (y is! YamlMap) {
      return const LlmProviderSettings(apiKey: '', model: '');
    }
    return LlmProviderSettings(
      apiKey: (y['apiKey'] as String?) ?? '',
      model: (y['model'] as String?) ?? '',
      maxTokens: (y['maxTokens'] as int?) ?? 4096,
    );
  }

  Map<String, dynamic> toJson() => {
    'apiKey': apiKey,
    'model': model,
    'maxTokens': maxTokens,
  };
}

class McpSettings {
  const McpSettings({required this.inbound, required this.outbound});
  const McpSettings.defaults()
    : inbound = const InboundMcpSettings(),
      outbound = const [];

  final InboundMcpSettings inbound;
  final List<OutboundMcpServer> outbound;

  static McpSettings fromYaml(Object? y) {
    if (y is! YamlMap) return const McpSettings.defaults();
    final out = <OutboundMcpServer>[];
    final rawOut = y['outbound'];
    if (rawOut is YamlMap && rawOut['servers'] is YamlList) {
      for (final s in rawOut['servers'] as YamlList) {
        out.add(OutboundMcpServer.fromYaml(s));
      }
    }
    return McpSettings(
      inbound: InboundMcpSettings.fromYaml(y['inbound']),
      outbound: out,
    );
  }

  Map<String, dynamic> toJson() => {
    'inbound': inbound.toJson(),
    'outbound': {'servers': outbound.map((s) => s.toJson()).toList()},
  };
}

/// Network MCP transports the app will `listen` on.
///
/// `stdio` is intentionally absent here: it activates automatically when the
/// app is spawned as a subprocess by an MCP client (e.g. Claude Desktop) —
/// no config needed. The two fields below control the two *network*
/// transports, each independently toggleable with its own port.
class InboundMcpSettings {
  const InboundMcpSettings({
    this.sseEnabled = true,
    this.streamableHttpEnabled = true,
    this.ssePort = 7123,
    this.streamableHttpPort = 7124,
  });

  final bool sseEnabled;
  final bool streamableHttpEnabled;
  final int ssePort;
  final int streamableHttpPort;

  static InboundMcpSettings fromYaml(Object? y) {
    if (y is! YamlMap) return const InboundMcpSettings();
    // Backward compat: legacy `transport: sse` / `transport: stdio` single-value form.
    final legacy = y['transport'] as String?;
    final hasNew =
        y['sseEnabled'] != null ||
        y['streamableHttpEnabled'] != null ||
        y['streamableHttpPort'] != null;
    if (!hasNew && legacy != null) {
      return InboundMcpSettings(
        sseEnabled: legacy == 'sse',
        streamableHttpEnabled: false,
        ssePort: (y['ssePort'] as int?) ?? 7123,
      );
    }
    return InboundMcpSettings(
      sseEnabled: (y['sseEnabled'] as bool?) ?? true,
      streamableHttpEnabled: (y['streamableHttpEnabled'] as bool?) ?? true,
      ssePort: (y['ssePort'] as int?) ?? 7123,
      streamableHttpPort: (y['streamableHttpPort'] as int?) ?? 7124,
    );
  }

  Map<String, dynamic> toJson() => {
    'sseEnabled': sseEnabled,
    'streamableHttpEnabled': streamableHttpEnabled,
    'ssePort': ssePort,
    'streamableHttpPort': streamableHttpPort,
  };
}

class OutboundMcpServer {
  const OutboundMcpServer({
    required this.id,
    required this.transport,
    this.command,
    this.url,
    this.auth,
  });
  final String id;
  final String transport; // stdio | sse
  final String? command;
  final String? url;
  final Map<String, Object?>? auth;

  static OutboundMcpServer fromYaml(Object? y) {
    if (y is! YamlMap) {
      return const OutboundMcpServer(id: '', transport: 'stdio');
    }
    return OutboundMcpServer(
      id: (y['id'] as String?) ?? '',
      transport: (y['transport'] as String?) ?? 'stdio',
      command: y['command'] as String?,
      url: y['url'] as String?,
      auth:
          y['auth'] is YamlMap
              ? Map<String, Object?>.from(y['auth'] as YamlMap)
              : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'transport': transport,
    if (command != null) 'command': command,
    if (url != null) 'url': url,
    if (auth != null) 'auth': auth,
  };
}

class BrowserSettings {
  const BrowserSettings({
    this.chromiumPath,
    this.userAgent,
    this.defaultViewport,
    this.downloadDir,
    this.maxConcurrentContexts = 4,
    this.respectRobots = true,
  });
  const BrowserSettings.defaults()
    : chromiumPath = null,
      userAgent = null,
      defaultViewport = null,
      downloadDir = null,
      maxConcurrentContexts = 4,
      respectRobots = true;

  final String? chromiumPath;
  final String? userAgent;
  final Map<String, int>? defaultViewport;
  final String? downloadDir;
  final int maxConcurrentContexts;
  final bool respectRobots;

  static BrowserSettings fromYaml(Object? y) {
    if (y is! YamlMap) return const BrowserSettings.defaults();
    Map<String, int>? viewport;
    if (y['defaultViewport'] is YamlMap) {
      final v = y['defaultViewport'] as YamlMap;
      viewport = {
        'width': (v['width'] as int?) ?? 1440,
        'height': (v['height'] as int?) ?? 900,
      };
    }
    return BrowserSettings(
      chromiumPath: y['chromiumPath'] as String?,
      userAgent: y['userAgent'] as String?,
      defaultViewport: viewport,
      downloadDir: y['downloadDir'] as String?,
      maxConcurrentContexts: (y['maxConcurrentContexts'] as int?) ?? 4,
      respectRobots: (y['respectRobots'] as bool?) ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    if (chromiumPath != null) 'chromiumPath': chromiumPath,
    if (userAgent != null) 'userAgent': userAgent,
    if (defaultViewport != null) 'defaultViewport': defaultViewport,
    if (downloadDir != null) 'downloadDir': downloadDir,
    'maxConcurrentContexts': maxConcurrentContexts,
    'respectRobots': respectRobots,
  };
}

class StorageSettings {
  const StorageSettings({
    required this.localKvPath,
    this.backupIntervalHours = 24,
    this.retentionDays = 90,
  });
  const StorageSettings.defaults()
    : localKvPath = '',
      backupIntervalHours = 24,
      retentionDays = 90;

  final String localKvPath;
  final int backupIntervalHours;
  final int retentionDays;

  static StorageSettings fromYaml(Object? y) {
    if (y is! YamlMap) return const StorageSettings.defaults();
    return StorageSettings(
      localKvPath: (y['localKvPath'] as String?) ?? '',
      backupIntervalHours: (y['backupIntervalHours'] as int?) ?? 24,
      retentionDays: (y['retentionDays'] as int?) ?? 90,
    );
  }

  Map<String, dynamic> toJson() => {
    'localKvPath': localKvPath,
    'backupIntervalHours': backupIntervalHours,
    'retentionDays': retentionDays,
  };
}

class ChannelSettings {
  const ChannelSettings({required this.providers});
  const ChannelSettings.empty() : providers = const {};
  final Map<String, Map<String, Object?>> providers;

  static ChannelSettings fromYaml(Object? y) {
    if (y is! YamlMap) return const ChannelSettings.empty();
    final provs = <String, Map<String, Object?>>{};
    final rawProvs = y['providers'];
    if (rawProvs is YamlMap) {
      for (final entry in rawProvs.entries) {
        provs[entry.key as String] =
            entry.value is YamlMap
                ? Map<String, Object?>.from(entry.value as YamlMap)
                : <String, Object?>{};
      }
    }
    return ChannelSettings(providers: provs);
  }

  Map<String, dynamic> toJson() => {'providers': providers};
}

class SecuritySettings {
  const SecuritySettings({
    required this.secretsBackend,
    this.aesKeyRef,
    this.auditRetentionDays = 365,
  });
  const SecuritySettings.defaults()
    : secretsBackend = 'keychain',
      aesKeyRef = null,
      auditRetentionDays = 365;

  final String secretsBackend; // keychain | aes-file
  final String? aesKeyRef;
  final int auditRetentionDays;

  static SecuritySettings fromYaml(Object? y) {
    if (y is! YamlMap) return const SecuritySettings.defaults();
    return SecuritySettings(
      secretsBackend: (y['secretsBackend'] as String?) ?? 'keychain',
      aesKeyRef: y['aesKeyRef'] as String?,
      auditRetentionDays: (y['auditRetentionDays'] as int?) ?? 365,
    );
  }

  Map<String, dynamic> toJson() => {
    'secretsBackend': secretsBackend,
    if (aesKeyRef != null) 'aesKeyRef': aesKeyRef,
    'auditRetentionDays': auditRetentionDays,
  };
}

/// System administrator agent — runs the chat pane and orchestrates Ops
/// MCP tool invocations. Lives in the reserved `_system` workspace under
/// the id `_ops_admin` (override per install via this config).
class SystemAgentSettings {
  const SystemAgentSettings({
    this.id = '_ops_admin',
    this.displayName = 'Ops Admin',
    this.workspaceId = '_system',
    this.providerOverride,
    this.modelOverride,
    this.systemPrompt,
    this.enabled = true,
    this.toolCallingEnabled = true,
  });

  const SystemAgentSettings.defaults() : this();

  final String id;
  final String displayName;
  final String workspaceId;

  /// Optional provider override (defaults to `LlmSettings.defaultProvider`).
  final String? providerOverride;

  /// Optional model override (defaults to the chosen provider's model).
  final String? modelOverride;

  /// System prompt — when null, a built-in Ops administrator prompt is
  /// supplied at boot.
  final String? systemPrompt;

  /// Disable to skip system agent creation entirely (chat pane falls back
  /// to direct LlmPort calls).
  final bool enabled;

  /// When true, the chat pane forwards Ops MCP tool definitions to the
  /// system agent via `agents.ask(... tools: ...)`.
  final bool toolCallingEnabled;

  static SystemAgentSettings fromYaml(Object? y) {
    if (y is! YamlMap) return const SystemAgentSettings.defaults();
    return SystemAgentSettings(
      id: (y['id'] as String?) ?? '_ops_admin',
      displayName: (y['displayName'] as String?) ?? 'Ops Admin',
      workspaceId: (y['workspaceId'] as String?) ?? '_system',
      providerOverride: y['providerOverride'] as String?,
      modelOverride: y['modelOverride'] as String?,
      systemPrompt: y['systemPrompt'] as String?,
      enabled: (y['enabled'] as bool?) ?? true,
      toolCallingEnabled: (y['toolCallingEnabled'] as bool?) ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'workspaceId': workspaceId,
    if (providerOverride != null) 'providerOverride': providerOverride,
    if (modelOverride != null) 'modelOverride': modelOverride,
    if (systemPrompt != null) 'systemPrompt': systemPrompt,
    'enabled': enabled,
    'toolCallingEnabled': toolCallingEnabled,
  };
}
