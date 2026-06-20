import 'dart:convert' show base64Decode;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
// `resolveIconData` is the runtime's canonical Material-icon name →
// IconData map; keep the editor preview in lockstep with what the
// runtime actually renders. Not on the package's public surface.
// ignore: implementation_imports
import 'package:flutter_mcp_ui_runtime/src/utils/icon_resolver.dart';

import 'package:appplayer_studio/base.dart';
// widget_schema_catalog lifts via base barrel

/// Per `handoff/widgets/properties_panel.md` — right column at 320px.
/// Shows the **full mcp_ui 1.3 spec scaffolding** for the focused layer
/// and exposes per-field editors that route changes through [dispatch] so
/// every edit lands in the canonical bundle through the patch pipeline.
class PropertiesPanel extends StatelessWidget {
  const PropertiesPanel({
    super.key,
    required this.focusedLayer,
    required this.projection,
    required this.pipeline,
    required this.dispatch,
    this.focusedPageId,
    this.focusedComponentId,
    this.selectedWidgetPath,
    this.onSelectWidget,
    this.onAssetImport,
    this.assetBundlePath,
    this.health,
    this.width,
    this.modeLayers,
  });

  /// When set, the context-line index numbers the focused layer by its
  /// position within this list (matching a host's mode-filtered card
  /// strip) instead of the global enum order. Null = global order.
  final List<LayerId>? modeLayers;

  /// Latest health snapshot from the shell. Drives the per-page
  /// findings card in `_PagesBody` so authors see issues without
  /// running an audit by hand. Null while a project isn't open or
  /// the first health refresh hasn't completed.
  final Map<String, dynamic>? health;

  final LayerId focusedLayer;
  final LayerProjection projection;
  final PatchPipeline pipeline;
  final PatchDispatcher dispatch;

  /// Picks a file from disk, copies it into the active channel's
  /// `.mbd/assets/<auto-folder>/`, and returns the prepared mcp_bundle
  /// `Asset` entry (id / type / path / mimeType / hash / size).
  /// Returns null when the user cancels. The body then appends the
  /// entry to `manifest.assets.assets[]` via the standard dispatcher
  /// — keeps file IO in the shell and registry mutation in the
  /// editor body, same separation other layers use.
  final Future<Map<String, dynamic>?> Function()? onAssetImport;

  /// Absolute path to the active channel's `.mbd/` directory. The
  /// Assets body uses this to resolve file-backed asset previews
  /// (`<bundlePath>/<asset.path>` → bytes for image thumbnails).
  /// Null when no project is open or the channel has no bundle.
  final String? assetBundlePath;

  /// Currently-selected widget within the focused page or component.
  /// `null` means nothing selected (or no tree applicable).
  final WidgetPath? selectedWidgetPath;

  /// Reports user clicks on tree nodes back to the shell.
  final ValueChanged<WidgetPath>? onSelectWidget;

  /// Override of the column width. Defaults to [VibeTokens.propsPanelWidth].
  final double? width;

  /// When [focusedLayer] is `pages` or `dashboard`, identifies which page
  /// instance the body is editing. Driven by the center [InstanceStrip].
  final String? focusedPageId;

  /// When [focusedLayer] is `components`, identifies which template the
  /// body is editing.
  final String? focusedComponentId;

  static String _label(LayerId id) {
    switch (id) {
      case LayerId.appStructure:
        return 'App';
      case LayerId.theme:
        return 'Theme';
      case LayerId.components:
        return 'Template';
      case LayerId.dashboard:
        return 'Dashboard';
      case LayerId.navigation:
        return 'Navigation';
      case LayerId.pages:
        return 'Page';
      case LayerId.assets:
        return 'Assets';
      case LayerId.knowledge:
        return 'Knowledge';
      case LayerId.manifest:
        return 'Manifest';
      case LayerId.tools:
        return 'Tools';
      case LayerId.agents:
        return 'Agents';
      case LayerId.whole:
        return 'Whole';
    }
  }

  static int _index(LayerId id) {
    switch (id) {
      case LayerId.appStructure:
        return 1;
      case LayerId.theme:
        return 2;
      case LayerId.components:
        return 3;
      case LayerId.dashboard:
        return 4;
      case LayerId.navigation:
        return 5;
      case LayerId.pages:
        return 6;
      case LayerId.assets:
        return 7;
      case LayerId.knowledge:
        return 8;
      case LayerId.manifest:
        return 9;
      case LayerId.tools:
        return 10;
      case LayerId.agents:
        return 11;
      case LayerId.whole:
        return 12;
    }
  }

  Color _layerColor() {
    final l = VibeTokens.layer;
    switch (focusedLayer) {
      case LayerId.appStructure:
        return l.app;
      case LayerId.theme:
        return l.theme;
      case LayerId.components:
        return l.component;
      case LayerId.dashboard:
        return l.dashboard;
      case LayerId.navigation:
        return l.navigation;
      case LayerId.pages:
        return l.page;
      case LayerId.assets:
        return l.assets;
      case LayerId.knowledge:
        return l.knowledge;
      case LayerId.manifest:
        return l.manifest;
      case LayerId.tools:
        return l.tools;
      case LayerId.agents:
        return l.agents;
      case LayerId.whole:
        return l.whole;
    }
  }

  /// Suffix appended to the context line so the user sees which
  /// instance the editors below are bound to. Empty for layers that
  /// don't carry a per-instance focus.
  String? _focusSuffix() {
    switch (focusedLayer) {
      case LayerId.pages:
        final id =
            focusedPageId ??
            (projection.pages.isNotEmpty
                ? (projection.pages.keys.toList()..sort()).first
                : null);
        return id;
      case LayerId.components:
        final id =
            focusedComponentId ??
            (projection.components.templates.isNotEmpty
                ? (projection.components.templates.keys.toList()..sort()).first
                : null);
        return id;
      default:
        return null;
    }
  }

  /// Mode-aware index: position within [modeLayers] + 1 (matching a
  /// mode-filtered card strip) when set, else the global enum order.
  int _displayIndex(LayerId id) {
    final layers = modeLayers;
    if (layers != null) {
      final i = layers.indexOf(id);
      if (i >= 0) return i + 1;
    }
    return _index(id);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final prefix =
        '${_displayIndex(focusedLayer).toString().padLeft(2, '0')} ${_label(focusedLayer)}';
    final suffix = _focusSuffix();
    final contextText = suffix == null ? prefix : '$prefix · $suffix';
    return Container(
      width: width ?? VibeTokens.propsPanelWidth,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(left: BorderSide(color: c.borderDefault)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VibeTokens.space3,
              vertical: VibeTokens.space3,
            ),
            child: Text(
              'PROPERTIES',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 0.6,
                color: c.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          _ContextLine(color: _layerColor(), text: contextText),
          Divider(height: 1, color: c.borderDefault),
          Expanded(
            child: _Body(
              focusedLayer: focusedLayer,
              projection: projection,
              dispatch: dispatch,
              focusedPageId: focusedPageId,
              focusedComponentId: focusedComponentId,
              selectedWidgetPath: selectedWidgetPath,
              onSelectWidget: onSelectWidget,
              onAssetImport: onAssetImport,
              assetBundlePath: assetBundlePath,
              health: health,
            ),
          ),
        ],
      ),
    );
  }
}

