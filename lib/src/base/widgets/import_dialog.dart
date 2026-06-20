// Selective import dialog — appears after the user picks a source
// `.mbd` for the Import flow. Lets them either replace the target
// channel wholesale (current behaviour) or pick individual pages /
// templates / dashboard from the source bundle and merge them into
// the target. The full-bundle path stays the file-copy import; the
// selective path translates the picks into JSON-Patch ops applied
// against the canonical so the user can undo / save normally.

import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';

import 'package:appplayer_studio/base.dart';

/// Snapshot of a source `.mbd` directory's selectable content. Built
/// by [peekMbd] before the picker dialog opens so the UI can list
/// real ids + flag collisions against the target channel.
class MbdPeek {
  MbdPeek({
    required this.pages,
    required this.templates,
    required this.dashboard,
    required this.theme,
    this.assets = const <String, Map<String, dynamic>>{},
    this.navigation,
    this.sourcePath,
  });

  /// `<id, pageJson>` from `pages/<id>.json`.
  final Map<String, Map<String, dynamic>> pages;

  /// `<id, templateJson>` from `app.json#templates`.
  final Map<String, Map<String, dynamic>> templates;

  /// Inline dashboard map from `app.json#dashboard`, or null when the
  /// source bundle has no dashboard surface.
  final Map<String, dynamic>? dashboard;

  /// `app.json#theme` raw map, fed into [mcpThemeToFlutter] so the
  /// preview slot wraps the rendered widget tree in the source
  /// bundle's `ColorScheme` / typography.
  final Map<String, dynamic>? theme;

  /// `<id, assetEntry>` from `manifest.assets.assets[]`. Each entry is
  /// the mcp_bundle Asset shape (`id`, `path` / `contentRef`, `type`,
  /// `mimeType`, `hash`, `size`). File-backed entries also need their
  /// `<bundle>/assets/<path>` bytes copied during import; ref-only
  /// entries (Material / URL / data:) carry only the meta.
  final Map<String, Map<String, dynamic>> assets;

  /// Source's `ui.navigation` block (NavigationConfig). Null when
  /// the bundle ships without chrome.
  final Map<String, dynamic>? navigation;

  /// Absolute path to the source `.mbd` directory. Used by the
  /// importer to resolve file-backed asset paths so the bytes can be
  /// copied into the target channel's `assets/`. Null when the peek
  /// was constructed without a directory (e.g., from a packed mcpb).
  final String? sourcePath;

  bool get isEmpty =>
      pages.isEmpty &&
      templates.isEmpty &&
      dashboard == null &&
      assets.isEmpty &&
      navigation == null &&
      theme == null;
}

/// User's choice from the import picker. `everything` defers to the
/// existing whole-bundle replace path. `partial` carries the explicit
/// pick lists + conflict policy.
class ImportSelection {
  ImportSelection.everything()
    : isPartial = false,
      pages = const <String>{},
      templates = const <String>{},
      assets = const <String>{},
      includeDashboard = false,
      includeTheme = false,
      includeNavigation = false,
      replaceOnConflict = true;

  ImportSelection.partial({
    required this.pages,
    required this.templates,
    required this.includeDashboard,
    required this.replaceOnConflict,
    this.assets = const <String>{},
    this.includeTheme = false,
    this.includeNavigation = false,
  }) : isPartial = true;

  final bool isPartial;
  final Set<String> pages;
  final Set<String> templates;
  final bool includeDashboard;

  /// Asset ids picked for merge. File-backed assets get both their
  /// `manifest.assets[]` entry and their `assets/<path>` bytes
  /// copied; ref-only entries (Material / URL / data:) carry only
  /// the meta into the target.
  final Set<String> assets;

  /// Whether to overwrite the target's `/ui/theme`. False = keep
  /// target's tokens. Theme is global so import is "all or nothing"
  /// — partial token merge is left for explicit set_property edits.
  final bool includeTheme;

  /// Whether to overwrite the target's `/ui/navigation` chrome
  /// definition. Same all-or-nothing rule as theme.
  final bool includeNavigation;

  /// True ⇒ overwrite items that already exist in the target.
  /// False ⇒ skip those items, only add the new ones.
  final bool replaceOnConflict;

  bool get hasAnyPick =>
      pages.isNotEmpty ||
      templates.isNotEmpty ||
      assets.isNotEmpty ||
      includeDashboard ||
      includeTheme ||
      includeNavigation;
}

