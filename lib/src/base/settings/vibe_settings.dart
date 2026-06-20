/// Tool-level settings — distinct from per-bundle / per-project data.
/// Lives at `~/.config/<toolId>/settings.json` so it follows the user
/// across workspaces. Class name kept as `VibeSettings` for backwards
/// compat; semantics are domain-agnostic.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class VibeSettings {
  VibeSettings({
    this.workspaceDir,
    this.mcpServerUrl,
    this.mcpTransport = 'http',
    this.llmApiKey,
    this.llmModel,
    this.llmEndpoint,
    Map<String, String>? llmProviders,
    this.lastProjectPath,
    List<String>? recentProjects,
    this.chatPanelWidth,
    this.propsPanelWidth,
    this.autosaveDelaySec = 5,
    List<String>? recentSearches,
    this.themeMode = 'system',
    this.debugMode = false,
    this.chromiumPath,
    this.maxBrowserContexts,
    this.browserUserAgent,
    this.browserLocale,
    this.browserTimezone,
    this.browserViewportWidth,
    this.browserViewportHeight,
    this.browserRespectRobots,
  }) : llmProviders = Map<String, String>.from(
         llmProviders ?? const <String, String>{},
       ),
       recentProjects = List<String>.from(recentProjects ?? const <String>[]),
       recentSearches = List<String>.from(recentSearches ?? const <String>[]);

  /// Maximum entries kept in [recentProjects]. Older entries fall off
  /// the tail when the list exceeds this on a [bumpRecent].
  static const int recentProjectsLimit = 8;

  /// Default parent directory for new project folders.
  String? workspaceDir;

  /// URL the studio's own MCP server **listens** on (host + port).
  /// The embedded chat client connects to the same URL — one URL
  /// covers both sides. Empty/null = host's hard-coded
  /// `<scheme>://127.0.0.1:<StudioApp.defaultPort>`. CLI `--port`
  /// overrides. Takes effect on next launch (listen socket binds at
  /// boot).
  String? mcpServerUrl;

  /// `http` (Streamable HTTP) or `sse`. `stdio` is rejected by the
  /// runtime elsewhere and not surfaced here.
  String mcpTransport;

  /// API key for the LLM the chat panel drives.
  String? llmApiKey;

  /// Model id (e.g. `claude-opus-4-7`).
  String? llmModel;

  /// Optional base URL override for self-hosted LLM gateways.
  String? llmEndpoint;

  /// Per-provider API keys. Key = provider id (e.g. `anthropic`,
  /// `openai`, `gemini`); value = API key. The chat resolves the
  /// active model's provider from the host catalog and looks up the
  /// matching key here. Falls back to [llmApiKey] when no entry
  /// matches (legacy single-key shells).
  final Map<String, String> llmProviders;

  /// Lookup helper — returns the key for [providerId] or `null` when
  /// none is set. Empty values count as null (let the legacy fallback
  /// take over).
  String? keyFor(String? providerId) {
    if (providerId == null) return null;
    final v = llmProviders[providerId];
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// Absolute path of the project folder that was active in the last
  /// session.
  String? lastProjectPath;

  /// Most-recently-opened project paths in MRU order (head = newest).
  /// Capped at [recentProjectsLimit] entries.
  final List<String> recentProjects;

  /// User-resized chat panel width in logical pixels. Persisted across
  /// runs.
  double? chatPanelWidth;

  /// User-resized properties panel width in logical pixels. Persisted
  /// across runs.
  double? propsPanelWidth;

  /// Idle seconds before the host writes the canonical to disk. `0`
  /// disables autosave (manual ⌘S only). Default `5`. Hosts that
  /// don't track autosave can ignore this field.
  int autosaveDelaySec;

  /// Most-recent search queries (newest first), capped at
  /// [recentSearchesLimit]. Used by the ⌘F overlay to suggest prior
  /// queries when the input is empty.
  final List<String> recentSearches;
  static const int recentSearchesLimit = 10;

  /// Studio chrome theme mode — `'system'` (follow the OS),
  /// `'light'`, or `'dark'`. Wired into the universal-host
  /// When true, the studio runtime mounts every bundle through
  /// `MCPUIRuntime.withInspector(widgetWrapper:)` so each rendered
  /// widget shows up in `studio.renderer.layout_snapshot` and can be
  /// targeted by `studio.ui.tap({elementId:...})`. Off by default —
  /// inspect wrapping doubles the RenderObject count per inner widget,
  /// so production sessions should stay on the fast path. Flip true
  /// when running automated UI tests, recording tutorials, or
  /// debugging from MCP.
  bool debugMode;

  /// `MaterialApp.themeMode` so the chrome flips light/dark with the
  /// user's Settings choice. Defaults to `'system'`.
  String themeMode;

  /// Absolute path to a Chromium/Chrome executable for the host browser
  /// capability (`browser.*` tools). Null/empty = browser disabled (the
  /// tools register but report disabled on call). Hot-swappable — the
  /// lazy engine re-boots when this changes.
  String? chromiumPath;

  /// Max concurrent browser contexts for the host `browser.*` engine
  /// (mcp_browser `BrowserResourceCaps.maxConcurrentContexts`). Null = the
  /// engine default (50). Applied on the next lazy browser boot.
  int? maxBrowserContexts;

  /// Default browser identity applied to every host `browser.*` context
  /// (via the engine's default-spec registry). Null/empty = engine default.
  String? browserUserAgent;
  String? browserLocale;
  String? browserTimezone;
  int? browserViewportWidth;
  int? browserViewportHeight;

  /// Enforce robots.txt on the host browser engine. Null/false = off.
  bool? browserRespectRobots;

  /// Move [path] to the head of [recentProjects] (deduping any earlier
  /// entry) and trim the tail to [recentProjectsLimit]. Also updates
  /// [lastProjectPath]. Caller is responsible for [save].
  void bumpRecent(String path) {
    if (path.isEmpty) return;
    recentProjects.removeWhere((e) => e == path);
    recentProjects.insert(0, path);
    if (recentProjects.length > recentProjectsLimit) {
      recentProjects.removeRange(recentProjectsLimit, recentProjects.length);
    }
    lastProjectPath = path;
  }

  /// Move [query] to the head of [recentSearches]; dedupe earlier
  /// occurrences and trim the tail. Caller is responsible for [save].
  void bumpRecentSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    recentSearches.removeWhere((e) => e == q);
    recentSearches.insert(0, q);
    if (recentSearches.length > recentSearchesLimit) {
      recentSearches.removeRange(recentSearchesLimit, recentSearches.length);
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (workspaceDir != null && workspaceDir!.isNotEmpty)
      'workspaceDir': workspaceDir,
    if (mcpServerUrl != null && mcpServerUrl!.isNotEmpty)
      'mcpServerUrl': mcpServerUrl,
    'mcpTransport': mcpTransport,
    if (llmApiKey != null && llmApiKey!.isNotEmpty) 'llmApiKey': llmApiKey,
    if (llmModel != null && llmModel!.isNotEmpty) 'llmModel': llmModel,
    if (llmEndpoint != null && llmEndpoint!.isNotEmpty)
      'llmEndpoint': llmEndpoint,
    if (llmProviders.isNotEmpty) 'llmProviders': llmProviders,
    if (lastProjectPath != null && lastProjectPath!.isNotEmpty)
      'lastProjectPath': lastProjectPath,
    if (recentProjects.isNotEmpty) 'recentProjects': recentProjects,
    if (chatPanelWidth != null) 'chatPanelWidth': chatPanelWidth,
    if (propsPanelWidth != null) 'propsPanelWidth': propsPanelWidth,
    'autosaveDelaySec': autosaveDelaySec,
    if (recentSearches.isNotEmpty) 'recentSearches': recentSearches,
    'themeMode': themeMode,
    if (debugMode) 'debugMode': debugMode,
    if (chromiumPath != null && chromiumPath!.isNotEmpty)
      'chromiumPath': chromiumPath,
    if (maxBrowserContexts != null) 'maxBrowserContexts': maxBrowserContexts,
    if (browserUserAgent != null && browserUserAgent!.isNotEmpty)
      'browserUserAgent': browserUserAgent,
    if (browserLocale != null && browserLocale!.isNotEmpty)
      'browserLocale': browserLocale,
    if (browserTimezone != null && browserTimezone!.isNotEmpty)
      'browserTimezone': browserTimezone,
    if (browserViewportWidth != null)
      'browserViewportWidth': browserViewportWidth,
    if (browserViewportHeight != null)
      'browserViewportHeight': browserViewportHeight,
    if (browserRespectRobots != null)
      'browserRespectRobots': browserRespectRobots,
  };

  /// Normalize stored `mcpServerUrl` so the Streamable HTTP canonical
  /// `/mcp` endpoint path is present. Older settings files may lack
  /// the path; we transparently append it on read so dialog defaults,
  /// pool keys, and titlebar pill stay consistent.
  static String? _normalizeMcpUrl(String? raw) {
    if (raw == null || raw.isEmpty) return raw;
    final uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    if (uri.path.isEmpty || uri.path == '/') {
      return uri.replace(path: '/mcp').toString();
    }
    return raw;
  }

  static VibeSettings fromJson(Map<String, dynamic> json) => VibeSettings(
    workspaceDir: json['workspaceDir'] as String?,
    mcpServerUrl: _normalizeMcpUrl(json['mcpServerUrl'] as String?),
    mcpTransport: (json['mcpTransport'] as String?) ?? 'http',
    llmApiKey: json['llmApiKey'] as String?,
    llmModel: json['llmModel'] as String?,
    llmEndpoint: json['llmEndpoint'] as String?,
    llmProviders:
        (json['llmProviders'] as Map?)
            ?.map((k, v) => MapEntry('$k', '$v'))
            .cast<String, String>(),
    lastProjectPath: json['lastProjectPath'] as String?,
    recentProjects:
        (json['recentProjects'] as List<dynamic>?)
            ?.whereType<String>()
            .toList(),
    chatPanelWidth: (json['chatPanelWidth'] as num?)?.toDouble(),
    propsPanelWidth: (json['propsPanelWidth'] as num?)?.toDouble(),
    autosaveDelaySec: (json['autosaveDelaySec'] as num?)?.toInt() ?? 5,
    recentSearches:
        (json['recentSearches'] as List<dynamic>?)
            ?.whereType<String>()
            .toList(),
    themeMode: _validThemeMode(json['themeMode']),
    debugMode: json['debugMode'] == true,
    chromiumPath: json['chromiumPath'] as String?,
    maxBrowserContexts: (json['maxBrowserContexts'] as num?)?.toInt(),
    browserUserAgent: json['browserUserAgent'] as String?,
    browserLocale: json['browserLocale'] as String?,
    browserTimezone: json['browserTimezone'] as String?,
    browserViewportWidth: (json['browserViewportWidth'] as num?)?.toInt(),
    browserViewportHeight: (json['browserViewportHeight'] as num?)?.toInt(),
    browserRespectRobots: json['browserRespectRobots'] as bool?,
  );

  /// Accepts `'system'` / `'light'` / `'dark'`; any other value (including
  /// older configs without the field) falls back to `'system'`.
  static String _validThemeMode(Object? raw) {
    if (raw is String && (raw == 'light' || raw == 'dark')) return raw;
    return 'system';
  }

  /// Compose `~/.config/<toolId>/settings.json`. Hosts pass their tool
  /// id (e.g. `'app_builder_vibe'` for backwards-compat with existing
  /// settings). Directory is created on demand by [save].
  static String defaultPath(String toolId) {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return p.join(home, '.config', toolId, 'settings.json');
  }

  /// Load from disk; returns a default-valued instance when the file
  /// is missing or unreadable.
  static Future<VibeSettings> load(String path) async {
    final file = File(path);
    if (!await file.exists()) return VibeSettings();
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map<String, dynamic>) return fromJson(raw);
      return VibeSettings();
    } catch (_) {
      return VibeSettings();
    }
  }

  /// Persist atomically (write to a temp file, rename in place).
  Future<void> save(String path) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
    await tmp.rename(target.path);
  }

  /// Load → [bumpRecent] → save in one shot. Convenience for MCP tool
  /// handlers (`studio.project.open` / `studio.project.new` /
  /// `studio.workspace.adopt`) that need to update MRU after a
  /// successful activation without re-implementing the load+bump+save
  /// pattern at every call site. Silently no-op on empty [path].
  static Future<void> recordRecent({
    required String toolId,
    required String path,
  }) async {
    if (path.isEmpty) return;
    final p = defaultPath(toolId);
    final s = await load(p);
    s.bumpRecent(path);
    await s.save(p);
  }
}