class _ContextLine extends StatelessWidget {
  const _ContextLine({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(width: 3, color: color),
          const SizedBox(width: VibeTokens.space2),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: VibeTokens.space1),
                child: Text(
                  text,
                  style: vibeMono(
                    size: 12,
                    weight: FontWeight.w500,
                    color: VibeTokens.color.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Project the `manifest.assets` registry down to the icon-typed
/// subset and shape it for `showVibeIconPicker` / `VibeIconEditor`.
/// Empty-id rows are dropped so the picker can never produce
/// `bundle://` with a blank tail.
List<({String id, String? contentRef})> _iconRefsFromAssets(AssetSlice assets) {
  return assets.entries
      .where((e) => e['type'] == 'icon')
      .map(
        (e) => (
          id: '${e['id'] ?? ''}',
          contentRef:
              e['contentRef'] is String ? e['contentRef'] as String : null,
        ),
      )
      .where((e) => e.id.isNotEmpty)
      .toList(growable: false);
}

class _Body extends StatelessWidget {
  const _Body({
    required this.focusedLayer,
    required this.projection,
    required this.dispatch,
    required this.focusedPageId,
    required this.focusedComponentId,
    required this.selectedWidgetPath,
    required this.onSelectWidget,
    this.onAssetImport,
    this.assetBundlePath,
    this.health,
  });
  final LayerId focusedLayer;
  final LayerProjection projection;
  final PatchDispatcher dispatch;
  final String? focusedPageId;
  final String? focusedComponentId;
  final WidgetPath? selectedWidgetPath;
  final ValueChanged<WidgetPath>? onSelectWidget;
  final Future<Map<String, dynamic>?> Function()? onAssetImport;
  final String? assetBundlePath;
  final Map<String, dynamic>? health;

  @override
  Widget build(BuildContext context) {
    switch (focusedLayer) {
      case LayerId.appStructure:
        return _AppStructureBody(
          value: projection.appStructure,
          projection: projection,
          dispatch: dispatch,
          health: health,
        );
      case LayerId.theme:
        return _ThemeBody(
          value: projection.theme,
          projection: projection,
          dispatch: dispatch,
          health: health,
        );
      case LayerId.components:
        return _ComponentsBody(
          set: projection.components,
          focusedId: focusedComponentId,
          dispatch: dispatch,
          selectedWidgetPath: selectedWidgetPath,
          onSelectWidget: onSelectWidget,
          health: health,
        );
      case LayerId.dashboard:
        return _DashboardBody(
          value: projection.dashboard,
          dispatch: dispatch,
          health: health,
        );
      case LayerId.navigation:
        return _NavigationBody(
          value: projection.navigation,
          routes: projection.appStructure.routes
              .map((r) => r.path)
              .toList(growable: false),
          assets: projection.assets,
          dispatch: dispatch,
          health: health,
        );
      case LayerId.pages:
        return _PagesBody(
          pages: projection.pages,
          assets: projection.assets,
          focusedId: focusedPageId,
          dispatch: dispatch,
          selectedWidgetPath: selectedWidgetPath,
          onSelectWidget: onSelectWidget,
          health: health,
        );
      case LayerId.assets:
        return _AssetsBody(
          assets: projection.assets,
          dispatch: dispatch,
          onImport: onAssetImport,
          bundlePath: assetBundlePath,
          health: health,
        );
      case LayerId.manifest:
        return _ManifestBody(projection: projection, dispatch: dispatch);
      case LayerId.knowledge:
      case LayerId.tools:
      case LayerId.agents:
        // Bundle-mode layers whose full editor renders in the center
        // column (BundleKnowledgeView / BundleToolsView / BundleAgentsView)
        // — the properties panel reflects the card only.
        return _KnowledgePlaceholderBody(projection: projection);
      case LayerId.whole:
        return _WholeBody(projection: projection);
    }
  }
}

class _Section extends StatefulWidget {
  const _Section({
    required this.title,
    required this.children,
    this.initiallyOpen = true,
    this.indent = 0,
    this.trailing,
  });
  final String title;
  final List<Widget> children;
  final bool initiallyOpen;

  /// Visual nesting depth. Each step shifts the chevron + title right
  /// (and slightly dims the title) so child sections inside a parent
  /// `_Section` read as nested rather than peer.
  final int indent;

  /// Optional small right-aligned widget rendered in the section
  /// header — used by the Inspector Health section to show a letter
  /// grade chip alongside the finding count.
  final Widget? trailing;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  late bool _open;

  @override
  void initState() {
    super.initState();
    _open = widget.initiallyOpen;
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    // Layout depth comes from natural nesting — each parent Section's
    // body Padding already shifts children right. Adding an extra
    // `indent * 14` here would double-count and push nested fields
    // two steps in. Keep the layout offsets fixed and let `indent`
    // drive only the title color cue.
    const headerLeft = 0.0;
    const bodyLeft = 14.0;
    final titleColor = widget.indent == 0 ? c.textPrimary : c.textSecondary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              VibeTokens.space3 + headerLeft,
              VibeTokens.space2,
              VibeTokens.space3,
              VibeTokens.space2,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  _open ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 14,
                  color: c.textSecondary,
                ),
                const SizedBox(width: 2),
                Text(
                  widget.title.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w600,
                    color: titleColor,
                  ),
                ),
                if (widget.trailing != null) ...<Widget>[
                  const Spacer(),
                  widget.trailing!,
                ],
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: EdgeInsets.only(left: bodyLeft),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.children,
            ),
          ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: vibeMono(size: 12, color: c.textSecondary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              value ?? '—',
              style: vibeMono(
                size: 11,
                color: value == null ? c.textTertiary : c.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Editable list of `/ui/routes` entries — path key + target page id +
/// delete button per row, plus an add row at the bottom. Each
/// operation dispatches a single patch through the standard
/// pipeline so undo / draft / spec validation all work.
class _RoutesEditor extends StatefulWidget {
  const _RoutesEditor({
    required this.routes,
    required this.pageIds,
    required this.dispatch,
  });
  final List<RouteDef> routes;
  final List<String> pageIds;
  final PatchDispatcher dispatch;

  @override
  State<_RoutesEditor> createState() => _RoutesEditorState();
}

class _RoutesEditorState extends State<_RoutesEditor> {
  final TextEditingController _newPath = TextEditingController();
  String? _newPageId;

  @override
  void dispose() {
    _newPath.dispose();
    super.dispose();
  }

  /// JSON-Pointer-escape a single segment per RFC 6901: `~` → `~0`,
  /// `/` → `~1`. Without this a route key like `/about` collapses
  /// into a literal `/ui/routes//about` which the patch resolver
  /// can't address.
  String _escapeSegment(String s) =>
      s.replaceAll('~', '~0').replaceAll('/', '~1');

  Future<void> _setRoute(String pathKey, String pageId) async {
    if (pathKey.isEmpty || pageId.isEmpty) return;
    await widget.dispatch(
      layer: LayerId.appStructure,
      path: '/ui/routes/${_escapeSegment(pathKey)}',
      value: pageId,
    );
  }

  Future<void> _removeRoute(String pathKey) async {
    await widget.dispatch(
      layer: LayerId.appStructure,
      path: '/ui/routes/${_escapeSegment(pathKey)}',
      value: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final pageIds = widget.pageIds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VibeTokens.space4,
        VibeTokens.space2,
        VibeTokens.space4,
        VibeTokens.space2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: VibeTokens.space1),
            child: Text(
              'routes (${widget.routes.length})',
              style: vibeMono(size: 11, color: c.textSecondary),
            ),
          ),
          for (final r in widget.routes)
            _RouteRow(
              path: r.path,
              pageId: r.pageId,
              pageIds: pageIds,
              onPageIdChanged: (newId) {
                if (newId != null && newId != r.pageId) {
                  _setRoute(r.path, newId);
                }
              },
              onDelete: () => _removeRoute(r.path),
            ),
          const SizedBox(height: VibeTokens.space2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                flex: 2,
                child: VibeCompactInputBox(
                  child: TextField(
                    controller: _newPath,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      filled: false,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      hintText: '/about',
                      hintStyle: vibeMono(size: 11, color: c.textTertiary),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: VibeTokens.space1),
              Expanded(
                flex: 2,
                child: _PageIdDropdown(
                  value: _newPageId,
                  options: pageIds,
                  onChanged: (v) => setState(() => _newPageId = v),
                ),
              ),
              SizedBox(
                width: 24,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 28,
                  ),
                  icon: const Icon(Icons.add),
                  color: c.textSecondary,
                  tooltip: 'Add route',
                  onPressed:
                      (_newPath.text.trim().isEmpty || _newPageId == null)
                          ? null
                          : () async {
                            final p = _newPath.text.trim();
                            final id = _newPageId!;
                            await _setRoute(p, id);
                            if (mounted) {
                              setState(() {
                                _newPath.clear();
                                _newPageId = null;
                              });
                            }
                          },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RouteRow extends StatelessWidget {
  const _RouteRow({
    required this.path,
    required this.pageId,
    required this.pageIds,
    required this.onPageIdChanged,
    required this.onDelete,
  });
  final String path;
  final String pageId;
  final List<String> pageIds;
  final ValueChanged<String?> onPageIdChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final missingTarget = pageId.isNotEmpty && !pageIds.contains(pageId);
    return Padding(
      padding: const EdgeInsets.only(bottom: VibeTokens.space1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            flex: 2,
            child: Text(
              path,
              style: vibeMono(size: 11, color: c.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: VibeTokens.space1),
          Expanded(
            flex: 2,
            child: _PageIdDropdown(
              value: pageId.isEmpty ? null : pageId,
              options: pageIds,
              showWarning: missingTarget,
              onChanged: onPageIdChanged,
            ),
          ),
          SizedBox(
            width: 24,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 14,
              constraints: const BoxConstraints.tightFor(width: 24, height: 28),
              icon: const Icon(Icons.close),
              color: c.textTertiary,
              tooltip: 'Remove route',
              onPressed: onDelete,
            ),
          ),
        ],
      ),
    );
  }
}

class _PageIdDropdown extends StatelessWidget {
  const _PageIdDropdown({
    required this.value,
    required this.options,
    required this.onChanged,
    this.showWarning = false,
  });
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final bool showWarning;

  @override
  Widget build(BuildContext context) {
    return VibeCompactDropdown<String>(
      value: value,
      options: options,
      labelOf: (s) => s,
      placeholder: 'page',
      warning: showWarning,
      onChanged: onChanged,
    );
  }
}

class _AppStructureBody extends StatelessWidget {
  const _AppStructureBody({
    required this.value,
    required this.projection,
    required this.dispatch,
    this.health,
  });
  final AppStructure value;
  final LayerProjection projection;
  final PatchDispatcher dispatch;
  final Map<String, dynamic>? health;

  String? _str(String pointer) {
    final v = projection.lookup(pointer);
    if (v == null) return null;
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return null;
  }

  dynamic _json(String pointer) => projection.lookup(pointer);

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: <Widget>[
        _InspectorHealthSection(
          health: health,
          // App structure has no clean prefix — show project-wide
          // findings here so authors see the global picture.
          pathPrefix: null,
          scopeLabel: 'the project',
        ),
        // ApplicationDefinition root (mcp_ui_dsl /ui/*). Per spec
        // ground truth — manifest is extracted from these at bundle
        // pack time, not edited directly.
        _Section(
          title: 'Identity',
          children: <Widget>[
            VibeTextEditor(
              label: 'id',
              value: _str('/ui/id'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/id',
            ),
            VibeTextEditor(
              label: 'title',
              value: _str('/ui/title'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/title',
            ),
            VibeTextEditor(
              label: 'version',
              value: _str('/ui/version'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/version',
            ),
            VibeTextEditor(
              label: 'description',
              value: _str('/ui/description'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/description',
            ),
            VibeTextEditor(
              label: 'category',
              value: _str('/ui/category'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/category',
            ),
            VibeIconEditor(
              label: 'icon',
              value: _str('/ui/icon'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/icon',
              registeredIcons: _iconRefsFromAssets(projection.assets),
            ),
          ],
        ),
        _Section(
          title: 'Routing',
          children: <Widget>[
            VibeTextEditor(
              label: 'initialRoute',
              value: _str('/ui/initialRoute'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/initialRoute',
            ),
            _RoutesEditor(
              routes: value.routes,
              pageIds: projection.pages.keys.toList(growable: false),
              dispatch: dispatch,
            ),
          ],
        ),
        _Section(
          title: 'Navigation',
          initiallyOpen: false,
          children: <Widget>[
            VibeEnumEditor(
              label: 'type',
              value: _str('/ui/navigation/type'),
              options: const <String>['drawer', 'bottomBar', 'rail', 'tabs'],
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/navigation/type',
            ),
            VibeJsonEditor(
              label: 'items',
              value: _json('/ui/navigation/items'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/navigation/items',
            ),
          ],
        ),
        // ApplicationDefinition i18n (configs/app/I18nConfig.yaml).
        // Manifest-level localization is bundle metadata — extracted
        // from this at bundle pack time, edited later when versioning
        // / signing UI is built.
        _Section(
          title: 'I18n',
          initiallyOpen: false,
          children: <Widget>[
            VibeTextEditor(
              label: 'defaultLocale',
              value: _str('/ui/i18n/defaultLocale'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/i18n/defaultLocale',
            ),
            _StringListEditor(
              label: 'locales',
              values: () {
                final v = _json('/ui/i18n/locales');
                return v is List
                    ? v.whereType<String>().toList(growable: false)
                    : const <String>[];
              }(),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/i18n/locales',
              placeholder: 'en, ko, …',
            ),
            VibeJsonEditor(
              label: 'text',
              value: _json('/ui/i18n/text'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/i18n/text',
            ),
            VibeJsonEditor(
              label: 'pluralization',
              value: _json('/ui/i18n/pluralization'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/i18n/pluralization',
            ),
            VibeJsonEditor(
              label: 'numberFormat',
              value: _json('/ui/i18n/numberFormat'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/i18n/numberFormat',
            ),
            VibeJsonEditor(
              label: 'dateFormat',
              value: _json('/ui/i18n/dateFormat'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/i18n/dateFormat',
            ),
            VibeJsonEditor(
              label: 'textDirection',
              value: _json('/ui/i18n/textDirection'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/i18n/textDirection',
            ),
          ],
        ),
        // App-level services (configs/app/ServiceDefinition.yaml).
        // Map of name → { kind, interval, tool, binding, autoStart,
        // params, onMessage, onError }.
        _Section(
          title: 'Services',
          initiallyOpen: false,
          children: <Widget>[
            _ServicesEditor(
              services: () {
                final v = _json('/ui/services');
                return v is Map
                    ? Map<String, dynamic>.from(v)
                    : const <String, dynamic>{};
              }(),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              basePath: '/ui/services',
            ),
          ],
        ),
        // Remote template libraries (configs/app/TemplateLibraryRef
        // .yaml). Array of { uri, version, integrity }.
        _Section(
          title: 'Template libraries',
          initiallyOpen: false,
          children: <Widget>[
            _TemplateLibrariesEditor(
              entries: () {
                final v = _json('/ui/templateLibraries');
                return v is List
                    ? v
                        .whereType<Map>()
                        .map((m) => Map<String, dynamic>.from(m))
                        .toList(growable: false)
                    : const <Map<String, dynamic>>[];
              }(),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              basePath: '/ui/templateLibraries',
            ),
          ],
        ),
        _Section(
          title: 'Splash screen',
          initiallyOpen: false,
          children: <Widget>[
            VibeColorEditor(
              label: 'background',
              value: _str('/ui/splash/background'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/splash/background',
            ),
            VibeColorEditor(
              label: 'foreground',
              value: _str('/ui/splash/foreground'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/splash/foreground',
            ),
            VibeTextEditor(
              label: 'durationMs',
              numeric: true,
              value: _str('/ui/splash/durationMs'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/splash/durationMs',
            ),
            VibeTextEditor(
              label: 'image',
              value: _str('/ui/splash/image'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/splash/image',
            ),
          ],
        ),
        _Section(
          title: 'Permissions',
          initiallyOpen: false,
          children: <Widget>[
            VibeJsonEditor(
              label: 'permissions',
              value:
                  _json('/ui/permissions') ??
                  (value.permissions.isEmpty
                      ? null
                      : <Map<String, dynamic>>[
                        for (final p in value.permissions)
                          <String, dynamic>{'id': p.id, 'granted': p.granted},
                      ]),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/permissions',
            ),
          ],
        ),
        _Section(
          title: 'Background',
          initiallyOpen: false,
          children: <Widget>[
            VibeEnumEditor(
              label: 'kind',
              value: value.background?.kind,
              options: const <String>[
                'none',
                'passive_push',
                'active',
                'system',
              ],
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/background/kind',
            ),
          ],
        ),
        _Section(
          title: 'Publisher',
          initiallyOpen: false,
          children: <Widget>[
            VibeTextEditor(
              label: 'name',
              value: _str('/ui/publisher/name'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/publisher/name',
            ),
            VibeTextEditor(
              label: 'email',
              value: _str('/ui/publisher/email'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/publisher/email',
            ),
            VibeTextEditor(
              label: 'url',
              value: _str('/ui/publisher/url') ?? _str('/ui/publisher/website'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/publisher/url',
            ),
          ],
        ),
        _Section(
          title: 'Timestamps',
          initiallyOpen: false,
          children: <Widget>[
            VibeTextEditor(
              label: 'createdAt',
              value: _str('/ui/timestamps/createdAt'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/timestamps/createdAt',
            ),
            VibeTextEditor(
              label: 'updatedAt',
              value: _str('/ui/timestamps/updatedAt'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/timestamps/updatedAt',
            ),
            VibeTextEditor(
              label: 'publishedAt',
              value: _str('/ui/timestamps/publishedAt'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/timestamps/publishedAt',
            ),
          ],
        ),
        _Section(
          title: 'Screenshots',
          initiallyOpen: false,
          children: <Widget>[
            VibeJsonEditor(
              label: 'screenshots',
              value: _json('/ui/screenshots'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/screenshots',
            ),
          ],
        ),
        _Section(
          title: 'Templates',
          initiallyOpen: false,
          children: <Widget>[
            VibeJsonEditor(
              label: 'templates',
              value: _json('/ui/templates'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/templates',
            ),
          ],
        ),
        _Section(
          title: 'Initial state',
          initiallyOpen: false,
          children: <Widget>[
            VibeJsonEditor(
              label: 'state',
              value: _json('/ui/state'),
              dispatch: dispatch,
              layer: LayerId.appStructure,
              path: '/ui/state',
            ),
          ],
        ),
        _Section(
          title: 'Lifecycle',
          initiallyOpen: false,
          children: <Widget>[
            for (final h in const <String>[
              'onLaunch',
              'onResume',
              'onPause',
              'onTerminate',
            ])
              VibeTextEditor(
                label: h,
                value: _str('/ui/lifecycle/$h'),
                dispatch: dispatch,
                layer: LayerId.appStructure,
                path: '/ui/lifecycle/$h',
              ),
          ],
        ),
      ],
    );
  }
}

/// All M3 ColorScheme roles per mcp_ui 1.3 spec
/// (see ColorSchemeDefinition).
const List<String> _kColorRoles = <String>[
  'primary',
  'onPrimary',
  'primaryContainer',
  'onPrimaryContainer',
  'secondary',
  'onSecondary',
  'secondaryContainer',
  'onSecondaryContainer',
  'tertiary',
  'onTertiary',
  'tertiaryContainer',
  'onTertiaryContainer',
  'error',
  'onError',
  'errorContainer',
  'onErrorContainer',
  'surface',
  'onSurface',
  'onSurfaceVariant',
  'surfaceTint',
  'surfaceBright',
  'surfaceDim',
  'surfaceContainerLowest',
  'surfaceContainerLow',
  'surfaceContainer',
  'surfaceContainerHigh',
  'surfaceContainerHighest',
  'outline',
  'outlineVariant',
  'inverseSurface',
  'onInverseSurface',
  'inversePrimary',
  'shadow',
  'scrim',
];

/// All 15 M3 typography styles per mcp_ui 1.3 spec.
const List<String> _kTypographyStyles = <String>[
  'displayLarge',
  'displayMedium',
  'displaySmall',
  'headlineLarge',
  'headlineMedium',
  'headlineSmall',
  'titleLarge',
  'titleMedium',
  'titleSmall',
  'bodyLarge',
  'bodyMedium',
  'bodySmall',
  'labelLarge',
  'labelMedium',
  'labelSmall',
];

/// Spacing tokens defined in 1.3 SpacingDefinition (configs/theme/Spacing.yaml).
const List<String> _kSpacingTokens = <String>[
  'xxs',
  'xs',
  'sm',
  'md',
  'lg',
  'xl',
  '2xl',
  '3xl',
  '4xl',
];

/// Shape corner families.
const List<String> _kShapeFamilies = <String>[
  'none',
  'extraSmall',
  'small',
  'medium',
  'large',
  'extraLarge',
  'full',
];

class _ThemeBody extends StatelessWidget {
  const _ThemeBody({
    required this.value,
    required this.projection,
    required this.dispatch,
    this.health,
  });
  final ThemeView value;
  final LayerProjection projection;
  final PatchDispatcher dispatch;
  final Map<String, dynamic>? health;

  /// Walk every string leaf in the canonical once and tally
  /// `{{theme.<domain>.<role>}}` references across all domains.
  /// Returned shape: `domain → role → count`. The same single walk
  /// powers the Color / Spacing / Shape / Elevation usage badges so
  /// expensive trees only get traversed one time per Theme rebuild.
  Map<String, Map<String, int>> _themeTokenUsage() {
    final pattern = RegExp(r'\{\{\s*theme\.(\w+)\.(\w+)\s*\}\}');
    final out = <String, Map<String, int>>{};
    void walk(dynamic node) {
      if (node is String) {
        for (final m in pattern.allMatches(node)) {
          final domain = m.group(1)!;
          final role = m.group(2)!;
          out.putIfAbsent(domain, () => <String, int>{});
          out[domain]![role] = (out[domain]![role] ?? 0) + 1;
        }
        return;
      }
      if (node is Map) {
        for (final v in node.values) {
          walk(v);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      }
    }

    walk(projection.rawJson['ui']);
    return out;
  }

  Map<String, dynamic> _section(String key) {
    final raw = value.raw[key];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const <String, dynamic>{};
  }

  String? _stringy(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is num) return '$v';
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final tokenUsage = _themeTokenUsage();
    final colorUsage = tokenUsage['color'] ?? const <String, int>{};
    final spacingUsage = tokenUsage['spacing'] ?? const <String, int>{};
    // shape usage badges land when _shapeCornerEditors moves to the
    // _NumericTokenRow shape — wired in a follow-up turn.
    final elevationUsage = tokenUsage['elevation'] ?? const <String, int>{};
    final colors = _section('color');
    final typography = _section('typography');
    final spacing = _section('spacing');
    final shape = _section('shape');
    final elevation = _section('elevation');
    final motion = _section('motion');
    final density = _section('density');
    final breakpoints = _section('breakpoints');
    final border = _section('border');
    final opacity = _section('opacity');
    final focusRing = _section('focusRing');
    final zIndex = _section('zIndex');
    final component = _section('component');
    final mode = value.raw['mode'] as String?;

    return ListView(
      children: <Widget>[
        _InspectorHealthSection(
          health: health,
          pathPrefix: '/ui/theme',
          scopeLabel: 'the theme',
        ),
        _Section(
          title: 'Preset',
          children: <Widget>[
            // Spec 1.3.4 Phase 5 — curated content-app theme bundle
            // applied as base; other theme.* fields layer overrides.
            VibeEnumEditor(
              label: 'preset',
              value: _stringy(value.raw['preset']),
              options: const <String>[
                'warm',
                'cool',
                'sepia',
                'mono',
                'highContrast',
              ],
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/preset',
            ),
          ],
        ),
        _Section(
          title: 'Mode',
          children: <Widget>[
            VibeEnumEditor(
              label: 'mode',
              value: mode,
              options: const <String>['system', 'light', 'dark'],
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/mode',
            ),
            _Field(
              label: 'light',
              value: value.raw['light'] == null ? null : 'set',
            ),
            _Field(
              label: 'dark',
              value: value.raw['dark'] == null ? null : 'set',
            ),
          ],
        ),
        _Section(
          title: 'Color',
          children: <Widget>[
            for (final role in _kColorRoles)
              _ColorRoleRow(
                role: role,
                value: _stringy(colors[role]),
                dispatch: dispatch,
                usage: colorUsage[role] ?? 0,
                projection: projection,
              ),
          ],
        ),
        _Section(
          title: 'Typography',
          initiallyOpen: false,
          children: <Widget>[
            VibeTextEditor(
              label: 'fontFamily',
              value: _stringy(typography['fontFamily']),
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/typography/fontFamily',
            ),
            VibeTextEditor(
              label: 'fontSize',
              numeric: true,
              value: _stringy(typography['fontSize']),
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/typography/fontSize',
            ),
            VibeTextEditor(
              label: 'fontWeight',
              numeric: true,
              value: _stringy(typography['fontWeight']),
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/typography/fontWeight',
            ),
            VibeTextEditor(
              label: 'lineHeight',
              numeric: true,
              value: _stringy(typography['lineHeight']),
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/typography/lineHeight',
            ),
            VibeTextEditor(
              label: 'letterSpacing',
              numeric: true,
              value: _stringy(typography['letterSpacing']),
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/typography/letterSpacing',
            ),
            for (final style in _kTypographyStyles)
              ..._typographyStyleEditors(style, typography[style]),
          ],
        ),
        // Spec 1.3.4 Phase 5 — font asset registration. Map of family
        // name → { weights, variableAxes, fallbacks }.
        _Section(
          title: 'Fonts',
          initiallyOpen: false,
          children: <Widget>[
            _FontRegistryEditor(
              fonts:
                  value.raw['fonts'] is Map
                      ? Map<String, dynamic>.from(value.raw['fonts'] as Map)
                      : const <String, dynamic>{},
              dispatch: dispatch,
              layer: LayerId.theme,
              basePath: '/ui/theme/fonts',
            ),
          ],
        ),
        _Section(
          title: 'Spacing',
          initiallyOpen: false,
          children: <Widget>[
            for (final tok in _kSpacingTokens)
              _NumericTokenRow(
                label: tok,
                value: _stringy(spacing[tok]),
                dispatch: dispatch,
                path: '/ui/theme/spacing/$tok',
                usage: spacingUsage[tok] ?? 0,
                domain: 'spacing',
                role: tok,
                projection: projection,
              ),
            _NumericTokenRow(
              label: 'screenPadding',
              value: _stringy(spacing['screenPadding']),
              dispatch: dispatch,
              path: '/ui/theme/spacing/screenPadding',
              usage: spacingUsage['screenPadding'] ?? 0,
              domain: 'spacing',
              role: 'screenPadding',
              projection: projection,
            ),
          ],
        ),
        _Section(
          title: 'Shape',
          initiallyOpen: false,
          children: <Widget>[
            for (final tok in _kShapeFamilies)
              ..._shapeCornerEditors(tok, shape[tok]),
          ],
        ),
        _Section(
          title: 'Elevation',
          initiallyOpen: false,
          children: <Widget>[
            for (var i = 0; i < 6; i++)
              _NumericTokenRow(
                label: 'level$i',
                value: _stringy(elevation['level$i']),
                dispatch: dispatch,
                path: '/ui/theme/elevation/level$i',
                usage: elevationUsage['level$i'] ?? 0,
                domain: 'elevation',
                role: 'level$i',
                projection: projection,
              ),
            VibeTextEditor(
              label: 'shadow',
              numeric: true,
              value: _stringy(elevation['shadow']),
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/elevation/shadow',
            ),
            VibeColorEditor(
              label: 'tint',
              value: _stringy(elevation['tint']),
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/elevation/tint',
            ),
          ],
        ),
        _Section(
          title: 'Motion',
          initiallyOpen: false,
          children: <Widget>[
            for (final k in const <String>[
              'short1',
              'short2',
              'short3',
              'short4',
              'medium1',
              'medium2',
              'medium3',
              'medium4',
              'long1',
              'long2',
              'long3',
              'long4',
              'extraLong',
            ])
              VibeTextEditor(
                label: 'duration.$k',
                numeric: true,
                value: _stringy(
                  (motion['duration'] is Map)
                      ? (motion['duration'] as Map)[k]
                      : null,
                ),
                dispatch: dispatch,
                layer: LayerId.theme,
                path: '/ui/theme/motion/duration/$k',
              ),
            for (final k in const <String>[
              'standard',
              'emphasized',
              'decelerate',
              'accelerate',
            ])
              VibeTextEditor(
                label: 'easing.$k',
                value: _stringy(
                  (motion['easing'] is Map)
                      ? (motion['easing'] as Map)[k]
                      : null,
                ),
                dispatch: dispatch,
                layer: LayerId.theme,
                path: '/ui/theme/motion/easing/$k',
              ),
          ],
        ),
        _Section(
          title: 'Density',
          initiallyOpen: false,
          children: <Widget>[
            VibeEnumEditor(
              label: 'active',
              value: _stringy(density['active']),
              options: const <String>['comfortable', 'standard', 'compact'],
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/density/active',
            ),
            for (final lvl in const <String>[
              'comfortable',
              'standard',
              'compact',
            ])
              ..._densityLevelEditors(lvl, density[lvl]),
          ],
        ),
        _Section(
          title: 'Breakpoints',
          initiallyOpen: false,
          children: <Widget>[
            for (final k in const <String>[
              'compact',
              'medium',
              'expanded',
              'large',
              'extraLarge',
            ])
              VibeTextEditor(
                label: k,
                numeric: true,
                value: _stringy(breakpoints[k]),
                dispatch: dispatch,
                layer: LayerId.theme,
                path: '/ui/theme/breakpoints/$k',
              ),
          ],
        ),
        _Section(
          title: 'Border',
          initiallyOpen: false,
          children: <Widget>[
            VibeEnumEditor(
              label: 'style',
              value: _stringy(border['style']),
              options: const <String>[
                'solid',
                'dashed',
                'dotted',
                'double',
                'none',
              ],
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/border/style',
            ),
            for (final k in const <String>[
              'hairline',
              'thin',
              'normal',
              'thick',
              'heavy',
            ])
              VibeTextEditor(
                label: 'width.$k',
                numeric: true,
                value: _stringy(
                  (border['width'] is Map) ? (border['width'] as Map)[k] : null,
                ),
                dispatch: dispatch,
                layer: LayerId.theme,
                path: '/ui/theme/border/width/$k',
              ),
          ],
        ),
        _Section(
          title: 'Opacity',
          initiallyOpen: false,
          children: <Widget>[
            // Common opacity tokens; spec allows arbitrary names.
            for (final k in const <String>[
              'disabled',
              'hover',
              'focus',
              'pressed',
              'dragged',
              'selected',
              'overlay',
              'scrim',
            ])
              VibeTextEditor(
                label: k,
                numeric: true,
                value: _stringy(opacity[k]),
                dispatch: dispatch,
                layer: LayerId.theme,
                path: '/ui/theme/opacity/$k',
              ),
          ],
        ),
        _Section(
          title: 'Focus ring',
          initiallyOpen: false,
          children: <Widget>[
            VibeColorEditor(
              label: 'color',
              value: _stringy(focusRing['color']),
              dispatch: dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/focusRing/color',
            ),
            for (final k in const <String>['width', 'offset', 'radius'])
              VibeTextEditor(
                label: k,
                numeric: true,
                value: _stringy(focusRing[k]),
                dispatch: dispatch,
                layer: LayerId.theme,
                path: '/ui/theme/focusRing/$k',
              ),
          ],
        ),
        _Section(
          title: 'Z-index',
          initiallyOpen: false,
          children: <Widget>[
            for (final k in const <String>[
              'base',
              'dropdown',
              'sticky',
              'overlay',
              'modal',
              'popover',
              'tooltip',
              'toast',
              'system',
            ])
              VibeTextEditor(
                label: k,
                numeric: true,
                value: _stringy(zIndex[k]),
                dispatch: dispatch,
                layer: LayerId.theme,
                path: '/ui/theme/zIndex/$k',
              ),
          ],
        ),
        _Section(
          title: 'Component',
          initiallyOpen: false,
          children: <Widget>[
            if (component.isEmpty)
              const _Field(label: '(no component overrides)', value: null),
            for (final entry in component.entries)
              _Field(
                label: entry.key,
                value:
                    entry.value is Map
                        ? '${(entry.value as Map).length} props'
                        : _stringy(entry.value),
              ),
          ],
        ),
      ],
    );
  }

  /// Per-style typography editors (5 fields per M3 style).
  List<Widget> _typographyStyleEditors(String style, dynamic raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final base = '/ui/theme/typography/$style';
    return <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space3,
          vertical: 4,
        ),
        child: Text(
          style,
          style: vibeMono(
            size: 11,
            weight: FontWeight.w600,
            color: VibeTokens.color.textPrimary,
          ),
        ),
      ),
      VibeTextEditor(
        label: '  fontFamily',
        value: _stringy(m['fontFamily']),
        dispatch: dispatch,
        layer: LayerId.theme,
        path: '$base/fontFamily',
      ),
      VibeTextEditor(
        label: '  fontSize',
        numeric: true,
        value: _stringy(m['fontSize']),
        dispatch: dispatch,
        layer: LayerId.theme,
        path: '$base/fontSize',
      ),
      VibeTextEditor(
        label: '  fontWeight',
        numeric: true,
        value: _stringy(m['fontWeight']),
        dispatch: dispatch,
        layer: LayerId.theme,
        path: '$base/fontWeight',
      ),
      VibeTextEditor(
        label: '  lineHeight',
        numeric: true,
        value: _stringy(m['lineHeight']),
        dispatch: dispatch,
        layer: LayerId.theme,
        path: '$base/lineHeight',
      ),
      VibeTextEditor(
        label: '  letterSpacing',
        numeric: true,
        value: _stringy(m['letterSpacing']),
        dispatch: dispatch,
        layer: LayerId.theme,
        path: '$base/letterSpacing',
      ),
    ];
  }

  /// Per-family ShapeCorner editors (uniform / per-corner).
  List<Widget> _shapeCornerEditors(String family, dynamic raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final base = '/ui/theme/shape/$family';
    return <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space3,
          vertical: 4,
        ),
        child: Text(
          family,
          style: vibeMono(
            size: 11,
            weight: FontWeight.w600,
            color: VibeTokens.color.textPrimary,
          ),
        ),
      ),
      VibeTextEditor(
        label: '  uniform',
        numeric: true,
        value: _stringy(m['uniform']),
        dispatch: dispatch,
        layer: LayerId.theme,
        path: '$base/uniform',
      ),
      for (final corner in const <String>[
        'topStart',
        'topEnd',
        'bottomStart',
        'bottomEnd',
      ])
        VibeTextEditor(
          label: '  $corner',
          numeric: true,
          value: _stringy(m[corner]),
          dispatch: dispatch,
          layer: LayerId.theme,
          path: '$base/$corner',
        ),
    ];
  }

  /// Per-level density editors (vertical / horizontal numeric).
  List<Widget> _densityLevelEditors(String level, dynamic raw) {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final base = '/ui/theme/density/$level';
    return <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space3,
          vertical: 4,
        ),
        child: Text(
          level,
          style: vibeMono(
            size: 11,
            weight: FontWeight.w600,
            color: VibeTokens.color.textPrimary,
          ),
        ),
      ),
      VibeTextEditor(
        label: '  vertical',
        numeric: true,
        value: _stringy(m['vertical']),
        dispatch: dispatch,
        layer: LayerId.theme,
        path: '$base/vertical',
      ),
      VibeTextEditor(
        label: '  horizontal',
        numeric: true,
        value: _stringy(m['horizontal']),
        dispatch: dispatch,
        layer: LayerId.theme,
        path: '$base/horizontal',
      ),
    ];
  }
}

class _ComponentsBody extends StatelessWidget {
  const _ComponentsBody({
    required this.set,
    required this.focusedId,
    required this.dispatch,
    required this.selectedWidgetPath,
    required this.onSelectWidget,
    this.health,
  });
  final ComponentSet set;

  /// Component id selected by the center [InstanceStrip]. When null and
  /// templates exist, defaults to the first one alphabetically.
  final String? focusedId;
  final PatchDispatcher dispatch;

  final WidgetPath? selectedWidgetPath;
  final ValueChanged<WidgetPath>? onSelectWidget;
  final Map<String, dynamic>? health;

  String? get _resolved {
    if (focusedId != null && set.templates.containsKey(focusedId)) {
      return focusedId;
    }
    if (set.templates.isEmpty) return null;
    final keys = set.templates.keys.toList()..sort();
    return keys.first;
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final id = _resolved;
    if (id == null) {
      return Padding(
        padding: const EdgeInsets.all(VibeTokens.space4),
        child: Text(
          'No components yet — add one from the strip above.',
          style: vibeMono(size: 12, color: c.textSecondary),
        ),
      );
    }
    final template = set.templates[id];
    final templateRoot = template?['content'];
    final hasTree =
        templateRoot is Map<String, dynamic> &&
        templateRoot.containsKey('type');
    return ListView(
      children: <Widget>[
        _InspectorHealthSection(
          health: health,
          pathPrefix: '/ui/templates/$id',
          scopeLabel: 'this template',
          onSelectWidget: onSelectWidget,
        ),
        _Section(
          title: 'Template settings',
          initiallyOpen: false,
          children: <Widget>[
            _Section(
              title: 'Identity',
              indent: 1,
              children: <Widget>[
                _Field(label: 'id', value: id),
                VibeTextEditor(
                  label: 'name',
                  value: template?['name']?.toString(),
                  dispatch: dispatch,
                  layer: LayerId.components,
                  path: '/ui/templates/$id/name',
                ),
                VibeTextEditor(
                  label: 'description',
                  value: template?['description']?.toString(),
                  dispatch: dispatch,
                  layer: LayerId.components,
                  path: '/ui/templates/$id/description',
                ),
              ],
            ),
            _Section(
              title: 'Parameters',
              initiallyOpen: false,
              indent: 1,
              children: <Widget>[
                VibeJsonEditor(
                  label: 'parameters',
                  value: template?['parameters'],
                  dispatch: dispatch,
                  layer: LayerId.components,
                  path: '/ui/templates/$id/parameters',
                ),
              ],
            ),
            if (!hasTree)
              _Section(
                title: 'Content (raw)',
                indent: 1,
                children: <Widget>[
                  VibeJsonEditor(
                    label: 'content',
                    value: template?['content'],
                    dispatch: dispatch,
                    layer: LayerId.components,
                    path: '/ui/templates/$id/content',
                  ),
                ],
              ),
          ],
        ),
        if (hasTree)
          _Section(
            title: 'Widget tree',
            children: <Widget>[
              WidgetTreeView(
                root: templateRoot,
                selectedPath: selectedWidgetPath,
                onSelect: onSelectWidget ?? (_) {},
              ),
            ],
          ),
        if (hasTree)
          _SelectedWidgetSection(
            root: templateRoot,
            selectedPath: selectedWidgetPath,
            layer: LayerId.components,
            pointerPrefix: '/ui/templates/$id/content',
            dispatch: dispatch,
          ),
      ],
    );
  }
}

class _PagesBody extends StatelessWidget {
  const _PagesBody({
    required this.pages,
    required this.assets,
    required this.dispatch,
    required this.focusedId,
    required this.selectedWidgetPath,
    required this.onSelectWidget,
    this.health,
  });
  final Map<String, PageSlice> pages;
  final AssetSlice assets;
  final PatchDispatcher dispatch;
  final Map<String, dynamic>? health;

  /// Page id selected by the center [InstanceStrip]. Falls back to the
  /// first available page when null.
  final String? focusedId;

  final WidgetPath? selectedWidgetPath;
  final ValueChanged<WidgetPath>? onSelectWidget;

  PageSlice? get _focused {
    if (focusedId != null && pages.containsKey(focusedId)) {
      return pages[focusedId];
    }
    return pages.isNotEmpty ? pages.values.first : null;
  }

  String? _stringy(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is num) return '$v';
    if (v is List) return '${v.length} item${v.length == 1 ? '' : 's'}';
    if (v is Map) return '${v.length} key${v.length == 1 ? '' : 's'}';
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final raw = _focused?.raw ?? const <String, dynamic>{};
    final pageId = _focused?.id;
    final pathPrefix = pageId == null ? '/ui/pages' : '/ui/pages/$pageId';
    final contentRoot = raw['content'];
    final hasTree =
        contentRoot is Map<String, dynamic> && contentRoot.containsKey('type');
    return ListView(
      children: <Widget>[
        _InspectorHealthSection(
          health: health,
          pathPrefix: pageId == null ? '/ui/pages' : '/ui/pages/$pageId',
          scopeLabel: 'this page',
          onSelectWidget: onSelectWidget,
        ),
        _Section(
          title: 'Page settings',
          initiallyOpen: false,
          children: <Widget>[
            _Section(
              title: 'Identity',
              indent: 1,
              children: <Widget>[
                _Field(label: 'id', value: pageId),
                VibeTextEditor(
                  label: 'path',
                  value: _stringy(raw['path']),
                  dispatch: dispatch,
                  layer: LayerId.pages,
                  path: '$pathPrefix/path',
                ),
                VibeTextEditor(
                  label: 'title',
                  value: _stringy(raw['title']),
                  dispatch: dispatch,
                  layer: LayerId.pages,
                  path: '$pathPrefix/title',
                ),
                VibeIconEditor(
                  label: 'icon',
                  value: _stringy(raw['icon']),
                  dispatch: dispatch,
                  layer: LayerId.pages,
                  path: '$pathPrefix/icon',
                  registeredIcons: _iconRefsFromAssets(assets),
                ),
              ],
            ),
            _Section(
              title: 'Theme override',
              initiallyOpen: false,
              indent: 1,
              children: <Widget>[
                VibeJsonEditor(
                  label: 'themeOverride',
                  value: raw['themeOverride'],
                  dispatch: dispatch,
                  layer: LayerId.pages,
                  path: '$pathPrefix/themeOverride',
                ),
              ],
            ),
            _Section(
              title: 'Permissions',
              initiallyOpen: false,
              indent: 1,
              children: <Widget>[
                VibeJsonEditor(
                  label: 'permissions',
                  value: raw['permissions'],
                  dispatch: dispatch,
                  layer: LayerId.pages,
                  path: '$pathPrefix/permissions',
                ),
              ],
            ),
            _Section(
              title: 'Channels',
              initiallyOpen: false,
              indent: 1,
              children: <Widget>[
                VibeJsonEditor(
                  label: 'channels',
                  value: raw['channels'],
                  dispatch: dispatch,
                  layer: LayerId.pages,
                  path: '$pathPrefix/channels',
                ),
              ],
            ),
            _Section(
              title: 'Initial state',
              initiallyOpen: false,
              indent: 1,
              children: <Widget>[
                VibeJsonEditor(
                  label: 'state',
                  value: raw['state'],
                  dispatch: dispatch,
                  layer: LayerId.pages,
                  path: '$pathPrefix/state',
                ),
              ],
            ),
            _Section(
              title: 'Metadata',
              initiallyOpen: false,
              indent: 1,
              children: <Widget>[
                VibeJsonEditor(
                  label: 'metadata',
                  value: raw['metadata'],
                  dispatch: dispatch,
                  layer: LayerId.pages,
                  path: '$pathPrefix/metadata',
                ),
              ],
            ),
            _Section(
              title: 'Lifecycle hooks',
              initiallyOpen: false,
              indent: 1,
              children: <Widget>[
                for (final h in const <String>[
                  'onEnter',
                  'onLeave',
                  'onResume',
                  'onPause',
                ])
                  VibeTextEditor(
                    label: h,
                    value: _stringy(
                      (raw['lifecycle'] is Map)
                          ? (raw['lifecycle'] as Map)[h]
                          : null,
                    ),
                    dispatch: dispatch,
                    layer: LayerId.pages,
                    path: '$pathPrefix/lifecycle/$h',
                  ),
              ],
            ),
            _Section(
              title: 'Error handling',
              initiallyOpen: false,
              indent: 1,
              children: <Widget>[
                VibeJsonEditor(
                  label: 'errors',
                  value: raw['errors'],
                  dispatch: dispatch,
                  layer: LayerId.pages,
                  path: '$pathPrefix/errors',
                ),
              ],
            ),
            _Section(
              title: 'All pages',
              initiallyOpen: false,
              indent: 1,
              children: <Widget>[
                if (pages.isEmpty)
                  const _Field(label: '(no pages yet)', value: null),
                for (final p in pages.values)
                  _Field(label: p.id, value: '${p.raw.length} keys'),
              ],
            ),
          ],
        ),
        if (hasTree)
          _Section(
            title: 'Widget tree',
            children: <Widget>[
              WidgetTreeView(
                root: contentRoot,
                selectedPath: selectedWidgetPath,
                onSelect: onSelectWidget ?? (_) {},
              ),
            ],
          ),
        if (hasTree)
          _SelectedWidgetSection(
            root: contentRoot,
            selectedPath: selectedWidgetPath,
            layer: LayerId.pages,
            pointerPrefix: '$pathPrefix/content',
            dispatch: dispatch,
          ),
      ],
    );
  }
}

/// Editor for the single application dashboard (`ui.dashboard`, spec
/// §11.9). Distinct from the page editor — dashboard is the app's
/// compact preview surface and there's at most one per bundle.
class _DashboardBody extends StatelessWidget {
  const _DashboardBody({
    required this.value,
    required this.dispatch,
    this.health,
  });
  final DashboardSlice? value;
  final PatchDispatcher dispatch;
  final Map<String, dynamic>? health;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final raw = value?.raw ?? const <String, dynamic>{};
    return ListView(
      children: <Widget>[
        _InspectorHealthSection(
          health: health,
          pathPrefix: '/ui/dashboard',
          scopeLabel: 'the dashboard',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            VibeTokens.space3,
            VibeTokens.space2,
            VibeTokens.space3,
            0,
          ),
          child: Text(
            value == null
                ? 'No dashboard yet — add one by editing `content` below.'
                : 'Single application-scoped dashboard (spec §11.9).',
            style: vibeMono(size: 11, color: c.textSecondary),
          ),
        ),
        _Section(
          title: 'Content',
          children: <Widget>[
            VibeJsonEditor(
              label: 'content',
              value: raw['content'],
              dispatch: dispatch,
              layer: LayerId.dashboard,
              path: '/ui/dashboard/content',
            ),
          ],
        ),
        _Section(
          title: 'Refresh',
          initiallyOpen: false,
          children: <Widget>[
            VibeTextEditor(
              label: 'interval (ms)',
              numeric: true,
              value: raw['refreshInterval']?.toString(),
              dispatch: dispatch,
              layer: LayerId.dashboard,
              path: '/ui/dashboard/refreshInterval',
            ),
          ],
        ),
        _Section(
          title: 'On tap',
          initiallyOpen: false,
          children: <Widget>[
            VibeJsonEditor(
              label: 'onTap',
              value: raw['onTap'],
              dispatch: dispatch,
              layer: LayerId.dashboard,
              path: '/ui/dashboard/onTap',
            ),
          ],
        ),
      ],
    );
  }
}

/// Application-level navigation chrome editor. Edits `/ui/navigation`
/// (NavigationConfig per app schema) — type (drawer / bottomBar / rail
/// / tabs) + items[] (label, route, icon, badge). Chrome wraps every
/// page at runtime; authored once at the app level.
class _NavigationBody extends StatelessWidget {
  const _NavigationBody({
    required this.value,
    required this.routes,
    required this.assets,
    required this.dispatch,
    this.health,
  });
  final NavigationSlice? value;
  final List<String> routes;
  final AssetSlice assets;
  final PatchDispatcher dispatch;
  final Map<String, dynamic>? health;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final raw = value?.raw ?? const <String, dynamic>{};
    final items = raw['items'];
    final itemsCount = items is List ? items.length : 0;
    return ListView(
      children: <Widget>[
        _InspectorHealthSection(
          health: health,
          pathPrefix: '/ui/navigation',
          scopeLabel: 'navigation',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            VibeTokens.space3,
            VibeTokens.space2,
            VibeTokens.space3,
            0,
          ),
          child: Text(
            value == null
                ? 'No navigation chrome yet — pick a `type` and add `items` '
                    'to get a drawer / bottom bar / rail / tab strip wrapping '
                    'every page.'
                : '$itemsCount item${itemsCount == 1 ? '' : 's'} · spec '
                    '`NavigationConfig` (drawer / bottomBar / rail / tabs).',
            style: vibeMono(size: 11, color: c.textSecondary),
          ),
        ),
        _Section(
          title: 'Type',
          children: <Widget>[
            VibeEnumEditor(
              label: 'type',
              value: raw['type'] as String?,
              options: const <String>['drawer', 'bottomBar', 'rail', 'tabs'],
              dispatch: dispatch,
              layer: LayerId.navigation,
              path: '/ui/navigation/type',
            ),
          ],
        ),
        _Section(
          title: 'Items',
          children: <Widget>[
            _NavigationItemsEditor(
              items:
                  items is List
                      ? List<Map<String, dynamic>>.unmodifiable(
                        items.whereType<Map>().map(Map<String, dynamic>.from),
                      )
                      : const <Map<String, dynamic>>[],
              routes: routes,
              assets: assets,
              dispatch: dispatch,
            ),
          ],
        ),
        _Section(
          title: 'Header / Footer',
          initiallyOpen: false,
          children: <Widget>[
            VibeJsonEditor(
              label: 'header',
              value: raw['header'],
              dispatch: dispatch,
              layer: LayerId.navigation,
              path: '/ui/navigation/header',
            ),
            VibeJsonEditor(
              label: 'footer',
              value: raw['footer'],
              dispatch: dispatch,
              layer: LayerId.navigation,
              path: '/ui/navigation/footer',
            ),
          ],
        ),
        // Spec 1.3.4 Phase 5 — NavigationStyle (background / indicator
        // / divider / labels / icons / selected colors / elevation).
        _Section(
          title: 'Style',
          initiallyOpen: false,
          children: <Widget>[
            _NavigationStyleEditor(
              value:
                  raw['style'] is Map
                      ? Map<String, dynamic>.from(raw['style'] as Map)
                      : const <String, dynamic>{},
              dispatch: dispatch,
              layer: LayerId.navigation,
              basePath: '/ui/navigation/style',
            ),
          ],
        ),
      ],
    );
  }
}

/// Asset registry body — surfaces `manifest.assets.assets[]`
/// (mcp_bundle `AssetSection`) as a list editor. Each row shows id /
/// type / path-or-contentRef + delete. The "Import file" button
/// copies a local file into `.mbd/assets/<auto-folder>/<name>` and
/// auto-fills the entry meta (path, mimeType, hash, size). Material
/// / URL / inline assets are added through "Add reference" which
/// only persists the entry (no file copy).
///
/// All edits round-trip through the same dispatch the rest of the
/// panel uses, so the per-channel autosave / undo / draft / spec
/// validator work the same as for ui-side patches.
class _AssetsBody extends StatefulWidget {
  const _AssetsBody({
    required this.assets,
    required this.dispatch,
    this.onImport,
    this.bundlePath,
    this.health,
  });
  final AssetSlice assets;
  final PatchDispatcher dispatch;
  final Map<String, dynamic>? health;

  /// File picker + copy + meta builder, supplied by the shell. Null
  /// when the host hasn't wired it (e.g. preview tracks). Returns
  /// a complete `Asset` entry the body appends to the registry.
  final Future<Map<String, dynamic>?> Function()? onImport;

  /// Absolute path to the channel's `.mbd/` so per-row previews can
  /// resolve `<bundlePath>/<asset.path>` to actual file bytes for
  /// image thumbnails. Null disables file-backed previews; ref-only
  /// assets (Material / URL / data:) still preview from their refs.
  final String? bundlePath;

  @override
  State<_AssetsBody> createState() => _AssetsBodyState();
}

class _AssetsBodyState extends State<_AssetsBody> {
  final TextEditingController _newId = TextEditingController();
  final TextEditingController _newRef = TextEditingController();
  String _newType = 'icon';

  /// Currently expanded row's id. Only one row's editor is open at a
  /// time so the list stays compact.
  String? _expandedId;

  @override
  void dispose() {
    _newId.dispose();
    _newRef.dispose();
    super.dispose();
  }

  /// Replace one entry in the registry. Looks up by id, mutates, and
  /// dispatches a fresh array. Same path as add / remove.
  Future<void> _updateAt(String id, Map<String, dynamic> updated) async {
    final next = <Map<String, dynamic>>[];
    for (final e in widget.assets.entries) {
      if (e['id'] == id) {
        next.add(updated);
      } else {
        next.add(e);
      }
    }
    await _writeAll(next);
  }

  Future<void> _writeAll(List<Map<String, dynamic>> next) async {
    // mcp_bundle stores `assets` as a section: { schemaVersion,
    // assets:[...], directories:[...], bundles:[...] }. We only
    // touch the `assets` array; the other fields stay as the user
    // (or future tools) authored them.
    final base = Map<String, dynamic>.from(widget.assets.raw);
    base['assets'] = next;
    if (!base.containsKey('schemaVersion')) base['schemaVersion'] = '1.0.0';
    await widget.dispatch(
      layer: LayerId.assets,
      path: '/manifest/assets',
      value: base,
    );
  }

  Future<void> _addReference() async {
    final id = _newId.text.trim();
    final ref = _newRef.text.trim();
    if (id.isEmpty || ref.isEmpty) return;
    if (widget.assets.entries.any((e) => e['id'] == id)) return;
    final entry = <String, dynamic>{
      'id': id,
      'type': _newType,
      'contentRef': ref,
    };
    final next = <Map<String, dynamic>>[...widget.assets.entries, entry];
    await _writeAll(next);
    if (mounted) {
      setState(() {
        _newId.clear();
        _newRef.clear();
      });
    }
  }

  Future<void> _importFile() async {
    final cb = widget.onImport;
    if (cb == null) return;
    final entry = await cb();
    if (entry == null) return;
    // Reject id collisions — the shell already auto-deduplicates the
    // proposed id, but stay defensive in case a parallel canonical
    // patch added the same id between picker and dispatch.
    final id = '${entry['id'] ?? ''}';
    if (id.isEmpty || widget.assets.entries.any((e) => e['id'] == id)) {
      return;
    }
    final next = <Map<String, dynamic>>[...widget.assets.entries, entry];
    await _writeAll(next);
  }

  Future<void> _removeAt(int index) async {
    if (index < 0 || index >= widget.assets.entries.length) return;
    final next = <Map<String, dynamic>>[...widget.assets.entries]
      ..removeAt(index);
    await _writeAll(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final entries = widget.assets.entries;
    return ListView(
      children: <Widget>[
        _InspectorHealthSection(
          health: widget.health,
          // Asset findings primarily live under /manifest/assets
          // (asset_audit), so scope the section there.
          pathPrefix: '/manifest/assets',
          scopeLabel: 'assets',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            VibeTokens.space3,
            VibeTokens.space2,
            VibeTokens.space3,
            0,
          ),
          child: Text(
            entries.isEmpty
                ? 'No assets registered. Add an icon / image / font here, '
                    'then reference it from widgets as `bundle://<id>`.'
                : '${entries.length} asset'
                    '${entries.length == 1 ? '' : 's'} registered. '
                    'Reference from widgets as `bundle://<id>`.',
            style: vibeMono(size: 11, color: c.textSecondary),
          ),
        ),
        _Section(
          title: 'Registered',
          children: <Widget>[
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  VibeTokens.space4,
                  VibeTokens.space2,
                  VibeTokens.space4,
                  VibeTokens.space2,
                ),
                child: Text(
                  '— empty —',
                  style: vibeMono(size: 11, color: c.textTertiary),
                ),
              )
            else
              for (var i = 0; i < entries.length; i++)
                _AssetRow(
                  key: ValueKey<String>('${entries[i]['id']}'),
                  entry: entries[i],
                  bundlePath: widget.bundlePath,
                  expanded: _expandedId == entries[i]['id'],
                  onTapToggle:
                      () => setState(() {
                        final id = '${entries[i]['id']}';
                        _expandedId = _expandedId == id ? null : id;
                      }),
                  onSave:
                      (updated) => _updateAt('${entries[i]['id']}', updated),
                  onDelete: () => _removeAt(i),
                ),
          ],
        ),
        _Section(
          title: 'Add reference',
          initiallyOpen: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                VibeTokens.space4,
                VibeTokens.space1,
                VibeTokens.space4,
                VibeTokens.space2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(
                        flex: 3,
                        child: VibeCompactInputBox(
                          child: TextField(
                            controller: _newId,
                            style: vibeMono(size: 11, color: c.textPrimary),
                            decoration: InputDecoration(
                              isDense: true,
                              isCollapsed: true,
                              filled: false,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              hintText: 'id',
                              hintStyle: vibeMono(
                                size: 11,
                                color: c.textTertiary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: VibeTokens.space1),
                      Expanded(
                        flex: 2,
                        child: VibeCompactDropdown<String>(
                          value: _newType,
                          options: const <String>[
                            'icon',
                            'image',
                            'font',
                            'audio',
                            'video',
                            'json',
                            'text',
                            'binary',
                            'template',
                            'style',
                            'file',
                          ],
                          labelOf: (s) => s,
                          onChanged:
                              (v) => setState(() => _newType = v ?? 'icon'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: VibeTokens.space1),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      Expanded(
                        child: VibeCompactInputBox(
                          child: TextField(
                            controller: _newRef,
                            style: vibeMono(size: 11, color: c.textPrimary),
                            decoration: InputDecoration(
                              isDense: true,
                              isCollapsed: true,
                              filled: false,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              focusedErrorBorder: InputBorder.none,
                              hintText: 'https://… / data:… / assets/…svg',
                              hintStyle: vibeMono(
                                size: 11,
                                color: c.textTertiary,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: VibeTokens.space1),
                      SizedBox(
                        width: 24,
                        height: 28,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          constraints: const BoxConstraints.tightFor(
                            width: 24,
                            height: 28,
                          ),
                          icon: const Icon(Icons.add),
                          color: c.textSecondary,
                          tooltip: 'Add reference',
                          onPressed:
                              (_newId.text.trim().isEmpty ||
                                      _newRef.text.trim().isEmpty)
                                  ? null
                                  : _addReference,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        _Section(
          title: 'Import file',
          initiallyOpen: true,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                VibeTokens.space4,
                VibeTokens.space1,
                VibeTokens.space4,
                VibeTokens.space2,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.onImport == null
                          ? 'File import unavailable in this preview.'
                          : 'Pick an image / icon / font / file to copy '
                              'into .mbd/assets/. Meta is filled in '
                              'automatically.',
                      style: vibeMono(size: 11, color: c.textSecondary),
                    ),
                  ),
                  const SizedBox(width: VibeTokens.space2),
                  TextButton.icon(
                    onPressed: widget.onImport == null ? null : _importFile,
                    icon: const Icon(Icons.upload_file_outlined, size: 14),
                    label: const Text('Pick file'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: VibeTokens.space2,
                      ),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      foregroundColor: c.textPrimary,
                      backgroundColor: c.surface2,
                      side: BorderSide(color: c.borderDefault),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _AssetRow extends StatefulWidget {
  const _AssetRow({
    super.key,
    required this.entry,
    required this.bundlePath,
    required this.expanded,
    required this.onTapToggle,
    required this.onSave,
    required this.onDelete,
  });
  final Map<String, dynamic> entry;
  final String? bundlePath;
  final bool expanded;
  final VoidCallback onTapToggle;
  final ValueChanged<Map<String, dynamic>> onSave;
  final VoidCallback onDelete;

  @override
  State<_AssetRow> createState() => _AssetRowState();
}

class _AssetRowState extends State<_AssetRow> {
  late final TextEditingController _id;
  late final TextEditingController _ref;
  late final TextEditingController _path;
  late String _type;

  @override
  void initState() {
    super.initState();
    _id = TextEditingController(text: '${widget.entry['id'] ?? ''}');
    _ref = TextEditingController(text: '${widget.entry['contentRef'] ?? ''}');
    _path = TextEditingController(text: '${widget.entry['path'] ?? ''}');
    _type = '${widget.entry['type'] ?? 'file'}';
  }

  @override
  void didUpdateWidget(covariant _AssetRow old) {
    super.didUpdateWidget(old);
    if (old.entry != widget.entry) {
      _id.text = '${widget.entry['id'] ?? ''}';
      _ref.text = '${widget.entry['contentRef'] ?? ''}';
      _path.text = '${widget.entry['path'] ?? ''}';
      _type = '${widget.entry['type'] ?? 'file'}';
    }
  }

  @override
  void dispose() {
    _id.dispose();
    _ref.dispose();
    _path.dispose();
    super.dispose();
  }

  void _commit() {
    final updated = Map<String, dynamic>.from(widget.entry);
    final newId = _id.text.trim();
    if (newId.isNotEmpty) updated['id'] = newId;
    updated['type'] = _type;
    final ref = _ref.text.trim();
    final path = _path.text.trim();
    if (ref.isEmpty) {
      updated.remove('contentRef');
    } else {
      updated['contentRef'] = ref;
    }
    if (path.isEmpty) {
      updated.remove('path');
    } else {
      updated['path'] = path;
    }
    widget.onSave(updated);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final id = '${widget.entry['id'] ?? '?'}';
    final type = '${widget.entry['type'] ?? '?'}';
    final ref = '${widget.entry['contentRef'] ?? widget.entry['path'] ?? '?'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VibeTokens.space4,
        VibeTokens.space1,
        VibeTokens.space4,
        VibeTokens.space1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: widget.onTapToggle,
            borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  _AssetThumbnail(
                    entry: widget.entry,
                    bundlePath: widget.bundlePath,
                    size: 24,
                  ),
                  const SizedBox(width: VibeTokens.space1),
                  Expanded(
                    flex: 3,
                    child: Text(
                      id,
                      style: vibeMono(size: 11, color: c.textPrimary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: VibeTokens.space1),
                  SizedBox(
                    width: 56,
                    child: Text(
                      type,
                      style: vibeMono(size: 10, color: c.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: VibeTokens.space1),
                  Expanded(
                    flex: 5,
                    child: Text(
                      ref,
                      style: vibeMono(size: 10, color: c.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    widget.expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: c.textTertiary,
                  ),
                  SizedBox(
                    width: 24,
                    height: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 14,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 28,
                      ),
                      icon: const Icon(Icons.close),
                      color: c.textTertiary,
                      tooltip: 'Remove',
                      onPressed: widget.onDelete,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                28,
                VibeTokens.space2,
                0,
                VibeTokens.space2,
              ),
              child: Container(
                padding: const EdgeInsets.all(VibeTokens.space2),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                  border: Border.all(color: c.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // Larger preview to confirm visual identity. For
                    // ref-only entries this resolves Material icons /
                    // image URLs / data: URIs the same way the row
                    // thumbnail does, just bigger.
                    Center(
                      child: _AssetThumbnail(
                        entry: widget.entry,
                        bundlePath: widget.bundlePath,
                        size: 96,
                      ),
                    ),
                    const SizedBox(height: VibeTokens.space2),
                    _editorRow('id', _id),
                    _editorTypeRow((v) => setState(() => _type = v)),
                    _editorRow(
                      'contentRef',
                      _ref,
                      hint: 'https://… / data:… / assets/…svg',
                    ),
                    _editorRow('path', _path, hint: 'assets/…  (file-backed)'),
                    const SizedBox(height: VibeTokens.space1),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        TextButton(
                          onPressed: widget.onTapToggle,
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: VibeTokens.space1),
                        FilledButton(
                          onPressed: _commit,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _editorRow(String label, TextEditingController ctrl, {String? hint}) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: vibeMono(size: 11, color: c.textSecondary),
            ),
          ),
          Expanded(
            child: VibeCompactInputBox(
              child: TextField(
                controller: ctrl,
                style: vibeMono(size: 11, color: c.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  isCollapsed: true,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  hintText: hint,
                  hintStyle: vibeMono(size: 11, color: c.textTertiary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editorTypeRow(ValueChanged<String> onChanged) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 80,
            child: Text(
              'type',
              style: vibeMono(size: 11, color: c.textSecondary),
            ),
          ),
          Expanded(
            child: VibeCompactDropdown<String>(
              value: _type,
              options: const <String>[
                'icon',
                'image',
                'font',
                'audio',
                'video',
                'json',
                'text',
                'binary',
                'template',
                'style',
                'file',
              ],
              labelOf: (s) => s,
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Visual preview of one asset entry. Picks the best representation
/// based on type + source: Material icons resolve through
/// `resolveIconData`, file-backed images load `<bundlePath>/<path>`,
/// URL/data refs render as a small image when possible. Fallback for
/// unrenderable types (font/audio/video/etc.) is a type-specific
/// Material icon so the row still has a visual anchor.
class _AssetThumbnail extends StatelessWidget {
  const _AssetThumbnail({
    required this.entry,
    required this.bundlePath,
    required this.size,
  });
  final Map<String, dynamic> entry;
  final String? bundlePath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final type = '${entry['type'] ?? ''}';
    final ref = entry['contentRef'];
    final path = entry['path'];
    final box = SizedBox(
      width: size,
      height: size,
      child: _resolve(c, type, ref, path),
    );
    return box;
  }

  Widget _resolve(dynamic c, String type, dynamic ref, dynamic path) {
    // Material icon ref — resolve through the runtime's name table so
    // the preview matches what the user will see in the rendered app.
    if (ref is String && ref.startsWith('material:')) {
      return Icon(
        resolveIconData(ref.substring('material:'.length)),
        size: size * 0.7,
        color: c.textPrimary,
      );
    }
    // data: URI — best effort decode for image MIME types.
    if (ref is String && ref.startsWith('data:image')) {
      try {
        final commaIdx = ref.indexOf(',');
        if (commaIdx > 0) {
          final header = ref.substring(0, commaIdx);
          final payload = ref.substring(commaIdx + 1);
          if (header.contains(';base64')) {
            final bytes = base64Decode(payload);
            return Image.memory(
              bytes,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => _typeIcon(c, type),
            );
          }
        }
      } catch (_) {}
      return _typeIcon(c, type);
    }
    // Network URL — Image.network handles fetch + cache.
    if (ref is String &&
        (ref.startsWith('http://') || ref.startsWith('https://')) &&
        (type == 'image' || type == 'icon')) {
      return Image.network(
        ref,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _typeIcon(c, type),
      );
    }
    // File-backed asset (image/icon raster) — load `<bundle>/<path>`.
    if (path is String &&
        path.isNotEmpty &&
        bundlePath != null &&
        (type == 'image' || type == 'icon')) {
      final file = File(p.join(bundlePath!, path));
      // SVG isn't decoded by Image.file natively; fallback to icon.
      if (path.toLowerCase().endsWith('.svg')) return _typeIcon(c, type);
      return Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _typeIcon(c, type),
      );
    }
    return _typeIcon(c, type);
  }

  Widget _typeIcon(dynamic c, String type) {
    IconData icon;
    switch (type) {
      case 'image':
      case 'icon':
        icon = Icons.image_outlined;
        break;
      case 'font':
        icon = Icons.text_fields;
        break;
      case 'audio':
        icon = Icons.audiotrack;
        break;
      case 'video':
        icon = Icons.movie_outlined;
        break;
      case 'json':
      case 'text':
        icon = Icons.description_outlined;
        break;
      case 'template':
        icon = Icons.code;
        break;
      case 'style':
        icon = Icons.palette_outlined;
        break;
      default:
        icon = Icons.insert_drive_file_outlined;
    }
    return Icon(icon, size: size * 0.7, color: c.textSecondary);
  }
}

/// Per-item editor for `/ui/navigation/items`. Each row carries a
/// label, a route picked from the existing `/ui/routes` keys
/// (dropdown), and an optional icon. Add / remove / edit always
/// dispatch a full-array replace so the patch stays atomic and the
/// validator sees the final shape.
class _NavigationItemsEditor extends StatefulWidget {
  const _NavigationItemsEditor({
    required this.items,
    required this.routes,
    required this.assets,
    required this.dispatch,
  });
  final List<Map<String, dynamic>> items;
  final List<String> routes;
  final AssetSlice assets;
  final PatchDispatcher dispatch;

  @override
  State<_NavigationItemsEditor> createState() => _NavigationItemsEditorState();
}

class _NavigationItemsEditorState extends State<_NavigationItemsEditor> {
  final TextEditingController _newLabel = TextEditingController();
  final TextEditingController _newIcon = TextEditingController();
  String? _newRoute;

  @override
  void initState() {
    super.initState();
    // Repaint icon preview whenever the user types — `resolveIconData`
    // is O(1) so we don't debounce.
    _newIcon.addListener(_onIconChanged);
  }

  void _onIconChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _newIcon.removeListener(_onIconChanged);
    _newLabel.dispose();
    _newIcon.dispose();
    super.dispose();
  }

  Future<void> _writeAll(List<Map<String, dynamic>> next) async {
    await widget.dispatch(
      layer: LayerId.navigation,
      path: '/ui/navigation/items',
      value: next,
    );
  }

  /// Surface registered icon-typed assets as picker entries. Other
  /// asset types (image / font / video / …) are filtered out — the
  /// nav item icon slot only renders icons.
  List<({String id, String? contentRef})> _registeredIconRefs() {
    return widget.assets.entries
        .where((e) => e['type'] == 'icon')
        .map(
          (e) => (
            id: '${e['id'] ?? ''}',
            contentRef:
                e['contentRef'] is String ? e['contentRef'] as String : null,
          ),
        )
        .where((e) => e.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> _addItem() async {
    final label = _newLabel.text.trim();
    final route = _newRoute;
    final icon = _newIcon.text.trim();
    if (label.isEmpty || route == null) return;
    final next = <Map<String, dynamic>>[
      ...widget.items,
      <String, dynamic>{
        'label': label,
        'route': route,
        if (icon.isNotEmpty) 'icon': icon,
      },
    ];
    await _writeAll(next);
    if (mounted) {
      setState(() {
        _newLabel.clear();
        _newIcon.clear();
        _newRoute = null;
      });
    }
  }

  Future<void> _removeAt(int index) async {
    if (index < 0 || index >= widget.items.length) return;
    final next = <Map<String, dynamic>>[...widget.items]..removeAt(index);
    await _writeAll(next);
  }

  Future<void> _setRouteAt(int index, String? route) async {
    if (route == null || route.isEmpty) return;
    if (index < 0 || index >= widget.items.length) return;
    final updated = Map<String, dynamic>.from(widget.items[index])
      ..['route'] = route;
    final next = <Map<String, dynamic>>[...widget.items];
    next[index] = updated;
    await _writeAll(next);
  }

  /// Move the item at [from] to [to] (in-place swap when adjacent).
  /// Bounds-checked; out-of-range calls are silently dropped so the
  /// edge buttons can stay wired without an extra null dance.
  Future<void> _moveItem(int from, int to) async {
    if (from < 0 || from >= widget.items.length) return;
    if (to < 0 || to >= widget.items.length) return;
    if (from == to) return;
    final next = <Map<String, dynamic>>[...widget.items];
    final picked = next.removeAt(from);
    next.insert(to, picked);
    await _writeAll(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VibeTokens.space4,
        VibeTokens.space2,
        VibeTokens.space4,
        VibeTokens.space2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: VibeTokens.space2),
              child: Text(
                'no items — drag handle ≡ to reorder once added',
                style: vibeMono(size: 11, color: c.textTertiary),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: widget.items.length,
              proxyDecorator:
                  (child, index, animation) =>
                      _DragProxyDecorator(child: child),
              onReorder: (oldIndex, newIndex) {
                // Flutter's onReorder gives newIndex relative to the
                // pre-removal list, so a downward move needs the
                // canonical -1 adjustment.
                final adjusted = newIndex > oldIndex ? newIndex - 1 : newIndex;
                _moveItem(oldIndex, adjusted);
              },
              itemBuilder: (context, i) {
                return _NavItemRow(
                  key: ValueKey<int>(i),
                  index: i,
                  label: '${widget.items[i]['label'] ?? ''}',
                  route: '${widget.items[i]['route'] ?? ''}',
                  icon:
                      widget.items[i]['icon'] is String
                          ? widget.items[i]['icon'] as String
                          : null,
                  routes: widget.routes,
                  onRouteChanged: (v) => _setRouteAt(i, v),
                  onDelete: () => _removeAt(i),
                );
              },
            ),
          const SizedBox(height: VibeTokens.space2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              // Spacer matching the drag-handle width on data rows so
              // the bottom add-row's columns line up with the rows
              // above it (label, route, icon all start at same x).
              const SizedBox(width: 18),
              Expanded(
                flex: 3,
                child: VibeCompactInputBox(
                  child: TextField(
                    controller: _newLabel,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      filled: false,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      hintText: 'label',
                      hintStyle: vibeMono(size: 11, color: c.textTertiary),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: VibeTokens.space1),
              Expanded(
                flex: 3,
                child: VibeCompactDropdown<String>(
                  value: _newRoute,
                  options: widget.routes,
                  labelOf: (s) => s,
                  placeholder: 'route',
                  onChanged: (v) => setState(() => _newRoute = v),
                ),
              ),
              const SizedBox(width: VibeTokens.space1),
              Expanded(
                flex: 2,
                child: VibeCompactInputBox(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      const SizedBox(width: 4),
                      Expanded(
                        child: TextField(
                          controller: _newIcon,
                          style: vibeMono(size: 11, color: c.textPrimary),
                          decoration: InputDecoration(
                            isDense: true,
                            isCollapsed: true,
                            filled: false,
                            contentPadding: EdgeInsets.zero,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            hintText: 'icon',
                            hintStyle: vibeMono(
                              size: 11,
                              color: c.textTertiary,
                            ),
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: () async {
                          final picked = await showVibeIconPicker(
                            context,
                            registeredIcons: _registeredIconRefs(),
                            currentValue: _newIcon.text,
                          );
                          if (picked != null && mounted) {
                            setState(() => _newIcon.text = picked);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Icon(
                            Icons.arrow_drop_down,
                            size: 14,
                            color: c.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 24,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 28,
                  ),
                  icon: const Icon(Icons.add),
                  color: c.textSecondary,
                  tooltip: 'Add nav item',
                  onPressed:
                      (_newLabel.text.trim().isEmpty || _newRoute == null)
                          ? null
                          : _addItem,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NavItemRow extends StatelessWidget {
  const _NavItemRow({
    super.key,
    required this.index,
    required this.label,
    required this.route,
    required this.icon,
    required this.routes,
    required this.onRouteChanged,
    required this.onDelete,
  });

  /// Position inside the parent list. Required by
  /// `ReorderableDragStartListener` so the framework knows which
  /// row a drag gesture belongs to.
  final int index;
  final String label;
  final String route;
  final String? icon;
  final List<String> routes;
  final ValueChanged<String?> onRouteChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final missingRoute = route.isNotEmpty && !routes.contains(route);
    return Padding(
      key: ValueKey<int>(index),
      padding: const EdgeInsets.only(bottom: VibeTokens.space1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: SizedBox(
                width: 18,
                height: 28,
                child: Icon(
                  Icons.drag_indicator,
                  size: 14,
                  color: c.textTertiary,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              label.isEmpty ? '—' : label,
              style: vibeMono(
                size: 11,
                color: label.isEmpty ? c.textTertiary : c.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: VibeTokens.space1),
          Expanded(
            flex: 3,
            child: VibeCompactDropdown<String>(
              value: route.isEmpty ? null : route,
              options: routes,
              labelOf: (s) => s,
              placeholder: 'route',
              warning: missingRoute,
              onChanged: onRouteChanged,
            ),
          ),
          const SizedBox(width: VibeTokens.space1),
          Expanded(
            flex: 2,
            child: Text(
              icon ?? '—',
              style: vibeMono(
                size: 11,
                color: icon == null ? c.textTertiary : c.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 24,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 14,
              constraints: const BoxConstraints.tightFor(width: 24, height: 28),
              icon: const Icon(Icons.close),
              color: c.textTertiary,
              tooltip: 'Remove item',
              onPressed: onDelete,
            ),
          ),
        ],
      ),
    );
  }
}

/// Generic chip-row editor for a `List<String>` value at [path].
/// Used by I18n.locales, FontRegistry.fallbacks, etc. Adds /
/// removes always dispatch a full-array replace so the patch
/// pipeline sees the final shape atomically.
class _StringListEditor extends StatefulWidget {
  const _StringListEditor({
    required this.label,
    required this.values,
    required this.dispatch,
    required this.layer,
    required this.path,
    this.placeholder,
  });
  final String label;
  final List<String> values;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String path;
  final String? placeholder;

  @override
  State<_StringListEditor> createState() => _StringListEditorState();
}

class _StringListEditorState extends State<_StringListEditor> {
  late final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _commit(List<String> next) {
    return widget.dispatch(
      layer: widget.layer,
      path: widget.path,
      value: next.isEmpty ? null : next,
    );
  }

  Future<void> _add() async {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    final cur = widget.values;
    if (cur.contains(v)) {
      _ctrl.clear();
      return;
    }
    await _commit(<String>[...cur, v]);
    if (mounted) _ctrl.clear();
  }

  Future<void> _remove(int i) async {
    final next = <String>[...widget.values]..removeAt(i);
    await _commit(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            height: 28,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.label,
                    style: vibeMono(size: 12, color: c.textSecondary),
                  ),
                ),
                Text(
                  widget.values.isEmpty ? '—' : '${widget.values.length}',
                  style: vibeMono(size: 11, color: c.textTertiary),
                ),
              ],
            ),
          ),
          if (widget.values.isNotEmpty)
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                for (int i = 0; i < widget.values.length; i++)
                  _Chip(label: widget.values[i], onRemove: () => _remove(i)),
              ],
            ),
          const SizedBox(height: 4),
          SizedBox(
            height: 28,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: VibeCompactInputBox(
                    child: TextField(
                      controller: _ctrl,
                      style: vibeMono(size: 11, color: c.textPrimary),
                      decoration: InputDecoration(
                        isDense: true,
                        isCollapsed: true,
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 6,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: widget.placeholder ?? 'add…',
                        hintStyle: vibeMono(size: 11, color: c.textTertiary),
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                ),
                SizedBox(
                  width: 24,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 14,
                    constraints: const BoxConstraints.tightFor(
                      width: 24,
                      height: 28,
                    ),
                    icon: const Icon(Icons.add),
                    color: c.textSecondary,
                    onPressed: _add,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onRemove});
  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        border: Border.all(color: c.borderDefault),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: vibeMono(size: 11, color: c.textPrimary)),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(Icons.close, size: 12, color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Typed NavigationStyle editor (spec 1.3.4 §05_Theme.md, configs/
/// _primitive/NavigationStyle.yaml). Slot-by-slot fields beat raw
/// JSON for visual settings — every slot dispatches an upsert at its
/// own pointer so the patch is small and validator-friendly.
class _NavigationStyleEditor extends StatelessWidget {
  const _NavigationStyleEditor({
    required this.value,
    required this.dispatch,
    required this.basePath,
    required this.layer,
  });
  final Map<String, dynamic> value;
  final PatchDispatcher dispatch;

  /// `/ui/navigation/style` for the global surface, or `/ui/
  /// navigation/items/<i>/style` for per-item overrides.
  final String basePath;
  final LayerId layer;

  String? _str(String key) {
    final v = value[key];
    if (v == null) return null;
    if (v is String) return v;
    if (v is num || v is bool) return v.toString();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final iconStyle =
        (value['iconStyle'] is Map)
            ? Map<String, dynamic>.from(value['iconStyle'] as Map)
            : const <String, dynamic>{};
    return Column(
      children: <Widget>[
        VibeColorEditor(
          label: 'backgroundColor',
          value: _str('backgroundColor'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/backgroundColor',
        ),
        VibeColorEditor(
          label: 'indicatorColor',
          value: _str('indicatorColor'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/indicatorColor',
        ),
        VibeColorEditor(
          label: 'dividerColor',
          value: _str('dividerColor'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/dividerColor',
        ),
        VibeTextEditor(
          label: 'dividerThickness',
          numeric: true,
          value: _str('dividerThickness'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/dividerThickness',
        ),
        VibeTextEditor(
          label: 'dividerIndent',
          numeric: true,
          value: _str('dividerIndent'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/dividerIndent',
        ),
        VibeColorEditor(
          label: 'selectedColor',
          value: _str('selectedColor'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/selectedColor',
        ),
        VibeColorEditor(
          label: 'unselectedColor',
          value: _str('unselectedColor'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/unselectedColor',
        ),
        VibeTextEditor(
          label: 'elevation',
          numeric: true,
          value: _str('elevation'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/elevation',
        ),
        VibeColorEditor(
          label: 'iconStyle.color',
          value:
              iconStyle['color'] is String
                  ? iconStyle['color'] as String
                  : null,
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/iconStyle/color',
        ),
        VibeTextEditor(
          label: 'iconStyle.size',
          numeric: true,
          value: iconStyle['size'] != null ? '${iconStyle['size']}' : null,
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/iconStyle/size',
        ),
        // Nested primitives — typed sub-editors per
        // configs/_primitive/{TextStyle,BorderRadius,BackgroundImage}.
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Text(
            'labelStyle (TextStyle)',
            style: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
        _TextStyleEditor(
          value:
              value['labelStyle'] is Map
                  ? Map<String, dynamic>.from(value['labelStyle'] as Map)
                  : const <String, dynamic>{},
          dispatch: dispatch,
          layer: layer,
          basePath: '$basePath/labelStyle',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Text(
            'indicatorShape (BorderRadius)',
            style: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
        _BorderRadiusEditor(
          value: value['indicatorShape'],
          dispatch: dispatch,
          layer: layer,
          basePath: '$basePath/indicatorShape',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Text(
            'backgroundImage (BackgroundImage)',
            style: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
        _BackgroundImageEditor(
          value:
              value['backgroundImage'] is Map
                  ? Map<String, dynamic>.from(value['backgroundImage'] as Map)
                  : const <String, dynamic>{},
          dispatch: dispatch,
          layer: layer,
          basePath: '$basePath/backgroundImage',
        ),
      ],
    );
  }
}

/// Per-row TemplateLibraryRef editor — list of `{uri, version,
/// integrity}` entries. Add / remove always dispatch a full-array
/// replace; per-row edits dispatch the `/items/<i>/<field>` upsert.
class _TemplateLibrariesEditor extends StatefulWidget {
  const _TemplateLibrariesEditor({
    required this.entries,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final List<Map<String, dynamic>> entries;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  @override
  State<_TemplateLibrariesEditor> createState() =>
      _TemplateLibrariesEditorState();
}

class _TemplateLibrariesEditorState extends State<_TemplateLibrariesEditor> {
  final _newUri = TextEditingController();
  final _newVersion = TextEditingController();
  final _newIntegrity = TextEditingController();

  @override
  void dispose() {
    _newUri.dispose();
    _newVersion.dispose();
    _newIntegrity.dispose();
    super.dispose();
  }

  Future<void> _commit(List<Map<String, dynamic>> next) {
    return widget.dispatch(
      layer: widget.layer,
      path: widget.basePath,
      value: next.isEmpty ? null : next,
    );
  }

  Future<void> _add() async {
    final uri = _newUri.text.trim();
    if (uri.isEmpty) return;
    final entry = <String, dynamic>{
      'uri': uri,
      if (_newVersion.text.trim().isNotEmpty)
        'version': _newVersion.text.trim(),
      if (_newIntegrity.text.trim().isNotEmpty)
        'integrity': _newIntegrity.text.trim(),
    };
    await _commit(<Map<String, dynamic>>[...widget.entries, entry]);
    if (!mounted) return;
    _newUri.clear();
    _newVersion.clear();
    _newIntegrity.clear();
  }

  Future<void> _remove(int i) async {
    final next = <Map<String, dynamic>>[...widget.entries]..removeAt(i);
    await _commit(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < widget.entries.length; i++)
            _LibRow(
              entry: widget.entries[i],
              onRemove: () => _remove(i),
              onChange:
                  (k, v) => widget.dispatch(
                    layer: widget.layer,
                    path: '${widget.basePath}/$i/$k',
                    value: v,
                  ),
            ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                flex: 4,
                child: VibeCompactInputBox(
                  child: TextField(
                    controller: _newUri,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'uri',
                      hintStyle: vibeMono(size: 11, color: c.textTertiary),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                flex: 2,
                child: VibeCompactInputBox(
                  child: TextField(
                    controller: _newVersion,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'version',
                      hintStyle: vibeMono(size: 11, color: c.textTertiary),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                flex: 3,
                child: VibeCompactInputBox(
                  child: TextField(
                    controller: _newIntegrity,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'integrity',
                      hintStyle: vibeMono(size: 11, color: c.textTertiary),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 24,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 28,
                  ),
                  icon: const Icon(Icons.add),
                  color: c.textSecondary,
                  onPressed: _add,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _LibRow extends StatelessWidget {
  const _LibRow({
    required this.entry,
    required this.onRemove,
    required this.onChange,
  });
  final Map<String, dynamic> entry;
  final VoidCallback onRemove;
  final void Function(String key, dynamic value) onChange;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 4,
            child: SelectableText(
              '${entry['uri'] ?? ''}',
              style: vibeMono(size: 11, color: c.textPrimary),
              maxLines: 1,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 2,
            child: Text(
              '${entry['version'] ?? ''}',
              style: vibeMono(size: 11, color: c.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 3,
            child: Text(
              '${entry['integrity'] ?? ''}',
              style: vibeMono(size: 11, color: c.textTertiary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 24,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 14,
              constraints: const BoxConstraints.tightFor(width: 24, height: 28),
              icon: const Icon(Icons.close),
              color: c.textTertiary,
              onPressed: onRemove,
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-entry ServiceDefinition editor — map keyed by service name.
/// Each entry expands to typed fields (kind / interval / tool /
/// binding / autoStart) + JSON for params / onMessage / onError.
class _ServicesEditor extends StatefulWidget {
  const _ServicesEditor({
    required this.services,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final Map<String, dynamic> services;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  @override
  State<_ServicesEditor> createState() => _ServicesEditorState();
}

class _ServicesEditorState extends State<_ServicesEditor> {
  final _newName = TextEditingController();

  @override
  void dispose() {
    _newName.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _newName.text.trim();
    if (name.isEmpty || widget.services.containsKey(name)) return;
    await widget.dispatch(
      layer: widget.layer,
      path: '${widget.basePath}/$name',
      value: <String, dynamic>{'kind': 'polling', 'autoStart': true},
    );
    if (mounted) _newName.clear();
  }

  Future<void> _remove(String name) async {
    await widget.dispatch(
      layer: widget.layer,
      path: '${widget.basePath}/$name',
      value: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final keys = widget.services.keys.toList()..sort();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final name in keys)
            _ServiceRow(
              name: name,
              entry:
                  widget.services[name] is Map
                      ? Map<String, dynamic>.from(widget.services[name] as Map)
                      : <String, dynamic>{},
              dispatch: widget.dispatch,
              layer: widget.layer,
              basePath: '${widget.basePath}/$name',
              onRemove: () => _remove(name),
            ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Expanded(
                child: VibeCompactInputBox(
                  child: TextField(
                    controller: _newName,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'service name',
                      hintStyle: vibeMono(size: 11, color: c.textTertiary),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
              ),
              SizedBox(
                width: 24,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 28,
                  ),
                  icon: const Icon(Icons.add),
                  color: c.textSecondary,
                  onPressed: _add,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _ServiceRow extends StatefulWidget {
  const _ServiceRow({
    required this.name,
    required this.entry,
    required this.dispatch,
    required this.layer,
    required this.basePath,
    required this.onRemove,
  });
  final String name;
  final Map<String, dynamic> entry;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;
  final VoidCallback onRemove;

  @override
  State<_ServiceRow> createState() => _ServiceRowState();
}

class _ServiceRowState extends State<_ServiceRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final e = widget.entry;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.borderSubtle),
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: <Widget>[
                  Icon(
                    _open ? Icons.expand_more : Icons.chevron_right,
                    size: 14,
                    color: c.textTertiary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.name,
                      style: vibeMono(size: 11, color: c.textPrimary),
                    ),
                  ),
                  Text(
                    '${e['kind'] ?? ''}',
                    style: vibeMono(size: 11, color: c.textTertiary),
                  ),
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 12,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                      icon: const Icon(Icons.close),
                      color: c.textTertiary,
                      onPressed: widget.onRemove,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...<Widget>[
            Divider(height: 1, color: c.borderSubtle),
            VibeEnumEditor(
              label: 'kind',
              value: e['kind'] is String ? e['kind'] as String : null,
              options: const <String>['polling', 'subscription'],
              dispatch: widget.dispatch,
              layer: widget.layer,
              path: '${widget.basePath}/kind',
            ),
            VibeTextEditor(
              label: 'tool',
              value: e['tool'] is String ? e['tool'] as String : null,
              dispatch: widget.dispatch,
              layer: widget.layer,
              path: '${widget.basePath}/tool',
            ),
            VibeTextEditor(
              label: 'interval',
              numeric: true,
              value: e['interval'] != null ? '${e['interval']}' : null,
              dispatch: widget.dispatch,
              layer: widget.layer,
              path: '${widget.basePath}/interval',
            ),
            VibeTextEditor(
              label: 'binding',
              value: e['binding'] is String ? e['binding'] as String : null,
              dispatch: widget.dispatch,
              layer: widget.layer,
              path: '${widget.basePath}/binding',
            ),
            VibeBoolEditor(
              label: 'autoStart',
              value: e['autoStart'] is bool ? e['autoStart'] as bool : null,
              dispatch: widget.dispatch,
              layer: widget.layer,
              path: '${widget.basePath}/autoStart',
            ),
            VibeJsonEditor(
              label: 'params',
              value: e['params'],
              dispatch: widget.dispatch,
              layer: widget.layer,
              path: '${widget.basePath}/params',
            ),
            VibeJsonEditor(
              label: 'onMessage',
              value: e['onMessage'],
              dispatch: widget.dispatch,
              layer: widget.layer,
              path: '${widget.basePath}/onMessage',
            ),
            VibeJsonEditor(
              label: 'onError',
              value: e['onError'],
              dispatch: widget.dispatch,
              layer: widget.layer,
              path: '${widget.basePath}/onError',
            ),
          ],
        ],
      ),
    );
  }
}

/// Per-family FontRegistry editor — map keyed by font family. Each
/// entry expands to weights + fallbacks list editor. variableAxes
/// stays JSON (4-character tag rules + min/max/default — schema
/// validation handles the shape).
class _FontRegistryEditor extends StatefulWidget {
  const _FontRegistryEditor({
    required this.fonts,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final Map<String, dynamic> fonts;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  @override
  State<_FontRegistryEditor> createState() => _FontRegistryEditorState();
}

class _FontRegistryEditorState extends State<_FontRegistryEditor> {
  final _newFamily = TextEditingController();

  @override
  void dispose() {
    _newFamily.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final fam = _newFamily.text.trim();
    if (fam.isEmpty || widget.fonts.containsKey(fam)) return;
    await widget.dispatch(
      layer: widget.layer,
      path: '${widget.basePath}/$fam',
      value: <String, dynamic>{},
    );
    if (mounted) _newFamily.clear();
  }

  Future<void> _remove(String fam) async {
    await widget.dispatch(
      layer: widget.layer,
      path: '${widget.basePath}/$fam',
      value: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final keys = widget.fonts.keys.toList()..sort();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final fam in keys)
            _FontRow(
              family: fam,
              entry:
                  widget.fonts[fam] is Map
                      ? Map<String, dynamic>.from(widget.fonts[fam] as Map)
                      : <String, dynamic>{},
              dispatch: widget.dispatch,
              layer: widget.layer,
              basePath: '${widget.basePath}/$fam',
              onRemove: () => _remove(fam),
            ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Expanded(
                child: VibeCompactInputBox(
                  child: TextField(
                    controller: _newFamily,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'family',
                      hintStyle: vibeMono(size: 11, color: c.textTertiary),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
              ),
              SizedBox(
                width: 24,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 28,
                  ),
                  icon: const Icon(Icons.add),
                  color: c.textSecondary,
                  onPressed: _add,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _FontRow extends StatefulWidget {
  const _FontRow({
    required this.family,
    required this.entry,
    required this.dispatch,
    required this.layer,
    required this.basePath,
    required this.onRemove,
  });
  final String family;
  final Map<String, dynamic> entry;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;
  final VoidCallback onRemove;

  @override
  State<_FontRow> createState() => _FontRowState();
}

class _FontRowState extends State<_FontRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final e = widget.entry;
    final fallbacks = e['fallbacks'];
    final fallbackList =
        fallbacks is List
            ? fallbacks.whereType<String>().toList(growable: false)
            : const <String>[];
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.borderSubtle),
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: <Widget>[
                  Icon(
                    _open ? Icons.expand_more : Icons.chevron_right,
                    size: 14,
                    color: c.textTertiary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      widget.family,
                      style: vibeMono(size: 11, color: c.textPrimary),
                    ),
                  ),
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 12,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 24,
                      ),
                      icon: const Icon(Icons.close),
                      color: c.textTertiary,
                      onPressed: widget.onRemove,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...<Widget>[
            Divider(height: 1, color: c.borderSubtle),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: VibeTokens.space4,
                vertical: 4,
              ),
              child: Text(
                'weights',
                style: vibeMono(size: 11, color: c.textTertiary),
              ),
            ),
            _WeightsMapEditor(
              weights:
                  e['weights'] is Map
                      ? Map<String, dynamic>.from(e['weights'] as Map)
                      : const <String, dynamic>{},
              dispatch: widget.dispatch,
              layer: widget.layer,
              basePath: '${widget.basePath}/weights',
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: VibeTokens.space4,
                vertical: 4,
              ),
              child: Text(
                'variableAxes',
                style: vibeMono(size: 11, color: c.textTertiary),
              ),
            ),
            _VariableAxesEditor(
              axes:
                  e['variableAxes'] is List
                      ? (e['variableAxes'] as List)
                      : const <dynamic>[],
              dispatch: widget.dispatch,
              layer: widget.layer,
              basePath: '${widget.basePath}/variableAxes',
            ),
            _StringListEditor(
              label: 'fallbacks',
              values: fallbackList,
              dispatch: widget.dispatch,
              layer: widget.layer,
              path: '${widget.basePath}/fallbacks',
              placeholder: 'family',
            ),
          ],
        ],
      ),
    );
  }
}

/// Reusable Health section for any Inspector body. Filters the
/// global health snapshot by [pathPrefix] to show only findings
/// relevant to the focused layer (e.g. `/ui/theme` for the Theme
/// panel). Always renders so the global grade chip stays visible.
/// Pass `pathPrefix: null` to skip filtering (used by panels that
/// don't have a clean container scope, e.g. App Structure).
class _InspectorHealthSection extends StatelessWidget {
  const _InspectorHealthSection({
    required this.health,
    required this.pathPrefix,
    this.onSelectWidget,
    this.scopeLabel,
  });

  final Map<String, dynamic>? health;
  final String? pathPrefix;
  final ValueChanged<WidgetPath>? onSelectWidget;

  /// Human-readable scope name shown in the empty state
  /// (e.g. "this theme", "navigation"). Defaults to "this scope".
  final String? scopeLabel;

  List<Map<String, dynamic>> _filtered() {
    final h = health;
    if (h == null) return const <Map<String, dynamic>>[];
    final details = h['details'];
    if (details is! Map) return const <Map<String, dynamic>>[];
    final a11y = details['a11y'];
    if (a11y is! Map) return const <Map<String, dynamic>>[];
    final findings = a11y['findings'];
    if (findings is! List) return const <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    for (final f in findings) {
      if (f is! Map) continue;
      final p = f['path'];
      if (pathPrefix != null) {
        if (p is! String || !p.startsWith(pathPrefix!)) continue;
      }
      out.add(Map<String, dynamic>.from(f));
    }
    int sevRank(String? s) => s == 'fail' ? 0 : (s == 'warn' ? 1 : 2);
    out.sort((a, b) {
      final r = sevRank(
        a['severity'] as String?,
      ).compareTo(sevRank(b['severity'] as String?));
      if (r != 0) return r;
      return ('${a['path']}').compareTo('${b['path']}');
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final findings = _filtered();
    return _Section(
      title:
          findings.isEmpty
              ? 'Health · all clear'
              : 'Health · ${findings.length} '
                  'finding${findings.length == 1 ? '' : 's'}',
      initiallyOpen: findings.isNotEmpty,
      trailing: _GradeChip(health: health),
      children: <Widget>[
        if (findings.isEmpty)
          _EmptyHealthRow(scopeLabel: scopeLabel ?? 'this scope')
        else
          for (final f in findings)
            _FindingRow(finding: f, onSelectWidget: onSelectWidget),
      ],
    );
  }
}

/// Empty-state row for the Inspector Health section. Renders a faint
/// "no findings on this page" line so the section stays present (and
/// the grade chip stays visible) even when nothing is wrong.
class _EmptyHealthRow extends StatelessWidget {
  const _EmptyHealthRow({this.scopeLabel = 'this page'});
  final String scopeLabel;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        VibeTokens.space4,
        4,
        VibeTokens.space3,
        8,
      ),
      child: Text(
        'no findings on $scopeLabel',
        style: vibeMono(size: 11, color: c.textSecondary),
      ),
    );
  }
}

/// Letter-grade chip rendered in the Inspector Health section header.
/// Mirrors `_HealthBar._letterFromSummary` — same 5-axis rubric — so
/// the Inspector and chat-side health bar agree on the letter without
/// either needing to call the `grade()` MCP tool. Falls back to a
/// dim "—" pill when the snapshot is null or hasn't recorded a
/// summary yet.
class _GradeChip extends StatelessWidget {
  const _GradeChip({required this.health});
  final Map<String, dynamic>? health;

  String _letter() {
    final h = health;
    if (h == null) return '—';
    final summary = h['summary'];
    if (summary is! Map) return '—';
    int penalty(num issues, {num cap = 20, num perIssue = 4}) {
      final p = (issues * perIssue).clamp(0, cap).toInt();
      return 20 - p;
    }

    final validity = penalty(
      ((summary['specIssues'] ?? 0) as int) +
          ((summary['wiringIssues'] ?? 0) as int),
    );
    final a11y = penalty(
      ((summary['a11yFails'] ?? 0) as int) * 2 +
          ((summary['a11yWarns'] ?? 0) as int),
    );
    final assets = penalty((summary['invalidAssets'] ?? 0) as int, perIssue: 5);
    final state = penalty(
      ((summary['undefinedState'] ?? 0) as int) * 2 +
          ((summary['unusedState'] ?? 0) as int),
    );
    final tokens = penalty((summary['deadTokens'] ?? 0) as int, perIssue: 3);
    final total = validity + a11y + assets + state + tokens;
    return total >= 90
        ? 'A'
        : total >= 80
        ? 'B'
        : total >= 70
        ? 'C'
        : total >= 60
        ? 'D'
        : 'F';
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final letter = _letter();
    Color bg;
    Color fg;
    switch (letter) {
      case 'A':
        bg = c.mint.withValues(alpha: 0.15);
        fg = c.mint;
        break;
      case 'B':
        bg = c.surface2;
        fg = c.textPrimary;
        break;
      case 'C':
        bg = const Color(0xFFE8B86A).withValues(alpha: 0.18);
        fg = const Color(0xFFB07A2A);
        break;
      case 'D':
        bg = c.coral.withValues(alpha: 0.18);
        fg = c.coral;
        break;
      case 'F':
        bg = c.coral.withValues(alpha: 0.28);
        fg = c.coral;
        break;
      default:
        bg = c.surface2;
        fg = c.textSecondary;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        letter,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 10,
          letterSpacing: 0.4,
          color: fg,
        ),
      ),
    );
  }
}

/// One health finding row shown in `_PagesBody`'s Health section.
/// Severity icon + rule + first 60 chars of message; tap maps the
/// finding's path back into a `WidgetPath` and asks the host to
/// select that subtree so the author lands directly on the
/// offending widget. Skips findings whose path can't be resolved
/// to a widget root (rare — the audit always points at a widget).
class _FindingRow extends StatelessWidget {
  const _FindingRow({required this.finding, this.onSelectWidget});
  final Map<String, dynamic> finding;
  final ValueChanged<WidgetPath>? onSelectWidget;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final sev = '${finding['severity'] ?? 'info'}';
    final rule = '${finding['rule'] ?? ''}';
    final msg = '${finding['message'] ?? ''}';
    final path = '${finding['path'] ?? ''}';
    final accent =
        sev == 'fail'
            ? c.coral
            : sev == 'warn'
            ? const Color(0xFFE8B86A)
            : c.textSecondary;
    return InkWell(
      onTap: () => _jumpTo(path),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space4,
          vertical: 4,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              sev == 'fail'
                  ? Icons.error_outline
                  : Icons.warning_amber_outlined,
              size: 14,
              color: accent,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    rule,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    msg.length > 80 ? '${msg.substring(0, 80)}…' : msg,
                    style: vibeMono(size: 10, color: c.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _jumpTo(String pointer) {
    if (pointer.isEmpty || onSelectWidget == null) return;
    // Strip the page or template prefix so the path we hand back is
    // rooted at the content tree — matches the WidgetPath shape the
    // tree view + selection model expect.
    final m = RegExp(
      r'^/ui/(?:pages|templates)/[^/]+/content(/.*)?$',
    ).firstMatch(pointer);
    if (m == null) return;
    final tail = m.group(1) ?? '';
    if (tail.isEmpty) {
      onSelectWidget?.call(const <Object>[]);
      return;
    }
    final segs = tail.startsWith('/') ? tail.substring(1) : tail;
    final widgetPath = <Object>[];
    for (final raw in segs.split('/')) {
      final unescaped = raw.replaceAll('~1', '/').replaceAll('~0', '~');
      final asInt = int.tryParse(unescaped);
      if (asInt != null) {
        widgetPath.add(asInt);
      } else {
        widgetPath.add(unescaped);
      }
    }
    onSelectWidget?.call(widgetPath);
  }
}

/// Generic numeric token row for Spacing / Elevation / etc. Stacks
/// `VibeTextEditor` (numeric) with a token-usage badge identical
/// shape to `_ColorRoleRow` so every theme domain reads the same
/// way. Click expands inline path list when usage > 0.
class _NumericTokenRow extends StatefulWidget {
  const _NumericTokenRow({
    required this.label,
    required this.value,
    required this.dispatch,
    required this.path,
    required this.usage,
    required this.domain,
    required this.role,
    required this.projection,
  });
  final String label;
  final String? value;
  final PatchDispatcher dispatch;
  final String path;
  final int usage;

  /// Theme domain — used to pattern-match `{{theme.<domain>.<role>}}`.
  final String domain;
  final String role;
  final LayerProjection projection;

  @override
  State<_NumericTokenRow> createState() => _NumericTokenRowState();
}

class _NumericTokenRowState extends State<_NumericTokenRow> {
  bool _open = false;

  List<Map<String, String>> _findUsages() {
    final out = <Map<String, String>>[];
    final pattern = RegExp(
      r'\{\{\s*theme\.' +
          RegExp.escape(widget.domain) +
          r'\.' +
          RegExp.escape(widget.role) +
          r'\s*\}\}',
    );
    void walk(
      dynamic node,
      String pointer,
      String? widgetPath,
      String? property,
    ) {
      if (node is String) {
        if (pattern.hasMatch(node)) {
          out.add(<String, String>{
            'path': pointer,
            if (widgetPath != null) 'widgetPath': widgetPath,
            if (property != null) 'property': property,
          });
        }
        return;
      }
      if (node is Map) {
        final isWidget = node['type'] is String;
        for (final entry in node.entries) {
          final key = '${entry.key}';
          final escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
          walk(
            entry.value,
            '$pointer/$escaped',
            isWidget ? pointer : widgetPath,
            isWidget ? key : property,
          );
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$pointer/$i', widgetPath, property);
        }
      }
    }

    walk(widget.projection.rawJson['ui'], '/ui', null, null);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final usages = _open && widget.usage > 0 ? _findUsages() : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Stack(
          children: <Widget>[
            VibeTextEditor(
              label: widget.label,
              numeric: true,
              value: widget.value,
              dispatch: widget.dispatch,
              layer: LayerId.theme,
              path: widget.path,
            ),
            if (widget.usage > 0)
              Positioned(
                right: 138,
                top: 6,
                child: InkWell(
                  onTap: () => setState(() => _open = !_open),
                  borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: _open ? c.surface3 : c.surface2,
                      borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                      border: Border.all(
                        color: _open ? c.borderStrong : c.borderDefault,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          '${widget.usage}',
                          style: vibeMono(size: 10, color: c.textSecondary),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          _open ? Icons.expand_less : Icons.expand_more,
                          size: 12,
                          color: c.textTertiary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (usages != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              VibeTokens.space4,
              0,
              VibeTokens.space4,
              VibeTokens.space2,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: c.surface2,
                border: Border.all(color: c.borderSubtle),
                borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
              ),
              padding: const EdgeInsets.all(VibeTokens.space2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final u in usages)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        '${u['property'] ?? ''}  ·  '
                        '${u['widgetPath'] ?? u['path']}',
                        style: vibeMono(size: 10, color: c.textSecondary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One row in the Theme.Color section. Wraps `VibeColorEditor` with
/// a usage badge so the author sees how many widgets reference the
/// role before changing the swatch — "this token paints N spots."
/// Click the badge to expand inline usage paths; collapse via the
/// same badge.
class _ColorRoleRow extends StatefulWidget {
  const _ColorRoleRow({
    required this.role,
    required this.value,
    required this.dispatch,
    required this.usage,
    required this.projection,
  });
  final String role;
  final String? value;
  final PatchDispatcher dispatch;
  final int usage;
  final LayerProjection projection;

  @override
  State<_ColorRoleRow> createState() => _ColorRoleRowState();
}

class _ColorRoleRowState extends State<_ColorRoleRow> {
  bool _open = false;

  /// Collect every `{{theme.color.[role]}}` usage path (RFC 6901
  /// pointer + owning widget path + property name) on demand. Cheap
  /// — same single walk as the badge count, just retains paths.
  List<Map<String, String>> _findUsages() {
    final out = <Map<String, String>>[];
    final pattern = RegExp(
      r'\{\{\s*theme\.color\.' + RegExp.escape(widget.role) + r'\s*\}\}',
    );
    void walk(
      dynamic node,
      String pointer,
      String? widgetPath,
      String? property,
    ) {
      if (node is String) {
        if (pattern.hasMatch(node)) {
          out.add(<String, String>{
            'path': pointer,
            if (widgetPath != null) 'widgetPath': widgetPath,
            if (property != null) 'property': property,
          });
        }
        return;
      }
      if (node is Map) {
        final isWidget = node['type'] is String;
        for (final entry in node.entries) {
          final key = '${entry.key}';
          final escaped = key.replaceAll('~', '~0').replaceAll('/', '~1');
          walk(
            entry.value,
            '$pointer/$escaped',
            isWidget ? pointer : widgetPath,
            isWidget ? key : property,
          );
        }
      } else if (node is List) {
        for (var i = 0; i < node.length; i++) {
          walk(node[i], '$pointer/$i', widgetPath, property);
        }
      }
    }

    walk(widget.projection.rawJson['ui'], '/ui', null, null);
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final usages = _open && widget.usage > 0 ? _findUsages() : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Stack(
          children: <Widget>[
            VibeColorEditor(
              label: widget.role,
              value: widget.value,
              dispatch: widget.dispatch,
              layer: LayerId.theme,
              path: '/ui/theme/color/${widget.role}',
            ),
            if (widget.usage > 0)
              Positioned(
                right: 138,
                top: 6,
                child: Tooltip(
                  message:
                      'click to ${_open ? 'collapse' : 'expand'} '
                      '${widget.usage} reference'
                      '${widget.usage == 1 ? '' : 's'}',
                  waitDuration: const Duration(milliseconds: 200),
                  child: InkWell(
                    onTap: () => setState(() => _open = !_open),
                    borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: _open ? c.surface3 : c.surface2,
                        borderRadius: BorderRadius.circular(
                          VibeTokens.radiusSm,
                        ),
                        border: Border.all(
                          color: _open ? c.borderStrong : c.borderDefault,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            '${widget.usage}',
                            style: vibeMono(size: 10, color: c.textSecondary),
                          ),
                          const SizedBox(width: 2),
                          Icon(
                            _open ? Icons.expand_less : Icons.expand_more,
                            size: 12,
                            color: c.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (usages != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              VibeTokens.space4,
              0,
              VibeTokens.space4,
              VibeTokens.space2,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: c.surface2,
                border: Border.all(color: c.borderSubtle),
                borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
              ),
              padding: const EdgeInsets.all(VibeTokens.space2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final u in usages)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        '${u['property'] ?? ''}  ·  ${u['widgetPath'] ?? u['path']}',
                        style: vibeMono(size: 10, color: c.textSecondary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Typed BorderSide editor — color / width / style.
class _BorderSideEditor extends StatelessWidget {
  const _BorderSideEditor({
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final Map<String, dynamic> value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        VibeColorEditor(
          label: 'color',
          value: value['color'] is String ? value['color'] as String : null,
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/color',
        ),
        VibeTextEditor(
          label: 'width',
          numeric: true,
          value: value['width'] != null ? '${value['width']}' : null,
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/width',
        ),
        VibeEnumEditor(
          label: 'style',
          value: value['style'] is String ? value['style'] as String : null,
          options: const <String>['solid', 'none'],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/style',
        ),
      ],
    );
  }
}

/// Typed BoxBorder editor — `all` shorthand (single BorderSide for
/// all four sides) OR per-side `top/bottom/left/right`.
class _BoxBorderEditor extends StatefulWidget {
  const _BoxBorderEditor({
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final dynamic value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  @override
  State<_BoxBorderEditor> createState() => _BoxBorderEditorState();
}

class _BoxBorderEditorState extends State<_BoxBorderEditor> {
  // Detect uniform vs per-side authored shape; treat the absence of
  // `top/bottom/left/right` as uniform-mode.
  bool get _uniform {
    final v = widget.value;
    if (v is! Map) return true;
    return !v.keys.any(
      (k) => k == 'top' || k == 'bottom' || k == 'left' || k == 'right',
    );
  }

  Map<String, dynamic> _allSide() {
    final v = widget.value;
    if (v is Map && v['all'] is Map) {
      return Map<String, dynamic>.from(v['all'] as Map);
    }
    if (v is Map &&
        (v['color'] != null || v['width'] != null || v['style'] != null)) {
      // BorderSide-shaped at root.
      return Map<String, dynamic>.from(v);
    }
    return const <String, dynamic>{};
  }

  Map<String, dynamic> _side(String key) {
    final v = widget.value;
    if (v is Map && v[key] is Map) {
      return Map<String, dynamic>.from(v[key] as Map);
    }
    return const <String, dynamic>{};
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _uniform ? 'uniform (all sides)' : 'per-side',
                  style: vibeMono(size: 11, color: c.textSecondary),
                ),
              ),
            ],
          ),
        ),
        if (_uniform)
          _BorderSideEditor(
            value: _allSide(),
            dispatch: widget.dispatch,
            layer: widget.layer,
            basePath: widget.basePath,
          )
        else ...<Widget>[
          for (final side in const <String>[
            'top',
            'bottom',
            'left',
            'right',
          ]) ...<Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: VibeTokens.space4,
                vertical: 4,
              ),
              child: Text(
                side,
                style: vibeMono(size: 11, color: c.textTertiary),
              ),
            ),
            _BorderSideEditor(
              value: _side(side),
              dispatch: widget.dispatch,
              layer: widget.layer,
              basePath: '${widget.basePath}/$side',
            ),
          ],
        ],
      ],
    );
  }
}

/// Typed BoxShadow editor — single shadow row.
class _BoxShadowEditor extends StatelessWidget {
  const _BoxShadowEditor({
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final Map<String, dynamic> value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  String? _s(String k) {
    final v = value[k];
    return v == null ? null : '$v';
  }

  @override
  Widget build(BuildContext context) {
    final offset =
        value['offset'] is Map
            ? Map<String, dynamic>.from(value['offset'] as Map)
            : const <String, dynamic>{};
    return Column(
      children: <Widget>[
        VibeColorEditor(
          label: 'color',
          value: _s('color'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/color',
        ),
        VibeTextEditor(
          label: 'offset.dx',
          numeric: true,
          value: offset['dx'] != null ? '${offset['dx']}' : null,
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/offset/dx',
        ),
        VibeTextEditor(
          label: 'offset.dy',
          numeric: true,
          value: offset['dy'] != null ? '${offset['dy']}' : null,
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/offset/dy',
        ),
        VibeTextEditor(
          label: 'blurRadius',
          numeric: true,
          value: _s('blurRadius'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/blurRadius',
        ),
        VibeTextEditor(
          label: 'spreadRadius',
          numeric: true,
          value: _s('spreadRadius'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/spreadRadius',
        ),
      ],
    );
  }
}

/// Typed BoxShadow list editor — N shadows stacked back-to-front.
class _BoxShadowListEditor extends StatefulWidget {
  const _BoxShadowListEditor({
    required this.shadows,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final List<dynamic> shadows;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  @override
  State<_BoxShadowListEditor> createState() => _BoxShadowListEditorState();
}

class _BoxShadowListEditorState extends State<_BoxShadowListEditor> {
  Future<void> _add() async {
    final next = <Map<String, dynamic>>[
      ...widget.shadows.whereType<Map>().map(
        (m) => Map<String, dynamic>.from(m),
      ),
      <String, dynamic>{
        'color': '#00000033',
        'offset': <String, dynamic>{'dx': 0, 'dy': 2},
        'blurRadius': 4,
      },
    ];
    await widget.dispatch(
      layer: widget.layer,
      path: widget.basePath,
      value: next,
    );
  }

  Future<void> _remove(int i) async {
    final next =
        widget.shadows
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList()
          ..removeAt(i);
    await widget.dispatch(
      layer: widget.layer,
      path: widget.basePath,
      value: next.isEmpty ? null : next,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < widget.shadows.length; i++) ...<Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VibeTokens.space4,
              vertical: 4,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'shadow #$i',
                    style: vibeMono(size: 11, color: c.textTertiary),
                  ),
                ),
                SizedBox(
                  width: 24,
                  height: 28,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 12,
                    constraints: const BoxConstraints.tightFor(
                      width: 24,
                      height: 28,
                    ),
                    icon: const Icon(Icons.close),
                    color: c.textTertiary,
                    onPressed: () => _remove(i),
                  ),
                ),
              ],
            ),
          ),
          _BoxShadowEditor(
            value:
                widget.shadows[i] is Map
                    ? Map<String, dynamic>.from(widget.shadows[i] as Map)
                    : const <String, dynamic>{},
            dispatch: widget.dispatch,
            layer: widget.layer,
            basePath: '${widget.basePath}/$i',
          ),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: SizedBox(
            height: 28,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add, size: 14),
              label: const Text('add shadow'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                side: BorderSide(color: c.borderDefault),
                textStyle: vibeMono(size: 11, color: c.textSecondary),
              ),
              onPressed: _add,
            ),
          ),
        ),
      ],
    );
  }
}

/// Typed BoxDecoration composite editor — color / gradient / image
/// / border / borderRadius / boxShadow / shape / backdropBlur.
/// Composes the underlying primitive editors so authors edit each
/// slot directly.
class _BoxDecorationEditor extends StatelessWidget {
  const _BoxDecorationEditor({
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final Map<String, dynamic> value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  String? _s(String k) {
    final v = value[k];
    return v == null ? null : '$v';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        VibeColorEditor(
          label: 'color',
          value: _s('color'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/color',
        ),
        VibeEnumEditor(
          label: 'shape',
          value: _s('shape'),
          options: const <String>['rectangle', 'circle'],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/shape',
        ),
        VibeTextEditor(
          label: 'backdropBlur',
          numeric: true,
          value: _s('backdropBlur'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/backdropBlur',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Text(
            'borderRadius (BorderRadius)',
            style: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
        _BorderRadiusEditor(
          value: value['borderRadius'],
          dispatch: dispatch,
          layer: layer,
          basePath: '$basePath/borderRadius',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Text(
            'border (BoxBorder)',
            style: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
        _BoxBorderEditor(
          value: value['border'],
          dispatch: dispatch,
          layer: layer,
          basePath: '$basePath/border',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Text(
            'gradient (Gradient)',
            style: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
        _GradientEditor(
          value:
              value['gradient'] is Map
                  ? Map<String, dynamic>.from(value['gradient'] as Map)
                  : const <String, dynamic>{},
          dispatch: dispatch,
          layer: layer,
          basePath: '$basePath/gradient',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Text(
            'image (BackgroundImage)',
            style: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
        _BackgroundImageEditor(
          value:
              value['image'] is Map
                  ? Map<String, dynamic>.from(value['image'] as Map)
                  : const <String, dynamic>{},
          dispatch: dispatch,
          layer: layer,
          basePath: '$basePath/image',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Text(
            'boxShadow (BoxShadow[])',
            style: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
        _BoxShadowListEditor(
          shadows:
              value['boxShadow'] is List
                  ? (value['boxShadow'] as List)
                  : const <dynamic>[],
          dispatch: dispatch,
          layer: layer,
          basePath: '$basePath/boxShadow',
        ),
      ],
    );
  }
}

/// Typed Gradient editor (configs/_primitive/Gradient.yaml).
/// Discriminated by `type` ∈ linear / radial / sweep — slot fields
/// switch accordingly. `colors[]` is a chip list of hex/role refs;
/// `stops[]` (optional) is parallel positions.
class _GradientEditor extends StatelessWidget {
  const _GradientEditor({
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final Map<String, dynamic> value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  String? _s(String k) {
    final v = value[k];
    return v == null ? null : '$v';
  }

  @override
  Widget build(BuildContext context) {
    final type = _s('type') ?? 'linear';
    final colors =
        (value['colors'] is List)
            ? (value['colors'] as List).whereType<String>().toList(
              growable: false,
            )
            : const <String>[];
    final stops =
        (value['stops'] is List) ? (value['stops'] as List) : const <dynamic>[];
    return Column(
      children: <Widget>[
        VibeEnumEditor(
          label: 'type',
          value: type,
          options: const <String>['linear', 'radial', 'sweep'],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/type',
        ),
        _StringListEditor(
          label: 'colors',
          values: colors,
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/colors',
          placeholder: '#5B7CFA / {{theme.color.primary}}',
        ),
        VibeJsonEditor(
          label: 'stops',
          value: stops.isEmpty ? null : stops,
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/stops',
        ),
        if (type == 'linear') ...<Widget>[
          VibeEnumEditor(
            label: 'begin',
            value: _s('begin'),
            options: const <String>[
              'topStart',
              'topCenter',
              'topEnd',
              'centerStart',
              'center',
              'centerEnd',
              'bottomStart',
              'bottomCenter',
              'bottomEnd',
            ],
            dispatch: dispatch,
            layer: layer,
            path: '$basePath/begin',
          ),
          VibeEnumEditor(
            label: 'end',
            value: _s('end'),
            options: const <String>[
              'topStart',
              'topCenter',
              'topEnd',
              'centerStart',
              'center',
              'centerEnd',
              'bottomStart',
              'bottomCenter',
              'bottomEnd',
            ],
            dispatch: dispatch,
            layer: layer,
            path: '$basePath/end',
          ),
        ],
        if (type == 'radial') ...<Widget>[
          VibeEnumEditor(
            label: 'center',
            value: _s('center'),
            options: const <String>[
              'topStart',
              'topCenter',
              'topEnd',
              'centerStart',
              'center',
              'centerEnd',
              'bottomStart',
              'bottomCenter',
              'bottomEnd',
            ],
            dispatch: dispatch,
            layer: layer,
            path: '$basePath/center',
          ),
          VibeTextEditor(
            label: 'radius',
            numeric: true,
            value: _s('radius'),
            dispatch: dispatch,
            layer: layer,
            path: '$basePath/radius',
          ),
        ],
        if (type == 'sweep') ...<Widget>[
          VibeEnumEditor(
            label: 'center',
            value: _s('center'),
            options: const <String>[
              'topStart',
              'topCenter',
              'topEnd',
              'centerStart',
              'center',
              'centerEnd',
              'bottomStart',
              'bottomCenter',
              'bottomEnd',
            ],
            dispatch: dispatch,
            layer: layer,
            path: '$basePath/center',
          ),
          VibeTextEditor(
            label: 'startAngle',
            numeric: true,
            value: _s('startAngle'),
            dispatch: dispatch,
            layer: layer,
            path: '$basePath/startAngle',
          ),
          VibeTextEditor(
            label: 'endAngle',
            numeric: true,
            value: _s('endAngle'),
            dispatch: dispatch,
            layer: layer,
            path: '$basePath/endAngle',
          ),
        ],
        VibeEnumEditor(
          label: 'tileMode',
          value: _s('tileMode'),
          options: const <String>['clamp', 'repeated', 'mirror'],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/tileMode',
        ),
      ],
    );
  }
}

/// Typed BorderRadius editor (configs/_primitive/BorderRadius.yaml).
/// Four directional corners + `all` shorthand. Author can also type
/// a single number into `all` to apply uniformly. Empty fields keep
/// the canonical map sparse so the validator only sees set corners.
class _BorderRadiusEditor extends StatelessWidget {
  const _BorderRadiusEditor({
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final dynamic value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  String? _str(String key) {
    if (value is num) return key == 'all' ? '$value' : null;
    if (value is Map) {
      final v = (value as Map)[key];
      return v == null ? null : '$v';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        VibeTextEditor(
          label: 'all',
          numeric: true,
          value: _str('all'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/all',
        ),
        VibeTextEditor(
          label: 'topStart',
          numeric: true,
          value: _str('topStart'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/topStart',
        ),
        VibeTextEditor(
          label: 'topEnd',
          numeric: true,
          value: _str('topEnd'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/topEnd',
        ),
        VibeTextEditor(
          label: 'bottomStart',
          numeric: true,
          value: _str('bottomStart'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/bottomStart',
        ),
        VibeTextEditor(
          label: 'bottomEnd',
          numeric: true,
          value: _str('bottomEnd'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/bottomEnd',
        ),
      ],
    );
  }
}

/// Typed TextStyle editor (configs/_primitive/TextStyle.yaml). Surfaces
/// the high-traffic fields as typed slots; rare ones (shadows, shader,
/// fontFeatures) stay JSON since they are nested primitives the author
/// edits less frequently.
class _TextStyleEditor extends StatelessWidget {
  const _TextStyleEditor({
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final Map<String, dynamic> value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  String? _s(String k) {
    final v = value[k];
    if (v == null) return null;
    return '$v';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        VibeTextEditor(
          label: 'fontFamily',
          value: _s('fontFamily'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/fontFamily',
        ),
        VibeTextEditor(
          label: 'fontSize',
          numeric: true,
          value: _s('fontSize'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/fontSize',
        ),
        VibeEnumEditor(
          label: 'fontWeight',
          value: _s('fontWeight'),
          options: const <String>[
            '100',
            '200',
            '300',
            '400',
            '500',
            '600',
            '700',
            '800',
            '900',
            'thin',
            'light',
            'regular',
            'medium',
            'semiBold',
            'bold',
            'extraBold',
            'black',
          ],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/fontWeight',
        ),
        VibeEnumEditor(
          label: 'fontStyle',
          value: _s('fontStyle'),
          options: const <String>['normal', 'italic'],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/fontStyle',
        ),
        VibeTextEditor(
          label: 'letterSpacing',
          numeric: true,
          value: _s('letterSpacing'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/letterSpacing',
        ),
        VibeTextEditor(
          label: 'wordSpacing',
          numeric: true,
          value: _s('wordSpacing'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/wordSpacing',
        ),
        VibeTextEditor(
          label: 'height',
          numeric: true,
          value: _s('height'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/height',
        ),
        VibeColorEditor(
          label: 'color',
          value: _s('color'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/color',
        ),
        VibeColorEditor(
          label: 'backgroundColor',
          value: _s('backgroundColor'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/backgroundColor',
        ),
        VibeEnumEditor(
          label: 'decoration',
          value: _s('decoration'),
          options: const <String>[
            'none',
            'underline',
            'overline',
            'lineThrough',
          ],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/decoration',
        ),
        VibeColorEditor(
          label: 'decorationColor',
          value: _s('decorationColor'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/decorationColor',
        ),
        VibeJsonEditor(
          label: 'shadows',
          value: value['shadows'],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/shadows',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: 4,
          ),
          child: Text(
            'shader (Gradient)',
            style: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
        _GradientEditor(
          value:
              value['shader'] is Map
                  ? Map<String, dynamic>.from(value['shader'] as Map)
                  : const <String, dynamic>{},
          dispatch: dispatch,
          layer: layer,
          basePath: '$basePath/shader',
        ),
        VibeJsonEditor(
          label: 'fontFeatures',
          value: value['fontFeatures'],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/fontFeatures',
        ),
      ],
    );
  }
}

/// Typed BackgroundImage editor (configs/_primitive/BackgroundImage.yaml).
/// AssetRef + fit + alignment + opacity + colorFilter + repeat.
class _BackgroundImageEditor extends StatelessWidget {
  const _BackgroundImageEditor({
    required this.value,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final Map<String, dynamic> value;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  String? _s(String k) {
    final v = value[k];
    return v == null ? null : '$v';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        VibeTextEditor(
          label: 'src',
          value: _s('src'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/src',
        ),
        VibeEnumEditor(
          label: 'fit',
          value: _s('fit'),
          options: const <String>[
            'fill',
            'contain',
            'cover',
            'fitWidth',
            'fitHeight',
            'none',
            'scaleDown',
          ],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/fit',
        ),
        VibeEnumEditor(
          label: 'alignment',
          value: _s('alignment'),
          options: const <String>[
            'topStart',
            'topCenter',
            'topEnd',
            'centerStart',
            'center',
            'centerEnd',
            'bottomStart',
            'bottomCenter',
            'bottomEnd',
          ],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/alignment',
        ),
        VibeTextEditor(
          label: 'opacity',
          numeric: true,
          value: _s('opacity'),
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/opacity',
        ),
        VibeEnumEditor(
          label: 'repeat',
          value: _s('repeat'),
          options: const <String>['noRepeat', 'repeat', 'repeatX', 'repeatY'],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/repeat',
        ),
        VibeJsonEditor(
          label: 'colorFilter',
          value: value['colorFilter'],
          dispatch: dispatch,
          layer: layer,
          path: '$basePath/colorFilter',
        ),
      ],
    );
  }
}

/// Map editor for FontRegistry weights — keys are weight values,
/// values are AssetRef strings. Add a key by typing weight + URL,
/// remove via × button. Keeps the canonical map sparse.
class _WeightsMapEditor extends StatefulWidget {
  const _WeightsMapEditor({
    required this.weights,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final Map<String, dynamic> weights;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  @override
  State<_WeightsMapEditor> createState() => _WeightsMapEditorState();
}

class _WeightsMapEditorState extends State<_WeightsMapEditor> {
  final _newWeight = TextEditingController();
  final _newRef = TextEditingController();

  @override
  void dispose() {
    _newWeight.dispose();
    _newRef.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final w = _newWeight.text.trim();
    final r = _newRef.text.trim();
    if (w.isEmpty || r.isEmpty) return;
    await widget.dispatch(
      layer: widget.layer,
      path: '${widget.basePath}/$w',
      value: r,
    );
    if (!mounted) return;
    _newWeight.clear();
    _newRef.clear();
  }

  Future<void> _remove(String w) async {
    await widget.dispatch(
      layer: widget.layer,
      path: '${widget.basePath}/$w',
      value: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final keys = widget.weights.keys.toList()..sort();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final k in keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 60,
                    child: Text(
                      k,
                      style: vibeMono(size: 11, color: c.textPrimary),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${widget.weights[k]}',
                      style: vibeMono(size: 11, color: c.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(
                    width: 24,
                    height: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 12,
                      constraints: const BoxConstraints.tightFor(
                        width: 24,
                        height: 28,
                      ),
                      icon: const Icon(Icons.close),
                      color: c.textTertiary,
                      onPressed: () => _remove(k),
                    ),
                  ),
                ],
              ),
            ),
          Row(
            children: <Widget>[
              SizedBox(
                width: 60,
                child: VibeCompactInputBox(
                  child: TextField(
                    controller: _newWeight,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: '400',
                      hintStyle: vibeMono(size: 11, color: c.textTertiary),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: VibeCompactInputBox(
                  child: TextField(
                    controller: _newRef,
                    style: vibeMono(size: 11, color: c.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      isCollapsed: true,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'bundle://… / https://…',
                      hintStyle: vibeMono(size: 11, color: c.textTertiary),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 24,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 28,
                  ),
                  icon: const Icon(Icons.add),
                  color: c.textSecondary,
                  onPressed: _add,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

/// List editor for FontRegistry variableAxes — array of `{tag, min,
/// max, default}`. Add row enforces 4-char tag. Standard tags
/// (`wght`, `wdth`, `opsz`, `ital`, `slnt`) are common; custom is
/// allowed.
class _VariableAxesEditor extends StatefulWidget {
  const _VariableAxesEditor({
    required this.axes,
    required this.dispatch,
    required this.layer,
    required this.basePath,
  });
  final List<dynamic> axes;
  final PatchDispatcher dispatch;
  final LayerId layer;
  final String basePath;

  @override
  State<_VariableAxesEditor> createState() => _VariableAxesEditorState();
}

class _VariableAxesEditorState extends State<_VariableAxesEditor> {
  final _newTag = TextEditingController();
  final _newMin = TextEditingController();
  final _newMax = TextEditingController();
  final _newDef = TextEditingController();

  @override
  void dispose() {
    _newTag.dispose();
    _newMin.dispose();
    _newMax.dispose();
    _newDef.dispose();
    super.dispose();
  }

  Future<void> _commit(List<Map<String, dynamic>> next) {
    return widget.dispatch(
      layer: widget.layer,
      path: widget.basePath,
      value: next.isEmpty ? null : next,
    );
  }

  Future<void> _add() async {
    final tag = _newTag.text.trim();
    if (tag.length != 4) return;
    final min = num.tryParse(_newMin.text.trim());
    final max = num.tryParse(_newMax.text.trim());
    if (min == null || max == null) return;
    final def = num.tryParse(_newDef.text.trim());
    final entry = <String, dynamic>{
      'tag': tag,
      'min': min,
      'max': max,
      if (def != null) 'default': def,
    };
    final next = <Map<String, dynamic>>[
      ...widget.axes.whereType<Map>().map((m) => Map<String, dynamic>.from(m)),
      entry,
    ];
    await _commit(next);
    if (!mounted) return;
    _newTag.clear();
    _newMin.clear();
    _newMax.clear();
    _newDef.clear();
  }

  Future<void> _remove(int i) async {
    final next =
        widget.axes
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList()
          ..removeAt(i);
    await _commit(next);
  }

  Widget _input(TextEditingController c, String hint, int width) {
    return SizedBox(
      width: width.toDouble(),
      child: VibeCompactInputBox(
        child: TextField(
          controller: c,
          style: vibeMono(size: 11, color: VibeTokens.color.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            isCollapsed: true,
            filled: false,
            contentPadding: const EdgeInsets.symmetric(horizontal: 6),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            hintText: hint,
            hintStyle: vibeMono(size: 11, color: VibeTokens.color.textTertiary),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: VibeTokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < widget.axes.length; i++) ...<Widget>[
            if (widget.axes[i] is Map)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 50,
                      child: Text(
                        '${(widget.axes[i] as Map)['tag'] ?? ''}',
                        style: vibeMono(size: 11, color: c.textPrimary),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${(widget.axes[i] as Map)['min']}–'
                        '${(widget.axes[i] as Map)['max']} '
                        '@${(widget.axes[i] as Map)['default'] ?? '?'}',
                        style: vibeMono(size: 11, color: c.textSecondary),
                      ),
                    ),
                    SizedBox(
                      width: 24,
                      height: 28,
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 12,
                        constraints: const BoxConstraints.tightFor(
                          width: 24,
                          height: 28,
                        ),
                        icon: const Icon(Icons.close),
                        color: c.textTertiary,
                        onPressed: () => _remove(i),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          Row(
            children: <Widget>[
              _input(_newTag, 'wght', 50),
              const SizedBox(width: 4),
              _input(_newMin, 'min', 48),
              const SizedBox(width: 4),
              _input(_newMax, 'max', 48),
              const SizedBox(width: 4),
              _input(_newDef, 'def', 48),
              SizedBox(
                width: 24,
                height: 28,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 14,
                  constraints: const BoxConstraints.tightFor(
                    width: 24,
                    height: 28,
                  ),
                  icon: const Icon(Icons.add),
                  color: c.textSecondary,
                  onPressed: _add,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

/// Subtle proxy for the row being dragged — surface3 + strong border
/// so the user sees what they're moving without a hard tilt or scale.
class _DragProxyDecorator extends StatelessWidget {
  const _DragProxyDecorator({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          border: Border.all(color: c.borderStrong),
        ),
        child: child,
      ),
    );
  }
}

/// Property form for the currently-selected widget node within a page
/// or component widget tree. Renders a leaf-only key/value form: child
/// edges (`child` / `children`) are surfaced through the tree view
/// itself and skipped here. Each editor commits through the same
/// dispatcher the rest of the panel uses, so undo / history pick up
/// the change normally.
class _SelectedWidgetSection extends StatelessWidget {
  const _SelectedWidgetSection({
    required this.root,
    required this.selectedPath,
    required this.layer,
    required this.pointerPrefix,
    required this.dispatch,
  });

  final Map<String, dynamic> root;
  final WidgetPath? selectedPath;
  final LayerId layer;

  /// JSON Pointer prefix that addresses [root] in the canonical bundle.
  /// E.g. `/ui/pages/<id>/content` or `/ui/templates/<id>/content`.
  final String pointerPrefix;

  final PatchDispatcher dispatch;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final path = selectedPath ?? const <Object>[];
    final node = atPath(root, path);
    if (node is! Map<String, dynamic>) {
      return _Section(
        title: 'Selected widget',
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: VibeTokens.space4,
              vertical: VibeTokens.space2,
            ),
            child: Text(
              'Pick a node in the tree to edit its properties.',
              style: vibeMono(size: 11, color: c.textTertiary),
            ),
          ),
        ],
      );
    }
    final type = node['type']?.toString() ?? '?';
    final pointer = pointerPrefix + pointerOf(path);
    final catalog = WidgetSchemaCatalog.instance;
    final descriptors = catalog.propertiesFor(type);
    // Property keys present in the schema — used to detect raw JSON
    // entries the schema does NOT cover so we can still surface them.
    final knownKeys = <String>{for (final d in descriptors) d.name};
    final extraKeys = <String>[
      for (final k in node.keys)
        if (k != 'type' && !knownKeys.contains(k) && !_isWidgetEdge(node[k])) k,
    ];
    final body = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space3,
          vertical: VibeTokens.space1,
        ),
        child: Text(
          pointer,
          style: TextStyle(
            fontFamily: VibeTokens.fontMono,
            fontSize: 10,
            color: c.textTertiary,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      for (final d in descriptors)
        if (!d.isWidgetEdge)
          _editorForDescriptor(node, d, '$pointer/${d.name}'),
      for (final k in extraKeys) _editorFor(node, k, '$pointer/$k'),
    ];
    if (descriptors.isEmpty && extraKeys.isEmpty) {
      body.add(
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space4,
            vertical: VibeTokens.space2,
          ),
          child: Text(
            catalog.knows(type)
                ? '(this widget exposes only child edges — pick a child in the tree to edit its leaves)'
                : '($type is not in the spec yet — drop into JSON if you need to edit it)',
            style: vibeMono(size: 11, color: c.textTertiary),
          ),
        ),
      );
    }
    return _Section(title: 'Selected · $type', children: body);
  }

  /// Build an editor for a schema-described property. The schema is
  /// authoritative — every spec'd field shows up regardless of whether
  /// the JSON node currently carries a value, so the user can set,
  /// override, or clear (= return to inherited / default) any of them.
  Widget _editorForDescriptor(
    Map<String, dynamic> node,
    WidgetPropertyDescriptor d,
    String fieldPath,
  ) {
    final v = node[d.name];
    final enumValues = d.enumValues;
    if (enumValues != null && enumValues.isNotEmpty) {
      return VibeEnumEditor(
        label: d.name,
        value: v is String ? v : null,
        options: enumValues,
        dispatch: dispatch,
        layer: layer,
        path: fieldPath,
      );
    }
    if (_isColorKey(d.name)) {
      return VibeColorEditor(
        label: d.name,
        value: v is String ? v : null,
        dispatch: dispatch,
        layer: layer,
        path: fieldPath,
      );
    }
    final t = d.jsonType;
    if (t == 'integer' || t == 'number') {
      return VibeTextEditor(
        label: d.name,
        numeric: true,
        value: v?.toString(),
        dispatch: dispatch,
        layer: layer,
        path: fieldPath,
      );
    }
    if (t == 'boolean') {
      return VibeBoolEditor(
        label: d.name,
        value: v is bool ? v : null,
        dispatch: dispatch,
        layer: layer,
        path: fieldPath,
        schemaDefault: _parseBoolDefault(d.defaultValue),
      );
    }
    // Primitive-aware sub-editor mapping. Property name signals the
    // primitive type when the schema description points at a known
    // _primitive/* shape. Anything we don't recognise still falls
    // through to JSON for hand authoring.
    final primitive = _primitiveTypeFor(d.name);
    if (primitive != null) {
      return _primitiveSubEditor(primitive, d.name, v, fieldPath);
    }
    if (t == 'object' || t == 'array' || v is Map || v is List) {
      return VibeJsonEditor(
        label: d.name,
        value: v,
        dispatch: dispatch,
        layer: layer,
        path: fieldPath,
      );
    }
    return VibeTextEditor(
      label: d.name,
      value: v?.toString(),
      dispatch: dispatch,
      layer: layer,
      path: fieldPath,
    );
  }

  /// Map a property name to a 1.3.4 _primitive type when the spec
  /// references that primitive at this field. Authors get the typed
  /// sub-editor instead of raw JSON.
  String? _primitiveTypeFor(String name) {
    switch (name) {
      case 'decoration':
        return 'BoxDecoration';
      case 'gradient':
      case 'shader':
        return 'Gradient';
      case 'border':
        return 'BoxBorder';
      case 'borderRadius':
      case 'indicatorShape':
        return 'BorderRadius';
      case 'boxShadow':
      case 'shadows':
        return 'BoxShadow[]';
      case 'image':
      case 'backgroundImage':
        return 'BackgroundImage';
      case 'style':
      case 'labelStyle':
        return 'TextStyle';
      default:
        return null;
    }
  }

  Widget _primitiveSubEditor(
    String primitive,
    String label,
    dynamic v,
    String fieldPath,
  ) {
    final c = VibeTokens.color;
    Widget header = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space4,
        vertical: 4,
      ),
      child: Text(
        '$label  ($primitive)',
        style: vibeMono(size: 11, color: c.textTertiary),
      ),
    );
    Widget body;
    switch (primitive) {
      case 'BoxDecoration':
        body = _BoxDecorationEditor(
          value:
              v is Map
                  ? Map<String, dynamic>.from(v)
                  : const <String, dynamic>{},
          dispatch: dispatch,
          layer: layer,
          basePath: fieldPath,
        );
        break;
      case 'Gradient':
        body = _GradientEditor(
          value:
              v is Map
                  ? Map<String, dynamic>.from(v)
                  : const <String, dynamic>{},
          dispatch: dispatch,
          layer: layer,
          basePath: fieldPath,
        );
        break;
      case 'BoxBorder':
        body = _BoxBorderEditor(
          value: v,
          dispatch: dispatch,
          layer: layer,
          basePath: fieldPath,
        );
        break;
      case 'BorderRadius':
        body = _BorderRadiusEditor(
          value: v,
          dispatch: dispatch,
          layer: layer,
          basePath: fieldPath,
        );
        break;
      case 'BoxShadow[]':
        body = _BoxShadowListEditor(
          shadows: v is List ? v : const <dynamic>[],
          dispatch: dispatch,
          layer: layer,
          basePath: fieldPath,
        );
        break;
      case 'BackgroundImage':
        body = _BackgroundImageEditor(
          value:
              v is Map
                  ? Map<String, dynamic>.from(v)
                  : const <String, dynamic>{},
          dispatch: dispatch,
          layer: layer,
          basePath: fieldPath,
        );
        break;
      case 'TextStyle':
        body = _TextStyleEditor(
          value:
              v is Map
                  ? Map<String, dynamic>.from(v)
                  : const <String, dynamic>{},
          dispatch: dispatch,
          layer: layer,
          basePath: fieldPath,
        );
        break;
      default:
        body = VibeJsonEditor(
          label: label,
          value: v,
          dispatch: dispatch,
          layer: layer,
          path: fieldPath,
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[header, body],
    );
  }

  /// Pick the right editor type for a leaf key. Color-typed keys get
  /// a swatch + picker; numbers → numeric text; bools / lists / maps →
  /// JSON editor; unknown leaves fall back to text.
  Widget _editorFor(Map<String, dynamic> node, String key, String fieldPath) {
    final v = node[key];
    if (_isColorKey(key)) {
      return VibeColorEditor(
        label: key,
        value: v is String ? v : null,
        dispatch: dispatch,
        layer: layer,
        path: fieldPath,
      );
    }
    if (v is num || (v == null && _isNumericKey(key))) {
      return VibeTextEditor(
        label: key,
        numeric: true,
        value: v?.toString(),
        dispatch: dispatch,
        layer: layer,
        path: fieldPath,
      );
    }
    if (v is bool || v is List || v is Map) {
      return VibeJsonEditor(
        label: key,
        value: v,
        dispatch: dispatch,
        layer: layer,
        path: fieldPath,
      );
    }
    return VibeTextEditor(
      label: key,
      value: v?.toString(),
      dispatch: dispatch,
      layer: layer,
      path: fieldPath,
    );
  }

  /// Heuristic: any key whose name is `color` exactly or ends with
  /// `Color` (camelCase like `backgroundColor`, `borderColor`, ...).
  /// Picks up the common spec slots without listing each one.
  static bool _isColorKey(String key) {
    if (key == 'color') return true;
    return key.length > 5 && key.endsWith('Color');
  }

  static bool _isWidgetEdge(dynamic v) {
    if (v is Map && v.containsKey('type')) return true;
    if (v is List && v.isNotEmpty) {
      return v.every((e) => e is Map && e.containsKey('type'));
    }
    return false;
  }

  /// Parse the schema's `default` text into a bool. The descriptor
  /// stringifies JSON defaults verbatim (`"true"`, `"false"`); keep
  /// other shapes unhandled so the editor falls through to "no
  /// default" rather than guessing.
  static bool? _parseBoolDefault(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim().replaceAll('"', '');
    if (trimmed == 'true') return true;
    if (trimmed == 'false') return false;
    return null;
  }

  static const Set<String> _knownNumericKeys = <String>{
    'width',
    'height',
    'gap',
    'maxLines',
    'flex',
    'opacity',
    'elevation',
    'borderRadius',
    'fontSize',
  };

  static bool _isNumericKey(String key) => _knownNumericKeys.contains(key);
}

class _WholeBody extends StatelessWidget {
  const _WholeBody({required this.projection});
  final LayerProjection projection;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: <Widget>[
        _Section(
          title: 'Summary',
          children: <Widget>[
            _Field(
              label: 'routes',
              value: '${projection.appStructure.routes.length}',
            ),
            _Field(
              label: 'components',
              value: '${projection.components.templates.length}',
            ),
            _Field(label: 'pages', value: '${projection.pages.length}'),
            _Field(
              label: 'theme tokens',
              value: '${projection.theme.raw.length}',
            ),
          ],
        ),
      ],
    );
  }
}

/// Bundle-mode `manifest` layer editor — edits the top-level identity
/// block (`/manifest/id|name|version|description|type`) and reflects the
/// declared requires / ui / section counts read-only.
class _ManifestBody extends StatelessWidget {
  const _ManifestBody({required this.projection, required this.dispatch});

  final LayerProjection projection;
  final PatchDispatcher dispatch;

  @override
  Widget build(BuildContext context) {
    final manifest =
        (projection.rawJson['manifest'] as Map?) ?? const <String, dynamic>{};
    final requires =
        (projection.rawJson['requires'] as Map?) ?? const <String, dynamic>{};
    final builtinAtoms =
        (requires['builtinAtoms'] as List?) ?? const <dynamic>[];
    final builtinTools =
        (requires['builtinTools'] as List?) ?? const <dynamic>[];
    // `agents` is a section map (`{agents: [...]}`), not a bare list —
    // mirrors the `tools` / `settings` shape. Casting it as a List throws
    // when mcp_bundle's loader emits the canonical wrapped form.
    final agentsSection =
        (projection.rawJson['agents'] as Map?) ?? const <String, dynamic>{};
    final agents = (agentsSection['agents'] as List?) ?? const <dynamic>[];
    final toolsSection =
        (projection.rawJson['tools'] as Map?) ?? const <String, dynamic>{};
    final toolsList = (toolsSection['tools'] as List?) ?? const <dynamic>[];
    final ui = (projection.rawJson['ui'] as Map?) ?? const <String, dynamic>{};
    final wiring =
        (projection.rawJson['wiring'] as Map?) ?? const <String, dynamic>{};
    final knowledge =
        (projection.rawJson['knowledge'] as Map?) ?? const <String, dynamic>{};
    final settings =
        (projection.rawJson['settings'] as Map?) ?? const <String, dynamic>{};
    final settingsSections =
        (settings['sections'] as List?) ?? const <dynamic>[];

    return ListView(
      children: <Widget>[
        _Section(
          title: 'General',
          children: <Widget>[
            VibeTextEditor(
              label: 'id',
              value: manifest['id'] as String?,
              dispatch: dispatch,
              layer: LayerId.manifest,
              path: '/manifest/id',
            ),
            VibeTextEditor(
              label: 'name',
              value: manifest['name'] as String?,
              dispatch: dispatch,
              layer: LayerId.manifest,
              path: '/manifest/name',
            ),
            VibeTextEditor(
              label: 'version',
              value: manifest['version'] as String?,
              dispatch: dispatch,
              layer: LayerId.manifest,
              path: '/manifest/version',
            ),
            VibeTextEditor(
              label: 'description',
              value: manifest['description'] as String?,
              dispatch: dispatch,
              layer: LayerId.manifest,
              path: '/manifest/description',
            ),
            VibeTextEditor(
              label: 'type',
              value: manifest['type'] as String?,
              dispatch: dispatch,
              layer: LayerId.manifest,
              path: '/manifest/type',
            ),
          ],
        ),
        _Section(
          title: 'Requires',
          children: <Widget>[
            _Field(
              label: 'builtinAtoms',
              value: builtinAtoms.isEmpty ? '—' : builtinAtoms.join(', '),
            ),
            _Field(
              label: 'builtinTools',
              value: builtinTools.isEmpty ? '—' : builtinTools.join(', '),
            ),
          ],
        ),
        _Section(
          title: 'UI',
          children: <Widget>[
            _Field(label: 'kind', value: (ui['kind'] as String?) ?? '—'),
            _Field(label: 'path', value: (ui['path'] as String?) ?? '—'),
          ],
        ),
        _Section(
          title: 'Sections',
          children: <Widget>[
            _Field(label: 'agents', value: '${agents.length}'),
            _Field(label: 'tools', value: '${toolsList.length}'),
            _Field(label: 'wiring entries', value: '${wiring.length}'),
            _Field(label: 'knowledge entries', value: '${knowledge.length}'),
            _Field(
              label: 'settings sections',
              value: '${settingsSections.length}',
            ),
          ],
        ),
      ],
    );
  }
}

/// Bundle-mode `knowledge` / `tools` / `agents` properties placeholder.
/// The full editors for these layers render in the center column
/// (BundleKnowledgeView / BundleToolsView / BundleAgentsView); the
/// properties panel just reflects the card is wired and shows a count.
class _KnowledgePlaceholderBody extends StatelessWidget {
  const _KnowledgePlaceholderBody({required this.projection});
  final LayerProjection projection;

  @override
  Widget build(BuildContext context) {
    final knowledge =
        (projection.rawJson['knowledge'] as Map?) ?? const <String, dynamic>{};
    return ListView(
      children: <Widget>[
        _Section(
          title: 'Bundle layer',
          children: <Widget>[
            const _Field(
              label: 'editor',
              value: 'Full editing is in the center column',
            ),
            _Field(label: 'knowledge entries', value: '${knowledge.length}'),
          ],
        ),
      ],
    );
  }
}