/// Read a source `.mbd` directory and pull out its selectable pages,
/// templates, and dashboard map. Returns null when the path isn't a
/// loadable bundle (no manifest etc).
/// Right-side preview pane shown next to the scope picker. Resolves
/// the row currently focused (`page:<id>` / `template:<id>` /
/// `dashboard`) to its source + target JSON pair, runs a coarse
/// line-set diff, and renders the result as colored mono text.
/// "Coarse" means we don't align lines structurally — added /
/// removed are decided by membership of trimmed lines in the other
/// side. Good enough to read what's changing for typical bundle JSON.
class _DiffPane extends StatefulWidget {
  const _DiffPane({
    required this.previewKey,
    required this.peek,
    required this.existingPages,
    required this.existingTemplates,
    required this.existingDashboard,
    this.targetTheme,
  });
  final String? previewKey;
  final MbdPeek peek;
  final Map<String, Map<String, dynamic>> existingPages;
  final Map<String, Map<String, dynamic>> existingTemplates;
  final Map<String, dynamic>? existingDashboard;
  final Map<String, dynamic>? targetTheme;

  @override
  State<_DiffPane> createState() => _DiffPaneState();
}

class _DiffPaneState extends State<_DiffPane> {
  /// Resolve the previewKey to a (sourcePage, targetPage, badge,
  /// theme) tuple. The two page maps are wrapped to a `{type: page,
  /// content: ...}` shape so [_RenderedPreview] can hand them to a
  /// runtime regardless of whether the underlying entry was a real
  /// page, a template body, or the dashboard content.
  ({Map<String, dynamic>? source, Map<String, dynamic>? target, String badge})
  _resolve() {
    final key = widget.previewKey;
    if (key == null) {
      return (source: null, target: null, badge: '');
    }
    Map<String, dynamic>? wrap(Map<String, dynamic>? raw) {
      if (raw == null) return null;
      if (raw['type'] == 'page' && raw['content'] is Map) {
        return Map<String, dynamic>.from(raw);
      }
      final content = raw['content'];
      if (content is Map) {
        return <String, dynamic>{
          'type': 'page',
          'content': Map<String, dynamic>.from(content),
        };
      }
      return <String, dynamic>{'type': 'page', 'content': raw};
    }

    if (key.startsWith('page:')) {
      final id = key.substring(5);
      return (
        source: wrap(widget.peek.pages[id]),
        target: wrap(widget.existingPages[id]),
        badge:
            widget.existingPages[id] == null ? 'NEW PAGE — $id' : 'PAGE — $id',
      );
    }
    if (key.startsWith('template:')) {
      final id = key.substring(9);
      return (
        source: wrap(widget.peek.templates[id]),
        target: wrap(widget.existingTemplates[id]),
        badge:
            widget.existingTemplates[id] == null
                ? 'NEW TEMPLATE — $id'
                : 'TEMPLATE — $id',
      );
    }
    if (key == 'dashboard') {
      return (
        source: wrap(widget.peek.dashboard),
        target: wrap(widget.existingDashboard),
        badge: widget.existingDashboard == null ? 'NEW DASHBOARD' : 'DASHBOARD',
      );
    }
    return (source: null, target: null, badge: '');
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    if (widget.previewKey == null) {
      return Container(
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          border: Border.all(color: c.borderSubtle),
        ),
        child: Center(
          child: Text(
            'Tap an item to preview the change',
            style: vibeMono(size: 11, color: c.textTertiary),
          ),
        ),
      );
    }
    final r = _resolve();
    final hasTarget = r.target != null;
    final subtitle =
        !hasTarget ? 'new — no existing target' : 'replaces existing';
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: VibeTokens.space3,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.borderSubtle)),
            ),
            child: Row(
              children: <Widget>[
                Text(
                  r.badge,
                  style: vibeMono(
                    size: 11,
                    weight: FontWeight.w500,
                    color: c.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  subtitle,
                  style: vibeMono(size: 10, color: c.textTertiary),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(VibeTokens.space2),
              child:
                  hasTarget
                      ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Expanded(
                            child: _PreviewSlot(
                              key: ValueKey<String>(
                                '${widget.previewKey}:incoming',
                              ),
                              label: 'INCOMING',
                              data: r.source,
                              color: c.mint,
                              theme: widget.peek.theme,
                            ),
                          ),
                          const SizedBox(width: VibeTokens.space2),
                          Expanded(
                            child: _PreviewSlot(
                              key: ValueKey<String>(
                                '${widget.previewKey}:current',
                              ),
                              label: 'CURRENT',
                              data: r.target,
                              color: c.textTertiary,
                              theme: widget.targetTheme,
                            ),
                          ),
                        ],
                      )
                      : _PreviewSlot(
                        key: ValueKey<String>('${widget.previewKey}:incoming'),
                        label: 'INCOMING',
                        data: r.source,
                        color: c.mint,
                        theme: widget.peek.theme,
                      ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Single small render slot — labelled (INCOMING / CURRENT), framed,
/// holds a [_RenderedPreview] for the page-shaped data passed in.
class _PreviewSlot extends StatelessWidget {
  const _PreviewSlot({
    super.key,
    required this.label,
    required this.data,
    required this.color,
    this.theme,
  });
  final String label;
  final Map<String, dynamic>? data;
  final Color color;
  final Map<String, dynamic>? theme;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            label,
            style: vibeMono(size: 9, weight: FontWeight.w500, color: color),
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
              border: Border.all(color: c.borderSubtle),
            ),
            clipBehavior: Clip.hardEdge,
            child:
                data == null
                    ? Center(
                      child: Text(
                        '—',
                        style: vibeMono(size: 11, color: c.textTertiary),
                      ),
                    )
                    : _RenderedPreview(data: data!, theme: theme),
          ),
        ),
      ],
    );
  }
}

