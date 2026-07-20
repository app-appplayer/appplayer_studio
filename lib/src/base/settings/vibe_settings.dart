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
    Map<String, String>? domainLastProject,
    List<String>? recentProjects,
    this.chatPanelWidth,
    this.propsPanelWidth,
    this.autosaveDelaySec = 5,
    List<String>? recentSearches,
    this.themeMode = 'dark',
    this.debugMode = false,
    this.chromiumPath,
    this.serverShellPath,
    this.maxBrowserContexts,
    this.browserUserAgent,
    this.browserLocale,
    this.browserTimezone,
    this.browserViewportWidth,
    this.browserViewportHeight,
    this.browserRespectRobots,
    this.browserAuthAttachEndpoint,
    this.browserAuthUserDataDir,
    this.discoveryUsb = false,
    this.discoveryMdns = false,
    this.discoveryBle = false,
    this.discoveryDirectory = false,
    this.discoveryAutoConnect = false,
    this.discoveryEnforceSignature = false,
    this.discoveryDirectoryConfig,
  }) : llmProviders = Map<String, String>.from(
         llmProviders ?? const <String, String>{},
       ),
       domainLastProject = Map<String, String>.from(
         domainLastProject ?? const <String, String>{},
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

  /// Model id (e.g. `claude-opus-4-8`).
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
  /// session (host-level).
  String? lastProjectPath;

  /// Per built-in-app last-opened project path — keyed by the built-in's
  /// own id (e.g. `makemind_ops`, `app_builder`). A built-in is one of
  /// several host tabs, each able to hold a different project, so a single
  /// host [lastProjectPath] is not enough. Lives in THIS (per-host) config
  /// store so the debug host and the release host keep independent bindings;
  /// the value is a configurable project path, not a fixed folder.
  final Map<String, String> domainLastProject;

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
  /// user's Settings choice. Defaults to `'dark'`.
  String themeMode;

  /// Absolute path to a Chromium/Chrome executable for the host browser
  /// capability (`browser.*` tools). Null/empty = browser disabled (the
  /// tools register but report disabled on call). Hot-swappable — the
  /// lazy engine re-boots when this changes.
  String? chromiumPath;

  /// Absolute path to the marketplace serving-shell runtime directory
  /// (the checkout/install containing `lib/index.js` — the same Node
  /// shell Cloud Run uses). Powers the App Builder debug panel's
  /// "Cloud Server" variant: pack → boot the REAL shell locally →
  /// connect. Null/empty = the variant card explains how to configure.
  /// (Interim hand-edited settings.json key, like [chromiumPath]; the
  /// marketplace `mcp-serve` CLI will supersede the manual path.)
  String? serverShellPath;

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

  /// Interactive-auth (S2) session source for the headful auth engine.
  /// [browserAuthAttachEndpoint]: CDP endpoint of a user-launched Chrome
  /// (`--remote-debugging-port`) the auth engine attaches to — reuse an
  /// already-signed-in session instead of driving a login in automation
  /// (which SSO providers block). [browserAuthUserDataDir]: a persistent real
  /// profile the auth engine reuses (auto-launch counterpart). Both empty =
  /// default fresh-temp headful spawn.
  String? browserAuthAttachEndpoint;
  String? browserAuthUserDataDir;

  /// Auto-discovery source toggles (settings "Auto discovery" section) —
  /// which nearby-board sources the boot-time sweep scans. All default
  /// OFF: a fresh install never scans on its own. The `mcp.discover_boards`
  /// tool is independent of these (explicit source per call).
  bool discoveryUsb;
  bool discoveryMdns;
  bool discoveryBle;
  bool discoveryDirectory;

  /// Sweep policy: when true, probe-confirmed boards found by the sweep
  /// are auto-connected through the kernel seam (id `board:<manifest id>`).
  /// When false the sweep only reports (log + tool surface).
  bool discoveryAutoConnect;

  /// Manifest signature enforcement (spec 17 §6). When true, a discovered
  /// board is only connected (auto-connect sweep / connectCandidate) if its
  /// probed manifest carries a `trust` block that verifies against a
  /// registered root CA (fail-closed: unsigned / unverified boards are
  /// blocked). Default off — discovery surfaces the evidence either way.
  bool discoveryEnforceSignature;

  /// Organization-directory (LDAP) source config — the vendored
  /// `DirectoryConfig` JSON shape ({host, port?, ssl, bindDN?, password?,
  /// baseDN}). Null/incomplete = the directory source stays idle.
  Map<String, dynamic>? discoveryDirectoryConfig;

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
    if (domainLastProject.isNotEmpty) 'domainLastProject': domainLastProject,
    if (recentProjects.isNotEmpty) 'recentProjects': recentProjects,
    if (chatPanelWidth != null) 'chatPanelWidth': chatPanelWidth,
    if (propsPanelWidth != null) 'propsPanelWidth': propsPanelWidth,
    'autosaveDelaySec': autosaveDelaySec,
    if (recentSearches.isNotEmpty) 'recentSearches': recentSearches,
    'themeMode': themeMode,
    if (debugMode) 'debugMode': debugMode,
    if (chromiumPath != null && chromiumPath!.isNotEmpty)
      'chromiumPath': chromiumPath,
    if (serverShellPath != null && serverShellPath!.isNotEmpty)
      'serverShellPath': serverShellPath,
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
    if (browserAuthAttachEndpoint != null &&
        browserAuthAttachEndpoint!.isNotEmpty)
      'browserAuthAttachEndpoint': browserAuthAttachEndpoint,
    if (browserAuthUserDataDir != null && browserAuthUserDataDir!.isNotEmpty)
      'browserAuthUserDataDir': browserAuthUserDataDir,
    if (discoveryUsb) 'discoveryUsb': true,
    if (discoveryMdns) 'discoveryMdns': true,
    if (discoveryBle) 'discoveryBle': true,
    if (discoveryDirectory) 'discoveryDirectory': true,
    if (discoveryAutoConnect) 'discoveryAutoConnect': true,
    if (discoveryEnforceSignature) 'discoveryEnforceSignature': true,
    if (discoveryDirectoryConfig != null && discoveryDirectoryConfig!.isNotEmpty)
      'discoveryDirectoryConfig': discoveryDirectoryConfig,
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
    domainLastProject:
        (json['domainLastProject'] as Map?)
            ?.map((k, v) => MapEntry('$k', '$v'))
            .cast<String, String>(),
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
    serverShellPath: json['serverShellPath'] as String?,
    maxBrowserContexts: (json['maxBrowserContexts'] as num?)?.toInt(),
    browserUserAgent: json['browserUserAgent'] as String?,
    browserLocale: json['browserLocale'] as String?,
    browserTimezone: json['browserTimezone'] as String?,
    browserViewportWidth: (json['browserViewportWidth'] as num?)?.toInt(),
    browserViewportHeight: (json['browserViewportHeight'] as num?)?.toInt(),
    browserRespectRobots: json['browserRespectRobots'] as bool?,
    browserAuthAttachEndpoint: json['browserAuthAttachEndpoint'] as String?,
    browserAuthUserDataDir: json['browserAuthUserDataDir'] as String?,
    discoveryUsb: json['discoveryUsb'] == true,
    discoveryMdns: json['discoveryMdns'] == true,
    discoveryBle: json['discoveryBle'] == true,
    discoveryDirectory: json['discoveryDirectory'] == true,
    discoveryAutoConnect: json['discoveryAutoConnect'] == true,
    discoveryEnforceSignature: json['discoveryEnforceSignature'] == true,
    discoveryDirectoryConfig:
        (json['discoveryDirectoryConfig'] as Map?)?.map(
          (k, v) => MapEntry('$k', v),
        ),
  );

  /// Accepts `'system'` / `'light'` / `'dark'`; any other value (including
  /// older configs without the field) falls back to `'dark'` — the studio
  /// default theme, so a fresh config / new `--instance` profile boots dark
  /// instead of following the OS. Explicit `'system'` / `'light'` choices
  /// are preserved.
  static String _validThemeMode(Object? raw) {
    if (raw is String && (raw == 'light' || raw == 'dark' || raw == 'system')) {
      return raw;
    }
    return 'dark';
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