/// Mini render of a single page-shaped definition. Spins up a
/// dedicated [MCPUIRuntime], wraps the data as a single-route
/// application, and scales the result down to fit the available
/// box.
///
/// Important: we deliberately DO NOT call `runtime.dispose()` here.
/// `MCPUIRuntime.destroy()` resets package-level singletons
/// (`ThemeManager.instance.reset()`, `WidgetCache.instance.clear()`,
/// `BindingEngine.clearStaticCaches()`, `NavigationService.instance
/// .onDispose()`), which would corrupt the editor preview's still-
/// live runtime. The runtime widget's own `State.dispose()` cleans
/// up local listeners cleanly; the engine itself simply gets garbage-
/// collected once no widget references remain. AppPlayer follows the
/// same leak-and-GC pattern when juggling multiple apps.
class _RenderedPreview extends StatefulWidget {
  const _RenderedPreview({required this.data, this.theme});
  final Map<String, dynamic> data;

  /// MCP-UI theme JSON for the bundle this preview belongs to.
  /// Locally converted via [mcpThemeToFlutter] and applied as a
  /// [Theme] wrap so the preview matches the bundle's intended
  /// look — without touching the runtime's singleton ThemeManager.
  final Map<String, dynamic>? theme;

  @override
  State<_RenderedPreview> createState() => _RenderedPreviewState();
}

class _RenderedPreviewState extends State<_RenderedPreview> {
  late Future<MCPUIRuntime?> _future;

  @override
  void initState() {
    super.initState();
    _future = _build();
  }

  @override
  void didUpdateWidget(covariant _RenderedPreview old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data)) {
      _future = _build();
    }
  }

  Future<MCPUIRuntime?> _build() async {
    try {
      final runtime = MCPUIRuntime(enableDebugMode: false);
      // Initialize as a Page (not Application). The runtime's
      // application path returns a `MaterialApp` with the shared
      // `NavigationService.instance.navigatorKey` — and the host
      // editor's runtime is already using that GlobalKey, so two
      // MaterialApps fighting over it triggers a render layout
      // error on every dialog open. The page path returns a plain
      // widget tree via `renderer.renderPage()` — no MaterialApp,
      // no navigatorKey, no host conflict.
      await runtime.initialize(Map<String, dynamic>.from(widget.data));
      return runtime;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return FutureBuilder<MCPUIRuntime?>(
      future: _future,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Center(
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.2,
                color: c.textTertiary,
              ),
            ),
          );
        }
        final runtime = snap.data;
        if (runtime == null) {
          return Center(
            child: Text(
              'preview unavailable',
              style: vibeMono(size: 10, color: c.textTertiary),
            ),
          );
        }
        // Render at a known logical size (phone-portrait) and scale
        // down to whatever the slot affords. The runtime now returns
        // a plain widget tree (page-only init), so wrapping with
        // Theme + MediaQuery + Material here gives it the expected
        // ambient context. The Theme uses the bundle's converted
        // [ThemeData] so colour scheme + typography match the real
        // app, instead of falling back to Flutter's defaults.
        const logicalW = 390.0;
        const logicalH = 700.0;
        final flutterTheme = mcpThemeToFlutter(widget.theme);
        return FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: logicalW,
            height: logicalH,
            child: MediaQuery(
              data: MediaQuery.of(ctx).copyWith(
                size: const Size(logicalW, logicalH),
                platformBrightness: flutterTheme.brightness,
              ),
              child: Theme(
                data: flutterTheme,
                child: Material(
                  color: flutterTheme.scaffoldBackgroundColor,
                  child: Builder(
                    builder: (innerCtx) {
                      try {
                        return runtime.buildUI(context: innerCtx);
                      } catch (_) {
                        return Center(
                          child: Text(
                            'preview render failed',
                            style: vibeMono(size: 10, color: c.textTertiary),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Compact pill button used by the import dialog's quick-select
/// toolbar. Disabled state is visual-only — onTap is the source of
/// truth for whether the action runs.
Widget _quickActionButton({
  required String label,
  required bool enabled,
  required VoidCallback onTap,
}) {
  final c = VibeTokens.color;
  return InkWell(
    onTap: enabled ? onTap : null,
    borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
    child: Container(
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space2,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        border: Border.all(color: c.borderDefault),
      ),
      child: Text(
        label,
        style: vibeMono(
          size: 10,
          color: enabled ? c.textPrimary : c.textTertiary,
        ),
      ),
    ),
  );
}

/// Walk an arbitrary JSON subtree and collect every `bundle://<id>`
/// asset reference appearing in any string value. Used by the import
/// dialog to auto-include the assets that picked pages / templates
/// depend on — without this, partial imports leave the target with
/// dangling refs (`bundle://logo` pointing at no logo).
Set<String> _collectAssetRefs(dynamic node) {
  final out = <String>{};
  final re = RegExp(r'bundle://([\w\-]+)');
  void scan(dynamic n) {
    if (n is String) {
      for (final m in re.allMatches(n)) {
        final id = m.group(1);
        if (id != null && id.isNotEmpty) out.add(id);
      }
    } else if (n is Map) {
      for (final v in n.values) {
        scan(v);
      }
    } else if (n is List) {
      for (final v in n) {
        scan(v);
      }
    }
  }

  scan(node);
  return out;
}

/// Inline placeholder rendered inside an empty dialog section. Lets
/// the user see that the category exists in the import surface even
/// when the source bundle has nothing to offer for it (e.g. importing
/// a pages-only bundle still shows the Templates / Dashboard / Assets
/// headings, just with this stub underneath).
Widget _emptySectionPlaceholder() {
  final c = VibeTokens.color;
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: VibeTokens.space2,
      vertical: VibeTokens.space2,
    ),
    child: Text(
      '— none in source —',
      style: vibeMono(size: 11, color: c.textTertiary),
    ),
  );
}

Future<MbdPeek?> peekMbd(String path) async {
  final fs = FileWorkspaceFsPort();
  final json = await fs.readJson(path);
  if (json == null) return null;
  final ui = json['ui'];
  Map<String, Map<String, dynamic>> mapOfMaps(dynamic m) {
    if (m is! Map) return <String, Map<String, dynamic>>{};
    final out = <String, Map<String, dynamic>>{};
    for (final e in m.entries) {
      final v = e.value;
      if (v is Map) {
        out[e.key.toString()] = Map<String, dynamic>.from(v);
      }
    }
    return out;
  }

  // Pull manifest.assets.assets[] into an id-keyed map so the dialog
  // can render the same row pattern it uses for pages / templates.
  final manifest = json['manifest'];
  final assets = <String, Map<String, dynamic>>{};
  if (manifest is Map) {
    final section = manifest['assets'];
    if (section is Map) {
      final entries = section['assets'];
      if (entries is List) {
        for (final raw in entries) {
          if (raw is! Map) continue;
          final id = raw['id'];
          if (id is! String || id.isEmpty) continue;
          assets[id] = Map<String, dynamic>.from(raw);
        }
      }
    }
  }

  if (ui is! Map) {
    return MbdPeek(
      pages: const <String, Map<String, dynamic>>{},
      templates: const <String, Map<String, dynamic>>{},
      dashboard: null,
      theme: null,
      assets: assets,
      sourcePath: path,
    );
  }
  return MbdPeek(
    pages: mapOfMaps(ui['pages']),
    templates: mapOfMaps(ui['templates']),
    dashboard:
        ui['dashboard'] is Map
            ? Map<String, dynamic>.from(ui['dashboard'] as Map)
            : null,
    theme:
        ui['theme'] is Map
            ? Map<String, dynamic>.from(ui['theme'] as Map)
            : null,
    navigation:
        ui['navigation'] is Map
            ? Map<String, dynamic>.from(ui['navigation'] as Map)
            : null,
    assets: assets,
    sourcePath: path,
  );
}

/// Tiny MCP-UI-spec theme JSON → Flutter [ThemeData] converter. The
/// runtime ships its own (`McpUiThemeBuilder`) but it's package-
/// private + routes everything through the singleton ThemeManager,
/// which would clash with the host editor's runtime if we touched
/// it. Vibe's preview wrap only needs M3 colour scheme + a few
/// typography roles to look "right enough" — that maps cleanly to
/// `ColorScheme` here without singleton involvement.
ThemeData mcpThemeToFlutter(Map<String, dynamic>? theme) {
  Color? parseColor(dynamic v) {
    if (v is! String) return null;
    final s = v.trim();
    if (!s.startsWith('#')) return null;
    final hex = s.substring(1);
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }

  final mode = theme?['mode'];
  final isDark = mode == 'dark';
  final brightness = isDark ? Brightness.dark : Brightness.light;
  if (theme == null) {
    return ThemeData(brightness: brightness, useMaterial3: true);
  }
  final colors = theme['colors'];
  Color? c(String k) => colors is Map ? parseColor(colors[k]) : null;
  final primary = c('primary');
  final scheme = ColorScheme.fromSeed(
    seedColor: primary ?? (isDark ? Colors.blueGrey : Colors.blue),
    brightness: brightness,
  ).copyWith(
    primary: primary,
    onPrimary: c('onPrimary'),
    secondary: c('secondary'),
    onSecondary: c('onSecondary'),
    surface: c('surface') ?? c('background'),
    onSurface: c('onSurface') ?? c('onBackground'),
    error: c('error'),
    onError: c('onError'),
  );
  return ThemeData(
    brightness: brightness,
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: c('background') ?? c('surface'),
  );
}

/// Show the scope picker dialog. Returns null when the user cancels;
/// otherwise the [ImportSelection] describes what should land in the
/// target channel.
Future<ImportSelection?> showImportSelectionDialog({
  required BuildContext context,
  required String channelLabel,
  required String sourcePath,
  required MbdPeek peek,
  required Set<String> existingPageIds,
  required Set<String> existingTemplateIds,
  required bool targetHasDashboard,
  Map<String, Map<String, dynamic>> existingPages =
      const <String, Map<String, dynamic>>{},
  Map<String, Map<String, dynamic>> existingTemplates =
      const <String, Map<String, dynamic>>{},
  Map<String, dynamic>? existingDashboard,
  Map<String, dynamic>? targetTheme,
}) {
  final c = VibeTokens.colorOf(context);
  bool partial = false;
  final pickedPages = <String>{};
  final pickedTemplates = <String>{};
  final pickedAssets = <String>{};
  // Asset ids the user explicitly *unchecked* even though one of
  // their picked pages / templates references them. Honoured when
  // computing the auto-included set so the picker doesn't fight the
  // user — once they say "no" to an asset, repeated page picks
  // shouldn't keep re-checking it.
  final excludedAutoAssets = <String>{};
  bool includeDashboard = false;
  bool includeTheme = false;
  bool includeNavigation = false;
  bool replaceOnConflict = true;
  // Tracks the row currently expanded in the right-side diff pane.
  // Format: `'page:<id>'` / `'template:<id>'` / `'dashboard'`. Updates
  // on tap regardless of whether the row is selected — preview is
  // independent of the include-in-import decision.
  String? previewKey;
  return showDialog<ImportSelection?>(
    context: context,
    builder:
        (ctx) => Dialog(
          backgroundColor: c.surface2,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          child: StatefulBuilder(
            builder: (ctx, setLocal) {
              void setPartial(bool v) {
                setLocal(() => partial = v);
              }

              Widget radioRow({
                required bool value,
                required String title,
                String? subtitle,
                VoidCallback? onTap,
              }) {
                return InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          value
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 16,
                          color: value ? c.mint : c.textSecondary,
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                title,
                                style: TextStyle(
                                  fontFamily: VibeTokens.fontSans,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: c.textPrimary,
                                ),
                              ),
                              if (subtitle != null) ...<Widget>[
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  style: vibeMono(
                                    size: 10,
                                    color: c.textTertiary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              Widget itemRow({
                required bool checked,
                required String label,
                required bool collides,
                required VoidCallback onTap,
              }) {
                return InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: VibeTokens.space2,
                      vertical: 4,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          checked
                              ? Icons.check_box_outlined
                              : Icons.check_box_outline_blank,
                          size: 14,
                          color: checked ? c.mint : c.textSecondary,
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        Expanded(
                          child: Text(
                            label,
                            style: vibeMono(size: 11, color: c.textPrimary),
                          ),
                        ),
                        if (collides)
                          Text(
                            'exists',
                            style: vibeMono(size: 10, color: c.amber),
                          ),
                      ],
                    ),
                  ),
                );
              }

              Widget section(String title, List<Widget> children) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 8, bottom: 4),
                      child: Text(
                        title,
                        style: vibeMono(
                          size: 10,
                          weight: FontWeight.w500,
                          color: c.textTertiary,
                        ),
                      ),
                    ),
                    ...children,
                  ],
                );
              }

              final pickEnabled = partial;
              final pageIds = peek.pages.keys.toList()..sort();
              final templateIds = peek.templates.keys.toList()..sort();
              final assetIds = peek.assets.keys.toList()..sort();
              final hasTheme = peek.theme != null;
              final hasNavigation = peek.navigation != null;
              // Compute the auto-included asset set on every rebuild by
              // re-scanning currently-picked pages / templates. The
              // result is union'd with the user's explicit picks for
              // dispatch; assets the user actively rejected
              // (`excludedAutoAssets`) stay off regardless of refs.
              final autoAssets = <String>{};
              if (peek.assets.isNotEmpty) {
                for (final id in pickedPages) {
                  final page = peek.pages[id];
                  if (page != null) autoAssets.addAll(_collectAssetRefs(page));
                }
                for (final id in pickedTemplates) {
                  final tpl = peek.templates[id];
                  if (tpl != null) autoAssets.addAll(_collectAssetRefs(tpl));
                }
                if (includeDashboard && peek.dashboard != null) {
                  autoAssets.addAll(_collectAssetRefs(peek.dashboard));
                }
                autoAssets.removeWhere(excludedAutoAssets.contains);
                autoAssets.removeWhere((id) => !peek.assets.containsKey(id));
              }
              final effectiveAssets = <String>{...pickedAssets, ...autoAssets};
              final hasAny =
                  pickedPages.isNotEmpty ||
                  pickedTemplates.isNotEmpty ||
                  effectiveAssets.isNotEmpty ||
                  includeDashboard ||
                  includeTheme ||
                  includeNavigation;
              // Build the per-item rows so the same widgets can live
              // either in the single-column compact layout or in the
              // side-by-side layout that pairs them with a diff pane.
              // Quick-select toolbar — small buttons to bulk-toggle
              // the most common slices without scrolling and clicking
              // each row. Each button only enables/disables; doesn't
              // touch unrelated sections.
              Widget quickSelectBar() {
                if (!pickEnabled) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: VibeTokens.space2,
                    vertical: VibeTokens.space1,
                  ),
                  child: Wrap(
                    spacing: VibeTokens.space1,
                    runSpacing: VibeTokens.space1,
                    children: <Widget>[
                      _quickActionButton(
                        label: 'All pages',
                        enabled: pageIds.isNotEmpty,
                        onTap:
                            () => setLocal(() {
                              pickedPages
                                ..clear()
                                ..addAll(pageIds);
                            }),
                      ),
                      _quickActionButton(
                        label: 'All templates',
                        enabled: templateIds.isNotEmpty,
                        onTap:
                            () => setLocal(() {
                              pickedTemplates
                                ..clear()
                                ..addAll(templateIds);
                            }),
                      ),
                      _quickActionButton(
                        label: 'All assets',
                        enabled: assetIds.isNotEmpty,
                        onTap:
                            () => setLocal(() {
                              pickedAssets
                                ..clear()
                                ..addAll(assetIds);
                              excludedAutoAssets.clear();
                            }),
                      ),
                      _quickActionButton(
                        label: 'All UI',
                        enabled:
                            pageIds.isNotEmpty ||
                            templateIds.isNotEmpty ||
                            peek.dashboard != null ||
                            hasTheme ||
                            hasNavigation,
                        onTap:
                            () => setLocal(() {
                              pickedPages
                                ..clear()
                                ..addAll(pageIds);
                              pickedTemplates
                                ..clear()
                                ..addAll(templateIds);
                              includeDashboard = peek.dashboard != null;
                              includeTheme = hasTheme;
                              includeNavigation = hasNavigation;
                            }),
                      ),
                      _quickActionButton(
                        label: 'Clear',
                        enabled: hasAny,
                        onTap:
                            () => setLocal(() {
                              pickedPages.clear();
                              pickedTemplates.clear();
                              pickedAssets.clear();
                              excludedAutoAssets.clear();
                              includeDashboard = false;
                              includeTheme = false;
                              includeNavigation = false;
                            }),
                      ),
                    ],
                  ),
                );
              }

              final itemList = SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    quickSelectBar(),
                    // Always render every section — even when the source
                    // bundle is empty for a category — so the user knows
                    // the import surface covers Pages / Templates /
                    // Dashboard / Assets and not just whatever happens
                    // to be in the source. Empty cases land an inline
                    // "— none in source —" placeholder.
                    section('PAGES (${pageIds.length})', <Widget>[
                      if (pageIds.isEmpty)
                        _emptySectionPlaceholder()
                      else
                        for (final id in pageIds)
                          itemRow(
                            checked: pickedPages.contains(id),
                            label: id,
                            collides: existingPageIds.contains(id),
                            onTap:
                                () => setLocal(() {
                                  final wasSelected = pickedPages.contains(id);
                                  if (wasSelected) {
                                    pickedPages.remove(id);
                                    if (previewKey == 'page:$id')
                                      previewKey = null;
                                  } else {
                                    pickedPages.add(id);
                                    previewKey = 'page:$id';
                                  }
                                }),
                          ),
                    ]),
                    section('TEMPLATES (${templateIds.length})', <Widget>[
                      if (templateIds.isEmpty)
                        _emptySectionPlaceholder()
                      else
                        for (final id in templateIds)
                          itemRow(
                            checked: pickedTemplates.contains(id),
                            label: id,
                            collides: existingTemplateIds.contains(id),
                            onTap:
                                () => setLocal(() {
                                  final wasSelected = pickedTemplates.contains(
                                    id,
                                  );
                                  if (wasSelected) {
                                    pickedTemplates.remove(id);
                                    if (previewKey == 'template:$id') {
                                      previewKey = null;
                                    }
                                  } else {
                                    pickedTemplates.add(id);
                                    previewKey = 'template:$id';
                                  }
                                }),
                          ),
                    ]),
                    section('DASHBOARD', <Widget>[
                      if (peek.dashboard == null)
                        _emptySectionPlaceholder()
                      else
                        itemRow(
                          checked: includeDashboard,
                          label: 'replace dashboard',
                          collides: targetHasDashboard,
                          onTap:
                              () => setLocal(() {
                                final wasSelected = includeDashboard;
                                includeDashboard = !includeDashboard;
                                if (wasSelected) {
                                  if (previewKey == 'dashboard')
                                    previewKey = null;
                                } else {
                                  previewKey = 'dashboard';
                                }
                              }),
                        ),
                    ]),
                    section('ASSETS (${assetIds.length})', <Widget>[
                      if (assetIds.isEmpty)
                        _emptySectionPlaceholder()
                      else
                        for (final id in assetIds)
                          itemRow(
                            checked: effectiveAssets.contains(id),
                            // `<id> · <type> · <ref>` + (auto) tag when
                            // pulled in via a picked page / template.
                            label: () {
                              final entry = peek.assets[id]!;
                              final type = '${entry['type'] ?? '?'}';
                              final ref =
                                  entry['contentRef'] ?? entry['path'] ?? '?';
                              final isAuto =
                                  autoAssets.contains(id) &&
                                  !pickedAssets.contains(id);
                              final tag = isAuto ? '  · auto' : '';
                              return '$id  ·  $type  ·  $ref$tag';
                            }(),
                            collides: false,
                            onTap:
                                () => setLocal(() {
                                  final isAuto = autoAssets.contains(id);
                                  final isManual = pickedAssets.contains(id);
                                  if (isManual) {
                                    pickedAssets.remove(id);
                                    // If a page also references it, the
                                    // auto-include kicks back in unless the
                                    // user explicitly excludes.
                                    if (isAuto) excludedAutoAssets.add(id);
                                  } else if (isAuto &&
                                      !excludedAutoAssets.contains(id)) {
                                    // Currently auto-included → click means
                                    // "exclude even though referenced".
                                    excludedAutoAssets.add(id);
                                  } else {
                                    // Either fully unchecked, or previously
                                    // excluded — flip back on.
                                    excludedAutoAssets.remove(id);
                                    pickedAssets.add(id);
                                  }
                                }),
                          ),
                    ]),
                    section('THEME', <Widget>[
                      if (!hasTheme)
                        _emptySectionPlaceholder()
                      else
                        itemRow(
                          checked: includeTheme,
                          label: 'replace theme tokens',
                          collides: false,
                          onTap:
                              () => setLocal(() {
                                includeTheme = !includeTheme;
                              }),
                        ),
                    ]),
                    section('NAVIGATION', <Widget>[
                      if (!hasNavigation)
                        _emptySectionPlaceholder()
                      else
                        itemRow(
                          checked: includeNavigation,
                          label: 'replace navigation chrome',
                          collides: false,
                          onTap:
                              () => setLocal(() {
                                includeNavigation = !includeNavigation;
                              }),
                        ),
                    ]),
                  ],
                ),
              );
              // Diff pane — resolves the previewKey to source / target
              // JSON pairs, runs a simple line-set diff, and renders
              // the colored output. Empty placeholder when nothing's
              // selected yet.
              final diffPane = _DiffPane(
                previewKey: previewKey,
                peek: peek,
                existingPages: existingPages,
                existingTemplates: existingTemplates,
                existingDashboard: existingDashboard,
                targetTheme: targetTheme,
              );
              return SizedBox(
                width: pickEnabled ? 880 : 460,
                child: Padding(
                  padding: const EdgeInsets.all(VibeTokens.space4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'Import .mbd into $channelLabel',
                        style: TextStyle(
                          fontFamily: VibeTokens.fontSans,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: c.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        sourcePath,
                        overflow: TextOverflow.ellipsis,
                        style: vibeMono(size: 10, color: c.textTertiary),
                      ),
                      const SizedBox(height: VibeTokens.space3),
                      radioRow(
                        value: !partial,
                        title: 'Everything',
                        subtitle: 'Replace the entire $channelLabel channel.',
                        onTap: () => setPartial(false),
                      ),
                      radioRow(
                        value: partial,
                        title: 'Pick items',
                        subtitle:
                            peek.isEmpty
                                ? 'Source has no pages, templates, or dashboard.'
                                : 'Merge selected pages / templates / dashboard.',
                        onTap: peek.isEmpty ? null : () => setPartial(true),
                      ),
                      if (pickEnabled) ...<Widget>[
                        const SizedBox(height: VibeTokens.space2),
                        SizedBox(
                          height: 320,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              SizedBox(width: 320, child: itemList),
                              const SizedBox(width: VibeTokens.space3),
                              Expanded(child: diffPane),
                            ],
                          ),
                        ),
                        const SizedBox(height: VibeTokens.space3),
                        Row(
                          children: <Widget>[
                            Text(
                              'On conflict:',
                              style: vibeMono(size: 11, color: c.textSecondary),
                            ),
                            const SizedBox(width: VibeTokens.space2),
                            for (final entry in const <(bool, String)>[
                              (true, 'replace'),
                              (false, 'skip'),
                            ])
                              InkWell(
                                onTap:
                                    () => setLocal(
                                      () => replaceOnConflict = entry.$1,
                                    ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: VibeTokens.space2,
                                    vertical: 4,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Icon(
                                        replaceOnConflict == entry.$1
                                            ? Icons.radio_button_checked
                                            : Icons.radio_button_unchecked,
                                        size: 14,
                                        color:
                                            replaceOnConflict == entry.$1
                                                ? c.mint
                                                : c.textSecondary,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        entry.$2,
                                        style: vibeMono(
                                          size: 11,
                                          color: c.textPrimary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: VibeTokens.space4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          inspectTag(
                            type: 'dialog_action',
                            id: 'import.cancel',
                            label: 'Cancel',
                            child: TextButton(
                              onPressed: () => Navigator.of(ctx).pop(null),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: VibeTokens.space2),
                          inspectTag(
                            type: 'dialog_action',
                            id: 'import.apply',
                            label: 'Apply',
                            child: FilledButton(
                              onPressed:
                                  (partial && !hasAny)
                                      ? null
                                      : () {
                                        final result =
                                            partial
                                                ? ImportSelection.partial(
                                                  pages: Set<String>.from(
                                                    pickedPages,
                                                  ),
                                                  templates: Set<String>.from(
                                                    pickedTemplates,
                                                  ),
                                                  assets: Set<String>.from(
                                                    effectiveAssets,
                                                  ),
                                                  includeDashboard:
                                                      includeDashboard,
                                                  includeTheme: includeTheme,
                                                  includeNavigation:
                                                      includeNavigation,
                                                  replaceOnConflict:
                                                      replaceOnConflict,
                                                )
                                                : ImportSelection.everything();
                                        Navigator.of(ctx).pop(result);
                                      },
                              child: const Text('Apply'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
  );
}
