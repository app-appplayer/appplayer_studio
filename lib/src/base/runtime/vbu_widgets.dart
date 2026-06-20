/// Custom mcp_ui_runtime widgets exposing the full `vbu_studio_ui`
/// atom set to bundle DSL authors. Hosts call [registerVbuWidgets] on
/// a freshly-constructed `MCPUIRuntime`; bundles then reference each
/// atom by PascalCase name (`{"type": "VbuPill", ...}`).
///
/// The factories below are intentionally thin: they extract the
/// declarative properties, resolve bindings via [RenderContext], dispatch
/// callbacks as DSL actions, and instantiate the underlying Flutter
/// widget. No spec change is required — these are runtime-local custom
/// widgets, scoped to this `MCPUIRuntime` instance only.
library;

import 'package:flutter/material.dart';
// Namespace-forked runtime — see `tool_widgets.dart` rationale.
import 'package:appplayer_studio/runtime.dart';
import 'package:appplayer_studio/ui.dart';

import '../widgets/editors/bundle_knowledge_view.dart';
import '../widgets/editors/bundle_manifest_view.dart';
import '../widgets/vbu_settings_sections_form.dart';

/// Register every `vbu_*` atom on [runtime] under its PascalCase name.
/// Each factory is wrapped in [_MetadataWrappingFactory] so the rendered
/// widget carries a `MetaData` node — `studio.renderer.layout_snapshot`
/// then picks it up and reports `{type, id?, label?}` to the LLM
/// without an image-vision round trip.
void registerVbuWidgets(MCPUIRuntime runtime) {
  void reg(String name, WidgetFactory factory) =>
      runtime.registerWidget(name, _MetadataWrappingFactory(name, factory));
  reg('VbuActivityBar', _VbuActivityBarFactory());
  reg('VbuBundleEmbed', _VbuBundleEmbedPlaceholderFactory());
  reg('VbuBundleKnowledgeView', _VbuBundleKnowledgeViewFactory());
  reg('VbuBundleManifestView', _VbuBundleManifestViewFactory());
  reg('VbuBundleToolsEditor', _VbuBundleToolsEditorPlaceholderFactory());
  reg('VbuBusyIndicator', _VbuBusyIndicatorFactory());
  reg('VbuChannelStrip', _VbuChannelStripFactory());
  reg('VbuComposer', _VbuComposerFactory());
  reg('VbuCopyOnHover', _VbuCopyOnHoverFactory());
  reg('VbuDialogScaffold', _VbuDialogScaffoldFactory());
  reg('VbuDomainActionsRow', _VbuDomainActionsRowFactory());
  reg('VbuFormSection', _VbuFormSectionFactory());
  reg('VbuHeroPanel', _VbuHeroPanelFactory());
  reg('VbuInspectorPanel', _VbuInspectorPanelFactory());
  reg('VbuInstanceStrip', _VbuInstanceStripFactory());
  reg('VbuHistoryViewer', _VbuHistoryViewerFactory());
  reg('VbuIconButton', _VbuIconButtonFactory());
  reg('VbuJsonEditor', _VbuJsonEditorFactory());
  reg('VbuLabelledField', _VbuLabelledFieldFactory());
  reg('VbuLabelledFolder', _VbuLabelledFolderFactory());
  reg('VbuLabelledMenu', _VbuLabelledMenuFactory());
  reg('VbuLabelledToggle', _VbuLabelledToggleFactory());
  reg('VbuColorEditor', _VbuColorEditorFactory());
  reg('VbuIconEditor', _VbuIconEditorFactory());
  reg('VbuLayerCard', _VbuLayerCardFactory());
  reg('VbuMasterDetail', _VbuMasterDetailFactory());
  reg('VbuMiniPreview', _VbuMiniPreviewFactory());
  reg('VbuOverviewStrip', _VbuOverviewStripFactory());
  reg('VbuPaneHeader', _VbuPaneHeaderFactory());
  reg('VbuWidgetTreeOutline', _VbuWidgetTreeOutlineFactory());
  reg('VbuPanelDialogScaffold', _VbuPanelDialogScaffoldFactory());
  reg('VbuPanelSplitter', _VbuPanelSplitterFactory());
  reg('VbuPathTile', _VbuPathTileFactory());
  reg('VbuPill', _VbuPillFactory());
  reg('VbuPreviewMcpUi', _VbuPreviewMcpUiPlaceholderFactory());
  reg('VbuPropertiesForm', _VbuPropertiesFormFactory());
  reg('VbuProjectNameRow', _VbuProjectNameRowFactory());
  reg('VbuPromptBubble', _VbuPromptBubbleFactory());
  reg('VbuRecentMenuButton', _VbuRecentMenuButtonFactory());
  reg('VbuRouter', _VbuRouterFactory());
  reg('VbuSettingsSectionsForm', _VbuSettingsSectionsFormFactory());
  reg('VbuSlashChips', _VbuSlashChipsFactory());
  reg('VbuSnapshotDiff', _VbuSnapshotDiffFactory());
  reg('VbuStatusbar', _VbuStatusbarFactory());
  reg('VbuStatusDot', _VbuStatusDotFactory());
  reg('VbuStatusBadge', _VbuStatusBadgeFactory());
  reg('VbuSystemNote', _VbuSystemNoteFactory());
  reg('VbuTabStrip', _VbuTabStripFactory());
  reg('VbuTimeline', _VbuTimelineFactory());
  reg('VbuTitleBar', _VbuTitleBarFactory());
  reg('VbuToolsList', _VbuToolsListFactory());
  reg('VbuVideoPlayer', _VbuVideoPlayerFactory());
  // Host override of `button` — adds `click: [action1, action2, ...]`
  // multi-action support. The mcp_ui_runtime stock button only
  // accepts a single Map for click and casts it directly, so a List
  // there throws. We wrap with a factory that walks the list and
  // dispatches each action in order. Single Map click still works
  // exactly as before.
  runtime.registerWidget('button', _ButtonOverrideFactory());
  // `text` override — variant maps to vbu typography tokens (Material
  // `titleLarge`/`bodyMedium`/etc. would otherwise pull system text
  // styles that drift from the chrome's mono tone).
  runtime.registerWidget('text', _TextOverrideFactory());
}

/// Wraps another [WidgetFactory] so the rendered widget is enclosed in
/// a `MetaData` node. The metadata exposes the widget's PascalCase
/// type, plus `id` / `label` / `title` if the DSL definition carries
/// them — `studio.renderer.layout_snapshot` walks these and reports
/// them to the LLM (image-free layout introspection).
class _MetadataWrappingFactory extends WidgetFactory {
  _MetadataWrappingFactory(this.typeName, this.inner);
  final String typeName;
  final WidgetFactory inner;

  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final widget = inner.build(definition, context);
    final meta = <String, dynamic>{'type': typeName};
    for (final key in const <String>['id', 'label', 'title', 'name']) {
      final v = definition[key];
      if (v is String && v.isNotEmpty) meta[key] = v;
    }
    return MetaData(metaData: meta, child: widget);
  }
}

// ---------------------------------------------------------------------------
// Shared helpers — icon / color / child / callback resolution.
// ---------------------------------------------------------------------------

IconData _icon(Object? raw, {IconData fallback = Icons.circle}) =>
    resolveIconName(raw, fallback: fallback);

/// Resolve a Material icon by name (e.g. `'construction_outlined'`).
/// Strips an optional `icons.` prefix. Returns [fallback] when [raw] is
/// not a string or the name is not in the map.
IconData resolveIconName(Object? raw, {IconData fallback = Icons.circle}) {
  if (raw is IconData) return raw;
  if (raw is! String) return fallback;
  final name = raw.startsWith('icons.') ? raw.substring(6) : raw;
  return _iconNames[name] ?? fallback;
}

Color? _color(Object? raw) {
  if (raw is Color) return raw;
  if (raw is! String) return null;
  var s = raw.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) s = 'FF$s';
  if (s.length != 8) return null;
  final v = int.tryParse(s, radix: 16);
  return v == null ? null : Color(v);
}

Widget? _child(Object? def, RenderContext ctx) {
  if (def is Map<String, dynamic>) return ctx.buildWidget(def);
  return null;
}

List<Widget> _children(Object? defs, RenderContext ctx) {
  if (defs is! List) return const <Widget>[];
  return <Widget>[
    for (final d in defs)
      if (d is Map<String, dynamic>) ctx.buildWidget(d),
  ];
}

/// Dispatch [actionDef] when it's a Map (single action) OR a List of
/// Map (sequential multi-action). Returns null when the def is
/// missing entirely. Sequential await so each step's state writes
/// land before the next dispatches.
Future<void> _dispatch(Object? actionDef, RenderContext ctx) async {
  if (actionDef == null) return;
  if (actionDef is Map<String, dynamic>) {
    await ctx.handleAction(actionDef);
    return;
  }
  if (actionDef is Map) {
    await ctx.handleAction(Map<String, dynamic>.from(actionDef));
    return;
  }
  if (actionDef is List) {
    for (final a in actionDef) {
      if (a is Map<String, dynamic>) {
        await ctx.handleAction(a);
      } else if (a is Map) {
        await ctx.handleAction(Map<String, dynamic>.from(a));
      }
    }
  }
}

VoidCallback? _callback(Object? actionDef, RenderContext ctx) {
  if (actionDef == null) return null;
  if (actionDef is! Map && actionDef is! List) return null;
  return () => _dispatch(actionDef, ctx);
}

Future<void> Function()? _asyncCallback(Object? actionDef, RenderContext ctx) {
  if (actionDef == null) return null;
  if (actionDef is! Map && actionDef is! List) return null;
  return () => _dispatch(actionDef, ctx);
}

ValueChanged<T>? _valueCallback<T>(Object? actionDef, RenderContext ctx) {
  if (actionDef is! Map<String, dynamic>) return null;
  return (T value) {
    final patched = Map<String, dynamic>.from(actionDef);
    // Substitute `{{event.value}}` placeholder inside params + value.
    // Standard mcp_ui_runtime 1.3 input factories (radio / numberField /
    // datepicker / etc.) all do the same substitution at the factory
    // level instead of relying on a runtime binding resolver — match
    // that pattern so vbu_* atoms behave identically.
    final rawParams = patched['params'];
    if (rawParams is Map) {
      final params = Map<String, dynamic>.from(rawParams);
      params.forEach((k, v) {
        if (v == '{{event.value}}') params[k] = value;
      });
      patched['params'] = params;
    }
    if (patched['value'] == '{{event.value}}') {
      patched['value'] = value;
    }
    // Keep $event in params as well so callers preferring `{{event.value}}`
    // resolution via the binding system still see something.
    final p = patched['params'];
    if (p is Map<String, dynamic>) {
      p[r'$event'] = value;
    }
    ctx.handleAction(patched);
  };
}

const _iconNames = <String, IconData>{
  'home': Icons.home,
  'home_outlined': Icons.home_outlined,
  'add': Icons.add,
  'close': Icons.close,
  'check': Icons.check,
  'delete': Icons.delete,
  'edit': Icons.edit,
  'folder': Icons.folder,
  'folder_open': Icons.folder_open,
  'settings': Icons.settings,
  'info': Icons.info,
  'info_outline': Icons.info_outline,
  'warning': Icons.warning,
  'error': Icons.error,
  'search': Icons.search,
  'refresh': Icons.refresh,
  'play_arrow': Icons.play_arrow,
  'stop': Icons.stop,
  'pause': Icons.pause,
  'chevron_left': Icons.chevron_left,
  'chevron_right': Icons.chevron_right,
  'expand_more': Icons.expand_more,
  'expand_less': Icons.expand_less,
  'more_vert': Icons.more_vert,
  'more_horiz': Icons.more_horiz,
  'extension': Icons.extension,
  'extension_outlined': Icons.extension_outlined,
  'construction': Icons.construction,
  'construction_outlined': Icons.construction_outlined,
  'movie_creation': Icons.movie_creation,
  'movie_creation_outlined': Icons.movie_creation_outlined,
  'star': Icons.star,
  'star_border': Icons.star_border,
  'push_pin': Icons.push_pin,
  'push_pin_outlined': Icons.push_pin_outlined,
  'history': Icons.history,
  'arrow_upward': Icons.arrow_upward,
  'arrow_downward': Icons.arrow_downward,
  'arrow_back': Icons.arrow_back,
  'arrow_forward': Icons.arrow_forward,
  'menu': Icons.menu,
  'check_circle': Icons.check_circle,
  'cancel': Icons.cancel,
  'visibility': Icons.visibility,
  'visibility_off': Icons.visibility_off,
  'cloud': Icons.cloud,
  'download': Icons.download,
  'upload': Icons.upload,
  'send': Icons.send,
  'copy': Icons.copy,
  'content_copy': Icons.content_copy,
  'open_in_new': Icons.open_in_new,
  'build': Icons.build_outlined,
  'preview': Icons.preview_outlined,
  'school': Icons.school_outlined,
  'description': Icons.description_outlined,
  'tune': Icons.tune,
  'dashboard_customize': Icons.dashboard_customize_outlined,
  'alternate_email': Icons.alternate_email,
  'architecture': Icons.architecture_outlined,
};

// ---------------------------------------------------------------------------
// VbuActivityBar
// ---------------------------------------------------------------------------

class _VbuActivityBarFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawGroups = context.resolve<Object?>(props['groups']);
    final groups = <List<VbuActivityBarItem>>[];
    if (rawGroups is List) {
      for (final g in rawGroups) {
        if (g is List) {
          groups.add(<VbuActivityBarItem>[
            for (final item in g)
              if (item is Map<String, dynamic>)
                VbuActivityBarItem(
                  tooltip: context.resolve<String?>(item['tooltip']) ?? '',
                  icon: _icon(context.resolve<Object?>(item['icon'])),
                  onTap: _callback(item['onTap'], context),
                  emphasised:
                      context.resolve<bool?>(item['emphasised']) ?? false,
                ),
          ]);
        }
      }
    }
    final widget = VbuActivityBar(
      groups: groups,
      width: (context.resolve<num?>(props['width']) ?? 36).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuBusyIndicator
// ---------------------------------------------------------------------------

class _VbuBusyIndicatorFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuBusyIndicator(
      label: context.resolve<String?>(props['label']) ?? 'thinking…',
      dotColor: _color(context.resolve<Object?>(props['dotColor'])),
      cycleDuration: Duration(
        milliseconds: (context.resolve<num?>(props['cycleMs']) ?? 1200).toInt(),
      ),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuComposer — text input bound to a state key for value + a submit
// action. The factory owns a TextEditingController scoped to the widget
// instance and pushes every edit to the bound state so the DSL state
// tree stays the source of truth.
// ---------------------------------------------------------------------------

class _VbuComposerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = _VbuComposerWidget(ctx: context, props: props);
    return applyCommonWrappers(widget, props, context);
  }
}

class _VbuComposerWidget extends StatefulWidget {
  const _VbuComposerWidget({required this.ctx, required this.props});
  final RenderContext ctx;
  final Map<String, dynamic> props;
  @override
  State<_VbuComposerWidget> createState() => _VbuComposerWidgetState();
}

class _VbuComposerWidgetState extends State<_VbuComposerWidget> {
  late final TextEditingController _ctrl;
  @override
  void initState() {
    super.initState();
    final initial = widget.ctx.resolve<String?>(widget.props['value']) ?? '';
    _ctrl = TextEditingController(text: initial);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onSubmit = _asyncCallback(widget.props['onSubmit'], widget.ctx);
    return VbuComposer(
      controller: _ctrl,
      onSubmit: onSubmit ?? () async {},
      hint:
          widget.ctx.resolve<String?>(widget.props['hint']) ??
          'Send a message…',
      busy: widget.ctx.resolve<bool?>(widget.props['busy']) ?? false,
      minLines:
          (widget.ctx.resolve<num?>(widget.props['minLines']) ?? 1).toInt(),
      maxLines:
          (widget.ctx.resolve<num?>(widget.props['maxLines']) ?? 6).toInt(),
    );
  }
}

// ---------------------------------------------------------------------------
// VbuCopyOnHover — wraps a child, shows copy affordance when hovered.
// ---------------------------------------------------------------------------

class _VbuCopyOnHoverFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final child = _child(props['child'], context) ?? const SizedBox.shrink();
    final widget = VbuCopyOnHover(
      text: context.resolve<String?>(props['text']) ?? '',
      onDelete: _callback(props['onDelete'], context),
      copiedSnackText:
          context.resolve<String?>(props['copiedSnackText']) ?? 'Copied',
      child: child,
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuDialogScaffold
// ---------------------------------------------------------------------------

class _VbuDialogScaffoldFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final body = _child(props['body'], context) ?? const SizedBox.shrink();
    final widget = VbuDialogScaffold(
      title: context.resolve<String?>(props['title']) ?? '',
      subtitle: context.resolve<String?>(props['subtitle']),
      titleIcon: _maybeIcon(context.resolve<Object?>(props['titleIcon'])),
      titleIconColor: _color(context.resolve<Object?>(props['titleIconColor'])),
      body: body,
      actions: _children(props['actions'], context),
      leadingAction: _child(props['leadingAction'], context),
      maxWidth: (context.resolve<num?>(props['maxWidth']) ?? 640).toDouble(),
      maxHeight: (context.resolve<num?>(props['maxHeight']) ?? 720).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

IconData? _maybeIcon(Object? raw) {
  if (raw == null) return null;
  return _icon(raw);
}

// ---------------------------------------------------------------------------
// VbuDomainActionsRow
// ---------------------------------------------------------------------------

class _VbuDomainActionsRowFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawEntries = context.resolve<Object?>(props['entries']);
    final items = <VbuDomainActionItem>[];
    if (rawEntries is List) {
      for (final e in rawEntries) {
        if (e is! Map) continue;
        items.add(
          VbuDomainActionItem(
            icon: _icon(context.resolve<Object?>(e['icon'])),
            tooltip: context.resolve<String?>(e['tooltip']) ?? '',
            onTap: _callback(e['onTap'], context),
            divider: context.resolve<bool?>(e['divider']) ?? false,
          ),
        );
      }
    }
    final widget = VbuDomainActionsRow(
      entries: items,
      iconSize: (context.resolve<num?>(props['iconSize']) ?? 16).toDouble(),
      chipSize: (context.resolve<num?>(props['chipSize']) ?? 26).toDouble(),
      spacing: (context.resolve<num?>(props['spacing']) ?? 6).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuSettingsSectionsForm
// ---------------------------------------------------------------------------

class _VbuSettingsSectionsFormFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawSections = context.resolve<Object?>(props['sections']);
    final sections = <VbuSettingsSection>[];
    if (rawSections is List) {
      for (final s in rawSections) {
        if (s is! Map) continue;
        final fields = <VbuSettingsField>[];
        final rawFields = s['fields'];
        if (rawFields is List) {
          for (final f in rawFields) {
            if (f is! Map) continue;
            final options = <String>[];
            final rawOpts = f['options'];
            if (rawOpts is List) {
              for (final o in rawOpts) {
                if (o is String) options.add(o);
              }
            }
            fields.add(
              VbuSettingsField(
                key: context.resolve<String?>(f['key']) ?? '',
                label: context.resolve<String?>(f['label']) ?? '',
                type: context.resolve<String?>(f['type']) ?? 'text',
                value: context.resolve<Object?>(f['value']),
                options: options,
                onChanged: _onChangedCallback(f['onChanged'], context),
              ),
            );
          }
        }
        sections.add(
          VbuSettingsSection(
            key: context.resolve<String?>(s['key']) ?? '',
            label: context.resolve<String?>(s['label']) ?? '',
            fields: fields,
          ),
        );
      }
    }
    final widget = VbuSettingsSectionsForm(sections: sections);
    return applyCommonWrappers(widget, props, context);
  }
}

ValueChanged<Object?>? _onChangedCallback(Object? raw, RenderContext context) {
  final cb = _callback(raw, context);
  if (cb == null) return null;
  return (_) => cb();
}

// ---------------------------------------------------------------------------
// VbuSlashChips
// ---------------------------------------------------------------------------

class _VbuSlashChipsFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawChips = context.resolve<Object?>(props['chips']);
    final chips = <VbuSlashChipItem>[];
    if (rawChips is List) {
      for (final c in rawChips) {
        if (c is! Map) continue;
        chips.add(
          VbuSlashChipItem(
            command: context.resolve<String?>(c['command']) ?? '/',
            description: context.resolve<String?>(c['description']),
            directDispatch:
                context.resolve<bool?>(c['directDispatch']) ?? false,
            onTap: _callback(c['onTap'], context),
          ),
        );
      }
    }
    final widget = VbuSlashChips(
      chips: chips,
      spacing: (context.resolve<num?>(props['spacing']) ?? 6).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuFormSection
// ---------------------------------------------------------------------------

class _VbuFormSectionFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuFormSection(
      label: context.resolve<String?>(props['label']) ?? '',
      rowGap: (context.resolve<num?>(props['rowGap']) ?? 8).toDouble(),
      children: _children(props['children'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuHeroPanel
// ---------------------------------------------------------------------------

class _VbuHeroPanelFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawActions = context.resolve<Object?>(props['actions']);
    final actions = <VbuHeroAction>[];
    if (rawActions is List) {
      for (final a in rawActions) {
        if (a is Map<String, dynamic>) {
          actions.add(
            VbuHeroAction(
              label: context.resolve<String?>(a['label']) ?? '',
              icon: _icon(context.resolve<Object?>(a['icon'])),
              onPressed: _callback(a['onPressed'], context) ?? () {},
              emphasised: context.resolve<bool?>(a['emphasised']) ?? false,
            ),
          );
        }
      }
    }
    final widget = VbuHeroPanel(
      title: context.resolve<String?>(props['title']) ?? '',
      subtitle: context.resolve<String?>(props['subtitle']),
      actions: actions,
      footer: _child(props['footer'], context),
      maxWidth: (context.resolve<num?>(props['maxWidth']) ?? 520).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuHistoryViewer
// ---------------------------------------------------------------------------

class _VbuHistoryViewerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawEntries = context.resolve<Object?>(props['entries']);
    final entries = <VbuHistoryEntry>[];
    if (rawEntries is List) {
      for (final e in rawEntries) {
        if (e is Map<String, dynamic>) {
          final ts = e['timestamp'];
          DateTime? when;
          if (ts is String) when = DateTime.tryParse(ts);
          if (ts is num) {
            when = DateTime.fromMillisecondsSinceEpoch(ts.toInt());
          }
          if (when == null) continue;
          final paths = e['changedPaths'];
          entries.add(
            VbuHistoryEntry(
              timestamp: when,
              kindLabel: context.resolve<String?>(e['kindLabel']) ?? '',
              kindColor: _color(context.resolve<Object?>(e['kindColor'])),
              originatorLabel: context.resolve<String?>(e['originatorLabel']),
              changedPaths:
                  paths is List
                      ? paths.whereType<String>().toList()
                      : const <String>[],
            ),
          );
        }
      }
    }
    final widget = VbuHistoryViewer(
      entries: entries,
      title: context.resolve<String?>(props['title']) ?? 'Recent changes',
      emptyText:
          context.resolve<String?>(props['emptyText']) ??
          'No changes recorded yet.',
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuIconButton
// ---------------------------------------------------------------------------

class _VbuIconButtonFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuIconButton(
      tooltip: context.resolve<String?>(props['tooltip']) ?? '',
      icon: _icon(context.resolve<Object?>(props['icon'])),
      onTap: _callback(props['onTap'], context) ?? () {},
      emphasised: context.resolve<bool?>(props['emphasised']) ?? false,
      iconSize: (context.resolve<num?>(props['iconSize']) ?? 16).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuLabelledField — text field with label. Owns controller scoped to
// the widget so the DSL `value` binding stays the source of truth.
// ---------------------------------------------------------------------------

class _VbuLabelledFieldFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    return applyCommonWrappers(
      _VbuLabelledFieldWidget(ctx: context, props: props),
      props,
      context,
    );
  }
}

class _VbuLabelledFieldWidget extends StatefulWidget {
  const _VbuLabelledFieldWidget({required this.ctx, required this.props});
  final RenderContext ctx;
  final Map<String, dynamic> props;
  @override
  State<_VbuLabelledFieldWidget> createState() =>
      _VbuLabelledFieldWidgetState();
}

class _VbuLabelledFieldWidgetState extends State<_VbuLabelledFieldWidget> {
  late final TextEditingController _ctrl;
  @override
  void initState() {
    super.initState();
    final initial = widget.ctx.resolve<String?>(widget.props['value']) ?? '';
    _ctrl = TextEditingController(text: initial);
    final onChange = _valueCallback<String>(
      widget.props['onChanged'],
      widget.ctx,
    );
    if (onChange != null) {
      _ctrl.addListener(() => onChange(_ctrl.text));
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return VbuLabelledField(
      label: widget.ctx.resolve<String?>(widget.props['label']) ?? '',
      controller: _ctrl,
      hint: widget.ctx.resolve<String?>(widget.props['hint']) ?? '',
      obscure: widget.ctx.resolve<bool?>(widget.props['obscure']) ?? false,
      trailing: _child(widget.props['trailing'], widget.ctx),
      labelWidth:
          (widget.ctx.resolve<num?>(widget.props['labelWidth']) ?? 92)
              .toDouble(),
    );
  }
}

// ---------------------------------------------------------------------------
// VbuLabelledFolder
// ---------------------------------------------------------------------------

class _VbuLabelledFolderFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuLabelledFolder(
      label: context.resolve<String?>(props['label']) ?? '',
      value: context.resolve<String?>(props['value']) ?? '',
      hint: context.resolve<String?>(props['hint']) ?? '',
      onPick: _asyncCallback(props['onPick'], context) ?? () async {},
      onClear: _callback(props['onClear'], context),
      labelWidth: (context.resolve<num?>(props['labelWidth']) ?? 92).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuLabelledMenu — generic dropdown. Options are List<dynamic>; values
// pass through unmodified, labels supplied via `labels` map.
// ---------------------------------------------------------------------------

class _VbuLabelledMenuFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final options =
        (context.resolve<Object?>(props['options']) as List?)
            ?.cast<Object?>() ??
        const <Object?>[];
    final labelsRaw = context.resolve<Object?>(props['labels']);
    final labels = <Object?, String>{};
    if (labelsRaw is Map) {
      labelsRaw.forEach((k, v) {
        if (v is String) labels[k] = v;
      });
    }
    final widget = VbuLabelledMenu<Object?>(
      label: context.resolve<String?>(props['label']) ?? '',
      value: context.resolve<Object?>(props['value']),
      options: options,
      onChanged: _valueCallback<Object?>(props['onChanged'], context) ?? (_) {},
      labels: labels,
      labelWidth: (context.resolve<num?>(props['labelWidth']) ?? 92).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuLabelledToggle
// ---------------------------------------------------------------------------

class _VbuLabelledToggleFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuLabelledToggle(
      label: context.resolve<String?>(props['label']) ?? '',
      value: context.resolve<bool?>(props['value']) ?? false,
      onChanged: _valueCallback<bool>(props['onChanged'], context) ?? (_) {},
      hint: context.resolve<String?>(props['hint']),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuBundleEmbed — placeholder factory. The real factory mounts a
// nested `DslWorkspaceView` to render another bundle's `ui/app.json`
// as a sub-runtime. That factory lives in `vibe_studio_workspace`
// (workspace imports base, so the override happens there after this
// placeholder is registered) — see `DslWorkspaceView._bootRuntime`.
// ---------------------------------------------------------------------------

class _VbuBundleEmbedPlaceholderFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuBundleEmbed(
      bundlePath: context.resolve<String?>(props['bundlePath']) ?? '',
      uiPath: context.resolve<String?>(props['uiPath']) ?? 'ui/app.json',
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuBundleKnowledgeView — mounts the per-bundle knowledge editor body
// (chunks / facts / skills / profiles / philosophies / agents). Today
// renders BundleEditorPlaceholder; future phases swap in a 6-category
// designer backed by `studio.builder.addKnowledge*` mutators.
// ---------------------------------------------------------------------------

class _VbuBundleKnowledgeViewFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final bundlePath = context.resolve<String?>(props['bundlePath']) ?? '';
    final widget =
        bundlePath.isEmpty
            ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No bundle adopted yet — create or open a package.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.white54,
                  ),
                ),
              ),
            )
            : BundleKnowledgeView(bundlePath: bundlePath);
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuBundleManifestView — mounts the per-bundle top-level metadata editor
// (id / name / version / description / requires / chat). Today renders
// BundleEditorPlaceholder; future phases swap in a dedicated metadata
// form backed by `studio.builder.patchManifest`.
// ---------------------------------------------------------------------------

class _VbuBundleManifestViewFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final bundlePath = context.resolve<String?>(props['bundlePath']) ?? '';
    final widget =
        bundlePath.isEmpty
            ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No bundle adopted yet — create or open a package.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.white54,
                  ),
                ),
              ),
            )
            : BundleManifestView(bundlePath: bundlePath);
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuBundleToolsEditor — placeholder factory. The real factory mounts the
// host's `BundleToolsView` against the target bundle so authors get the
// full master-detail wiring editor (Tools / Domain Icons / Slash Commands /
// Settings / Lifecycle, click-to-edit detail) via DSL. The real factory
// needs ChromeBridge + configRoot — both live above base — so it lives in
// `vibe_studio_workspace` and overrides this placeholder after register.
// ---------------------------------------------------------------------------

class _VbuBundleToolsEditorPlaceholderFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final bundlePath = context.resolve<String?>(props['bundlePath']) ?? '';
    final widget = Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          bundlePath.isEmpty
              ? 'No bundle adopted yet — create or open a package.'
              : 'Wiring editor placeholder — host did not register the '
                  'real VbuBundleToolsEditor factory.',
          textAlign: TextAlign.center,
          style: vbuMono(
            size: 11,
            color:
                (context.themeManager.effectiveMode == 'dark'
                        ? VbuTokens.color
                        : VbuTokens.lightColor)
                    .textTertiary,
          ),
        ),
      ),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuMasterDetail — labeled left panel (icon + label rows) + right
// detail body. Mirrors PropertiesPanel / InspectorPanel shell tone via
// the registered atom path so DSL authors compose master-detail layouts
// without hand-rolling the chrome.
// ---------------------------------------------------------------------------

class _VbuMasterDetailFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawSections = context.resolve<Object?>(props['sections']);
    final sections = <VbuMasterDetailSection>[];
    if (rawSections is List) {
      for (final s in rawSections) {
        if (s is! Map) continue;
        final rawItems = s['items'];
        final items = <VbuMasterDetailItem>[];
        if (rawItems is List) {
          for (final e in rawItems) {
            if (e is! Map) continue;
            items.add(
              VbuMasterDetailItem(
                label: context.resolve<String?>(e['label']) ?? '',
                icon: _icon(context.resolve<Object?>(e['icon'])),
                sub: context.resolve<String?>(e['sub']),
                trailingPill: context.resolve<String?>(e['trailingPill']),
                selected: context.resolve<bool?>(e['selected']) ?? false,
                onTap: _callback(e['onTap'], context),
              ),
            );
          }
        }
        sections.add(
          VbuMasterDetailSection(
            title: context.resolve<String?>(s['title']) ?? '',
            items: items,
          ),
        );
      }
    }
    final widget = VbuMasterDetail(
      panelLabel: context.resolve<String?>(props['panelLabel']) ?? '',
      sections: sections,
      body: _child(props['body'], context) ?? const SizedBox.shrink(),
      panelWidth:
          (context.resolve<num?>(props['panelWidth']) ?? 240).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuRouter — value-based page swap. The DSL resolves `value` (typically
// `{{runtime.navigation.currentRoute}}`) to a string, looks it up in
// `cases`, and renders the matching child. Fills the gap left by
// `conditional`'s truthy-only check so domains can drive page swaps
// from a single state key (set via `studio_builder.gotoPage` etc.).
// ---------------------------------------------------------------------------

class _VbuRouterFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final value = context.resolve<String?>(props['value']) ?? '';
    final rawCases = context.resolve<Object?>(props['cases']);
    final cases = <String, Widget>{};
    if (rawCases is Map) {
      rawCases.forEach((k, v) {
        if (k is String && v is Map<String, dynamic>) {
          cases[k] = context.buildWidget(v);
        }
      });
    }
    final widget = VbuRouter(
      value: value,
      cases: cases,
      fallback: _child(props['fallback'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuPaneHeader
// ---------------------------------------------------------------------------

class _VbuColorEditorFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuColorEditor(
      label: context.resolve<String?>(props['label']) ?? '',
      value: context.resolve<String?>(props['value']),
      onChange: _valueCallback<String?>(props['onChange'], context),
      onSwatchTap: _callback(props['onSwatchTap'], context),
      labelWidth: (context.resolve<num?>(props['labelWidth']) ?? 90).toDouble(),
      fieldWidth: (context.resolve<num?>(props['fieldWidth']) ?? 92).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

class _VbuIconEditorFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuIconEditor(
      label: context.resolve<String?>(props['label']) ?? '',
      value: context.resolve<String?>(props['value']),
      onChange: _valueCallback<String?>(props['onChange'], context),
      onPickerOpen: _callback(props['onPickerOpen'], context),
      labelWidth: (context.resolve<num?>(props['labelWidth']) ?? 90).toDouble(),
      fieldWidth:
          (context.resolve<num?>(props['fieldWidth']) ?? 110).toDouble(),
      iconResolver: (name) => _iconNames[name],
    );
    return applyCommonWrappers(widget, props, context);
  }
}

class _VbuWidgetTreeOutlineFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final raw = context.resolve<Object?>(props['root']);
    final root = _buildTreeNodes(raw);
    final widget = VbuWidgetTreeOutline(
      root: root,
      selectedId: context.resolve<String?>(props['selectedId']),
      onSelect: _valueCallback<String>(props['onSelect'], context),
      indent: (context.resolve<num?>(props['indent']) ?? 14).toDouble(),
      rowHeight: (context.resolve<num?>(props['rowHeight']) ?? 24).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }

  List<VbuWidgetTreeNode> _buildTreeNodes(Object? raw) {
    if (raw is! List) return const <VbuWidgetTreeNode>[];
    final out = <VbuWidgetTreeNode>[];
    for (final e in raw) {
      if (e is! Map) continue;
      out.add(
        VbuWidgetTreeNode(
          id: (e['id'] ?? '').toString(),
          label: (e['label'] ?? '').toString(),
          icon: e['icon'] is String ? _iconNames[e['icon'] as String] : null,
          children: _buildTreeNodes(e['children']),
        ),
      );
    }
    return out;
  }
}

class _VbuLayerCardFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuLayerCard(
      number: context.resolve<String?>(props['number']) ?? '',
      name: context.resolve<String?>(props['name']) ?? '',
      layerId: context.resolve<String?>(props['layerId']) ?? '',
      color: _color(context.resolve<Object?>(props['color'])) ?? Colors.grey,
      focused: context.resolve<bool?>(props['focused']) ?? false,
      patchCount: context.resolve<int?>(props['patchCount']),
      onTap: _callback(props['onTap'], context),
      width: (context.resolve<num?>(props['width']) ?? 168).toDouble(),
      height: (context.resolve<num?>(props['height']) ?? 80).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

class _VbuOverviewStripFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawLayers = context.resolve<Object?>(props['layers']);
    final layers = <VbuOverviewLayer>[];
    if (rawLayers is List) {
      for (final e in rawLayers) {
        if (e is! Map) continue;
        // patchCount may be a literal int OR a {{template}} that
        // resolves to an int / numeric string. Try all three so the
        // host can drive badges from runtime state without forking
        // the strip per build.
        int? patchCount;
        final rawPatch = e['patchCount'];
        if (rawPatch is int) {
          patchCount = rawPatch;
        } else if (rawPatch != null) {
          final resolved = context.resolve<Object?>(rawPatch);
          if (resolved is int) {
            patchCount = resolved;
          } else if (resolved is num) {
            patchCount = resolved.toInt();
          } else if (resolved is String) {
            patchCount = int.tryParse(resolved);
          }
        }
        layers.add(
          VbuOverviewLayer(
            id: (e['id'] ?? '').toString(),
            number: (e['number'] ?? '').toString(),
            name: (e['name'] ?? '').toString(),
            color: _color(e['color']) ?? Colors.grey,
            patchCount: patchCount,
          ),
        );
      }
    }
    final widget = VbuOverviewStrip(
      layers: layers,
      focused: context.resolve<String?>(props['focused']) ?? '',
      onFocus: _valueCallback<String>(props['onFocus'], context),
      height: (context.resolve<num?>(props['height']) ?? 96).toDouble(),
      cardGap: (context.resolve<num?>(props['cardGap']) ?? 12).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

class _VbuMiniPreviewFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final layer = context.resolve<String?>(props['layer']) ?? '';
    final w = (context.resolve<num?>(props['width']) ?? 140).toDouble();
    final h = (context.resolve<num?>(props['height']) ?? 48).toDouble();
    final colorStr = context.resolve<String?>(props['color']);
    final accent = _color(colorStr);
    final widget = VbuMiniPreview(
      layer: layer,
      size: Size(w, h),
      color: accent,
    );
    return applyCommonWrappers(widget, props, context);
  }
}

class _VbuPaneHeaderFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuPaneHeader(
      label: context.resolve<String?>(props['label']) ?? '',
      actions: _children(props['actions'], context),
      onClear: _asyncCallback(props['onClear'], context),
      clearTooltip: context.resolve<String?>(props['clearTooltip']) ?? 'Clear',
      height: (context.resolve<num?>(props['height']) ?? 36).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuPanelDialogScaffold
// ---------------------------------------------------------------------------

class _VbuPanelDialogScaffoldFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuPanelDialogScaffold(
      title: context.resolve<String?>(props['title']) ?? '',
      body: _child(props['body'], context) ?? const SizedBox.shrink(),
      actions: _children(props['actions'], context),
      titleTrailing: _child(props['titleTrailing'], context),
      headerExtra: _child(props['headerExtra'], context),
      quickActions: _children(props['quickActions'], context),
      actionsLeading: _child(props['actionsLeading'], context),
      width: (context.resolve<num?>(props['width']) ?? 460).toDouble(),
      height: (context.resolve<num?>(props['height']))?.toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuPanelSplitter
// ---------------------------------------------------------------------------

class _VbuPanelSplitterFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final axisStr =
        (context.resolve<String?>(props['axis']) ?? 'horizontal').toLowerCase();
    final widget = VbuPanelSplitter(
      onDrag: _valueCallback<double>(props['onDrag'], context) ?? (_) {},
      onDragEnd: _callback(props['onDragEnd'], context),
      axis: axisStr == 'vertical' ? Axis.vertical : Axis.horizontal,
      color: _color(context.resolve<Object?>(props['color'])),
      thickness: (context.resolve<num?>(props['thickness']) ?? 1).toDouble(),
      hitWidth: (context.resolve<num?>(props['hitWidth']) ?? 6).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuPill
// ---------------------------------------------------------------------------

class _VbuPillFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuPill(
      label: context.resolve<String?>(props['label']) ?? '',
      leading: _child(props['leading'], context),
      onTap: _callback(props['click'] ?? props['onTap'], context),
      background: _color(context.resolve<Object?>(props['background'])),
      foreground: _color(context.resolve<Object?>(props['foreground'])),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuProjectNameRow
// ---------------------------------------------------------------------------

class _VbuProjectNameRowFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuProjectNameRow(
      projectName: context.resolve<String?>(props['projectName']) ?? '',
      dirty: context.resolve<bool?>(props['dirty']) ?? false,
      hasProject: context.resolve<bool?>(props['hasProject']) ?? false,
      onRename: _callback(props['onRename'], context) ?? () {},
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuPromptBubble
// ---------------------------------------------------------------------------

class _VbuPromptBubbleFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuPromptBubble(
      text: context.resolve<String?>(props['text']) ?? '',
      onDelete: _callback(props['onDelete'], context),
      maxWidth: (context.resolve<num?>(props['maxWidth']) ?? 240).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuRecentMenuButton — recents is `List<{label, value}>`; onPick action
// receives the picked `value` as $event.
// ---------------------------------------------------------------------------

class _VbuRecentMenuButtonFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawRecents = context.resolve<Object?>(props['recents']);
    final recents = <String>[];
    if (rawRecents is List) {
      for (final r in rawRecents) {
        if (r is String) recents.add(r);
      }
    }
    final widget = VbuRecentMenuButton(
      recents: recents,
      onPick: _valueCallback<String>(props['onPick'], context) ?? (_) {},
      tooltip: context.resolve<String?>(props['tooltip']) ?? 'Recent',
      headerLabel: context.resolve<String?>(props['headerLabel']) ?? 'RECENT',
      minMenuWidth:
          (context.resolve<num?>(props['minMenuWidth']) ?? 280).toDouble(),
      maxMenuWidth:
          (context.resolve<num?>(props['maxMenuWidth']) ?? 480).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuSnapshotDiff — renders header + section views from a structured
// diff payload: `{leftLabel, rightLabel, sections: [{title, rows: [{id,
// status, leftValue, rightValue}]}]}`.
// ---------------------------------------------------------------------------

class _VbuSnapshotDiffFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final title = context.resolve<String?>(props['title']) ?? '';
    final leftLabel = context.resolve<String?>(props['leftLabel']) ?? 'Before';
    final rightLabel = context.resolve<String?>(props['rightLabel']) ?? 'After';
    final leftAccent = _color(context.resolve<Object?>(props['leftAccent']));
    final rightAccent = _color(context.resolve<Object?>(props['rightAccent']));
    final rawSections = context.resolve<Object?>(props['sections']);
    final sections = <VbuDiffSection>[];
    if (rawSections is List) {
      for (final s in rawSections) {
        if (s is Map<String, dynamic>) {
          final rawRows = s['rows'];
          final rows = <VbuDiffRow>[];
          if (rawRows is List) {
            for (final r in rawRows) {
              if (r is Map<String, dynamic>) {
                final statusStr =
                    (r['status'] as String? ?? 'same').toLowerCase();
                final status = switch (statusStr) {
                  'added' ||
                  'leftonly' ||
                  'left_only' => VbuDiffStatus.leftOnly,
                  'removed' ||
                  'rightonly' ||
                  'right_only' => VbuDiffStatus.rightOnly,
                  'changed' || 'modified' => VbuDiffStatus.modified,
                  _ => VbuDiffStatus.identical,
                };
                rows.add(
                  VbuDiffRow(
                    id: r['id']?.toString() ?? '',
                    status: status,
                    leftValue: r['leftValue']?.toString(),
                    rightValue: r['rightValue']?.toString(),
                  ),
                );
              }
            }
          }
          sections.add(
            VbuDiffSection(title: s['title']?.toString() ?? '', rows: rows),
          );
        }
      }
    }
    final widget = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        VbuDiffHeader(
          title: title,
          leftLabel: leftLabel,
          rightLabel: rightLabel,
          leftAccent: leftAccent,
          rightAccent: rightAccent,
        ),
        for (final s in sections) VbuDiffSectionView(section: s),
      ],
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuStatusbar
// ---------------------------------------------------------------------------

class _VbuStatusbarFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuStatusbar(
      left: _children(props['left'], context),
      right: _children(props['right'], context),
      height: (context.resolve<num?>(props['height']) ?? 22).toDouble(),
      gap: (context.resolve<num?>(props['gap']) ?? 16).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

class _VbuStatusDotFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuStatusDot(
      color: _color(context.resolve<Object?>(props['color'])) ?? Colors.grey,
      size: (context.resolve<num?>(props['size']) ?? 6).toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

class _VbuStatusBadgeFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuStatusBadge(
      color: _color(context.resolve<Object?>(props['color'])) ?? Colors.grey,
      label: context.resolve<String?>(props['label']) ?? '',
      onTap: _callback(props['onTap'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuSystemNote
// ---------------------------------------------------------------------------

class _VbuSystemNoteFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuSystemNote(
      text: context.resolve<String?>(props['text']) ?? '',
      error: context.resolve<bool?>(props['error']) ?? false,
      onDelete: _callback(props['onDelete'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuTabStrip — tabs is `List<{label, icon, closable}>`. onSelect /
// onClose actions receive tab index as $event.
// ---------------------------------------------------------------------------

class _VbuTabStripFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawTabs = context.resolve<Object?>(props['tabs']);
    final tabs = <VbuTab>[];
    if (rawTabs is List) {
      for (final t in rawTabs) {
        if (t is Map<String, dynamic>) {
          tabs.add(
            VbuTab(
              label: context.resolve<String?>(t['label']) ?? '',
              icon: _icon(context.resolve<Object?>(t['icon'])),
              closable: context.resolve<bool?>(t['closable']) ?? true,
            ),
          );
        }
      }
    }
    final widget = VbuTabStrip(
      tabs: tabs,
      activeIndex: (context.resolve<num?>(props['activeIndex']) ?? 0).toInt(),
      onSelect: _valueCallback<int>(props['onSelect'], context) ?? (_) {},
      onClose: _valueCallback<int>(props['onClose'], context),
      height: (context.resolve<num?>(props['height']) ?? 36).toDouble(),
      maxTabWidth:
          (context.resolve<num?>(props['maxTabWidth']) ?? 200).toDouble(),
      trailing: _children(props['trailing'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuTitleBar — chrome-style strip at the top of a bundle's page. Full
// width, title + optional subtitle on the left, optional leading widget,
// optional trailing widgets (icon buttons, badges). Canonical "title
// bar" — DSL authors use this instead of hand-rolling a box+linear+text
// header so every authored bundle shares the same chrome tone.
// ---------------------------------------------------------------------------

class _VbuTitleBarFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuTitleBar(
      title: context.resolve<String?>(props['title']) ?? '',
      subtitle: context.resolve<String?>(props['subtitle']),
      leading: _child(props['leading'], context),
      trailing: _children(props['trailing'], context),
      height:
          (context.resolve<num?>(props['height']) ?? VbuTokens.titlebarHeight)
              .toDouble(),
      background: _color(context.resolve<Object?>(props['background'])),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuToolsList
// ---------------------------------------------------------------------------

class _VbuToolsListFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawTools = context.resolve<Object?>(props['tools']);
    final items = <VbuToolItem>[];
    if (rawTools is List) {
      for (final t in rawTools) {
        if (t is! Map) continue;
        items.add(
          VbuToolItem(
            name: context.resolve<String?>(t['name']) ?? '(unnamed)',
            kind: context.resolve<String?>(t['kind']) ?? 'host',
            description: context.resolve<String?>(t['description']),
            subLabel: context.resolve<String?>(t['subLabel']),
            selected: context.resolve<bool?>(t['selected']) ?? false,
            onTap: _callback(t['onTap'], context),
          ),
        );
      }
    }
    final widget = VbuToolsList(tools: items);
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuPathTile — file/folder one-line.
// ---------------------------------------------------------------------------

class _VbuPathTileFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuPathTile(
      label: context.resolve<String?>(props['label']) ?? '',
      meta: context.resolve<String?>(props['meta']),
      leading: _child(props['leading'], context),
      trailing: _child(props['trailing'], context),
      selected: context.resolve<bool?>(props['selected']) ?? false,
      onTap: _callback(props['click'] ?? props['onTap'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuJsonEditor — monospace JSON text editor with live validation.
// ---------------------------------------------------------------------------

class _VbuJsonEditorFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuJsonEditor(
      initialText:
          context.resolve<String?>(props['initialText']) ??
          context.resolve<String?>(props['value']) ??
          '',
      readOnly: context.resolve<bool?>(props['readOnly']) ?? false,
      minLines: (context.resolve<num?>(props['minLines']) ?? 10).toInt(),
      maxLines: (context.resolve<num?>(props['maxLines']))?.toInt(),
      placeholder: context.resolve<String?>(props['placeholder']),
      onChanged: _valueCallback<String>(props['change'], context),
      onParsed: _valueCallback<Object?>(props['parsed'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuVideoPlayer — inline mp4 / webm player.
// ---------------------------------------------------------------------------

class _VbuVideoPlayerFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuVideoPlayer(
      src: context.resolve<String?>(props['src']) ?? '',
      autoplay: context.resolve<bool?>(props['autoplay']) ?? false,
      loop: context.resolve<bool?>(props['loop']) ?? false,
      showControls: context.resolve<bool?>(props['showControls']) ?? true,
      aspectRatio: (context.resolve<num?>(props['aspectRatio']))?.toDouble(),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// text override — per-variant vbu typography. Maps Material tokens such
// as titleLarge / bodyMedium to the vbu mono / sans tone.
// ---------------------------------------------------------------------------

class _TextOverrideFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    // spec 17_Naming §17.3.2: `text` is canonical, `content` / `value` are
    // legacy aliases. Match the runtime TextWidgetFactory's fallback chain
    // so DSL authors using the canonical `text` key get visible glyphs
    // (previously only `value` was read here, which silently broke any
    // template / hand-written DSL using `text`).
    final value =
        context.resolve<String?>(
          props['text'] ?? props['content'] ?? props['value'],
        ) ??
        '';
    final variantRaw =
        context.resolve<String?>(props['variant']) ?? 'bodyMedium';
    final c =
        context.themeManager.effectiveMode == 'dark'
            ? VbuTokens.color
            : VbuTokens.lightColor;
    var style = _variantToStyle(variantRaw, c);

    // Apply DSL `style` overrides on top of variant base — color, fontSize,
    // fontWeight, fontFamily, letterSpacing. Previously this factory ignored
    // every style field, so e.g. `style.color: "#9AA3B2"` (secondary tone)
    // got swallowed and every text rendered in the variant's hardcoded
    // textPrimary color.
    final styleProp = props['style'];
    if (styleProp is Map) {
      final overrideColor = context.resolve<String?>(styleProp['color']);
      if (overrideColor != null && overrideColor.isNotEmpty) {
        final parsed = _parseHexColor(overrideColor);
        if (parsed != null) style = style.copyWith(color: parsed);
      }
      final overrideSize = context.resolve<dynamic>(styleProp['fontSize']);
      if (overrideSize is num)
        style = style.copyWith(fontSize: overrideSize.toDouble());
      final overrideWeightRaw = context.resolve<String?>(
        styleProp['fontWeight'],
      );
      if (overrideWeightRaw != null) {
        final w = _parseFontWeight(overrideWeightRaw);
        if (w != null) style = style.copyWith(fontWeight: w);
      }
      final overrideFamily = context.resolve<String?>(styleProp['fontFamily']);
      if (overrideFamily != null && overrideFamily.isNotEmpty) {
        style = style.copyWith(fontFamily: overrideFamily);
      }
      final overrideLetter = context.resolve<dynamic>(
        styleProp['letterSpacing'],
      );
      if (overrideLetter is num)
        style = style.copyWith(letterSpacing: overrideLetter.toDouble());
    }

    final maxLines = (context.resolve<num?>(props['maxLines']))?.toInt();
    final widget = Text(
      value,
      style: style,
      maxLines: maxLines,
      overflow: maxLines != null ? TextOverflow.ellipsis : null,
    );
    return applyCommonWrappers(widget, props, context);
  }

  TextStyle _variantToStyle(String variant, dynamic c) {
    switch (variant) {
      case 'displayLarge':
        return vbuMono(size: 22, weight: FontWeight.w700, color: c.textPrimary);
      case 'displayMedium':
        return vbuMono(size: 20, weight: FontWeight.w700, color: c.textPrimary);
      case 'displaySmall':
      case 'headlineLarge':
        return vbuMono(size: 18, weight: FontWeight.w700, color: c.textPrimary);
      case 'headlineMedium':
      case 'headlineSmall':
      case 'titleLarge':
        return vbuMono(size: 16, weight: FontWeight.w600, color: c.textPrimary);
      case 'titleMedium':
        return vbuMono(size: 13, weight: FontWeight.w600, color: c.textPrimary);
      case 'titleSmall':
      case 'labelLarge':
        return vbuMono(size: 12, weight: FontWeight.w600, color: c.textPrimary);
      case 'labelMedium':
        return vbuMono(
          size: 11,
          weight: FontWeight.w500,
          color: c.textSecondary,
        );
      case 'labelSmall':
        return vbuMono(
          size: 10,
          weight: FontWeight.w500,
          color: c.textTertiary,
        );
      case 'bodyLarge':
        return vbuMono(size: 13, weight: FontWeight.w400, color: c.textPrimary);
      case 'bodyMedium':
        return vbuMono(size: 12, weight: FontWeight.w400, color: c.textPrimary);
      case 'bodySmall':
      default:
        return vbuMono(
          size: 11,
          weight: FontWeight.w400,
          color: c.textSecondary,
        );
    }
  }
}

/// Parse `#RRGGBB` / `#AARRGGBB` / `0xAARRGGBB` hex to Color. Returns null
/// for unparseable input so the caller falls back to the variant default.
Color? _parseHexColor(String s) {
  var t = s.trim();
  if (t.startsWith('#')) t = t.substring(1);
  if (t.startsWith('0x') || t.startsWith('0X')) t = t.substring(2);
  if (t.length == 6) t = 'FF$t';
  if (t.length != 8) return null;
  final v = int.tryParse(t, radix: 16);
  if (v == null) return null;
  return Color(v);
}

/// Parse `w100`..`w900` / `normal` / `bold` to [FontWeight].
FontWeight? _parseFontWeight(String s) {
  switch (s.trim().toLowerCase()) {
    case 'w100':
    case 'thin':
      return FontWeight.w100;
    case 'w200':
    case 'extralight':
      return FontWeight.w200;
    case 'w300':
    case 'light':
      return FontWeight.w300;
    case 'w400':
    case 'normal':
    case 'regular':
      return FontWeight.w400;
    case 'w500':
    case 'medium':
      return FontWeight.w500;
    case 'w600':
    case 'semibold':
      return FontWeight.w600;
    case 'w700':
    case 'bold':
      return FontWeight.w700;
    case 'w800':
    case 'extrabold':
      return FontWeight.w800;
    case 'w900':
    case 'black':
      return FontWeight.w900;
  }
  return null;
}

// ---------------------------------------------------------------------------
// button override — accepts click as Map (single action) OR List
// (multiple actions dispatched in order).
// ---------------------------------------------------------------------------

class _ButtonOverrideFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final label = context.resolve<String?>(props['label']) ?? '';
    final variantRaw = context.resolve<String?>(props['variant']) ?? 'text';
    final variant = variantRaw.toLowerCase();
    final onPressed = _callback(props['click'], context);
    final c =
        context.themeManager.effectiveMode == 'dark'
            ? VbuTokens.color
            : VbuTokens.lightColor;
    final labelStyle = vbuMono(
      size: 11,
      weight: FontWeight.w600,
      color: c.textPrimary,
    );
    final padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(4),
    );
    Widget btn;
    switch (variant) {
      case 'filled':
      case 'elevated':
        btn = ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: c.mint,
            foregroundColor: c.bg,
            padding: padding,
            shape: shape,
            textStyle: labelStyle,
            minimumSize: const Size(0, 28),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(label),
        );
        break;
      case 'outlined':
        btn = OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: c.textPrimary,
            side: BorderSide(color: c.borderDefault),
            padding: padding,
            shape: shape,
            textStyle: labelStyle,
            minimumSize: const Size(0, 28),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(label),
        );
        break;
      case 'text':
      default:
        btn = TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: c.textSecondary,
            padding: padding,
            shape: shape,
            textStyle: labelStyle,
            minimumSize: const Size(0, 28),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(label),
        );
    }
    return applyCommonWrappers(btn, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuTimeline — duration-proportional step strip + overlay tracks.
// ---------------------------------------------------------------------------

class _VbuTimelineFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawSteps = context.resolve<Object?>(props['steps']);
    final steps = <VbuTimelineStep>[];
    if (rawSteps is List) {
      for (final s in rawSteps) {
        if (s is! Map) continue;
        steps.add(
          VbuTimelineStep(
            label: context.resolve<String?>(s['label']) ?? '',
            durationMs: (context.resolve<num?>(s['durationMs']) ?? 0).toInt(),
            color: _color(context.resolve<Object?>(s['color'])),
            icon: s['icon'] == null ? null : _icon(s['icon']),
          ),
        );
      }
    }
    final rawTracks = context.resolve<Object?>(props['tracks']);
    final tracks = <VbuTimelineTrack>[];
    if (rawTracks is List) {
      for (final t in rawTracks) {
        if (t is! Map) continue;
        final rawRegions = t['regions'];
        final regions = <VbuTimelineRegion>[];
        if (rawRegions is List) {
          for (final r in rawRegions) {
            if (r is! Map) continue;
            regions.add(
              VbuTimelineRegion(
                atMs: (context.resolve<num?>(r['atMs']) ?? 0).toInt(),
                durationMs:
                    (context.resolve<num?>(r['durationMs']) ?? 0).toInt(),
                label: context.resolve<String?>(r['label']) ?? '',
                color: _color(context.resolve<Object?>(r['color'])),
              ),
            );
          }
        }
        tracks.add(
          VbuTimelineTrack(
            label: context.resolve<String?>(t['label']) ?? '',
            regions: regions,
          ),
        );
      }
    }
    final widget = VbuTimeline(
      steps: steps,
      tracks: tracks,
      selectedIndex: (context.resolve<num?>(props['selectedIndex']))?.toInt(),
      scrubMs: (context.resolve<num?>(props['scrubMs']))?.toInt(),
      pixelsPerSecond:
          (context.resolve<num?>(props['pixelsPerSecond']) ?? 80).toDouble(),
      stepHeight: (context.resolve<num?>(props['stepHeight']) ?? 36).toDouble(),
      trackHeight:
          (context.resolve<num?>(props['trackHeight']) ?? 22).toDouble(),
      onSelectStep: _valueCallback<int>(props['selectStep'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuChannelStrip — pill row representing build channels (app_builder
// action row [1] slot left half).
// ---------------------------------------------------------------------------

class _VbuChannelStripFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawChannels = context.resolve<Object?>(props['channels']);
    final channels = <String>[];
    if (rawChannels is List) {
      for (final c in rawChannels) {
        if (c is String) channels.add(c);
      }
    }
    final rawMenu = context.resolve<Object?>(props['menuItems']);
    final menuItems = <VbuChannelMenuItem>[];
    if (rawMenu is List) {
      for (final m in rawMenu) {
        if (m is! Map) continue;
        final id = m['id'];
        final label = m['label'];
        if (id is! String || label is! String) continue;
        menuItems.add(
          VbuChannelMenuItem(
            id: id,
            label: label,
            icon: m['icon'] == null ? null : _icon(m['icon']),
            danger: m['danger'] == true,
          ),
        );
      }
    }
    final widget = VbuChannelStrip(
      channels: channels,
      activeChannel: context.resolve<String?>(props['activeChannel']),
      onSelect: _valueCallback<String>(props['onSelect'], context),
      tone: _color(context.resolve<Object?>(props['tone'])),
      menuItems: menuItems,
      onMenuSelect: _valueCallback<String>(props['onMenuSelect'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuInstanceStrip — horizontal scrollable card row for layer-list
// surfaces (app_builder [3] slot).
// ---------------------------------------------------------------------------

class _VbuInstanceStripFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawItems = context.resolve<Object?>(props['items']);
    final items = <VbuInstanceItem>[];
    if (rawItems is List) {
      for (final m in rawItems) {
        if (m is! Map) continue;
        final id = m['id'];
        final label = m['label'];
        if (id is! String || label is! String) continue;
        // Optional menu items: parse `menuItems: [{label, danger?,
        // onTap?}]`. `onTap` becomes a VoidCallback wired through the
        // DSL action dispatcher.
        final menuItems = <VbuInstanceMenuItem>[];
        final rawMenu = m['menuItems'];
        if (rawMenu is List) {
          for (final mi in rawMenu) {
            if (mi is! Map) continue;
            final lbl = mi['label'];
            if (lbl is! String) continue;
            menuItems.add(
              VbuInstanceMenuItem(
                label: lbl,
                onTap: _callback(mi['onTap'], context),
                danger: mi['danger'] == true,
              ),
            );
          }
        }
        items.add(
          VbuInstanceItem(
            id: id,
            label: label,
            color: m['color'] is String ? m['color'] as String : null,
            subtitle: m['subtitle'] is String ? m['subtitle'] as String : null,
            issue: m['issue'] is String ? m['issue'] as String : null,
            menuItems: menuItems,
          ),
        );
      }
    }
    final orientation = switch (context.resolve<String?>(
      props['orientation'],
    )) {
      'vertical' => VbuInstanceStripOrientation.vertical,
      _ => VbuInstanceStripOrientation.horizontal,
    };
    final widget = VbuInstanceStrip(
      items: items,
      selectedId: context.resolve<String?>(props['selectedId']),
      onSelect: _valueCallback<String>(props['onSelect'], context),
      orientation: orientation,
      sectionTitle: context.resolve<String?>(props['sectionTitle']),
      sectionDotColor: context.resolve<String?>(props['sectionDotColor']),
      addLabel: context.resolve<String?>(props['addLabel']),
      onAdd: _callback(props['onAdd'], context),
      emptyText:
          context.resolve<String?>(props['emptyText']) ?? 'No instances yet',
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuPreviewMcpUi — domain-side preview placeholder. The real factory
// mounts a fresh MCPUIRuntime against the target bundle (lands in a
// follow-up phase once chrome-bridge access is wired).
// ---------------------------------------------------------------------------

class _VbuPreviewMcpUiPlaceholderFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final widget = VbuPreviewMcpUi(
      bundleId: context.resolve<String?>(props['bundleId']),
      uiPath: context.resolve<String?>(props['uiPath']) ?? 'ui/app.json',
      deviceSize: context.resolve<String?>(props['deviceSize']),
      orientation: context.resolve<String?>(props['orientation']) ?? 'portrait',
      brightness: context.resolve<String?>(props['brightness']) ?? 'auto',
      showInspector: context.resolve<bool?>(props['showInspector']) ?? false,
      onSizeChange: _valueCallback<String>(props['onSizeChange'], context),
      onOrientChange: _valueCallback<String>(props['onOrientChange'], context),
      onBrightnessChange: _valueCallback<String>(
        props['onBrightnessChange'],
        context,
      ),
      onRefresh: _callback(props['onRefresh'], context),
      child: _child(props['child'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuPropertiesForm — vertical scrollable form (app_builder [5] slot).
// Sections + fields; placeholder body renders read-only rows.
// ---------------------------------------------------------------------------

class _VbuPropertiesFormFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawSections = context.resolve<Object?>(props['sections']);
    final sections = <VbuPropertiesSection>[];
    if (rawSections is List) {
      for (final s in rawSections) {
        if (s is! Map) continue;
        final title = s['title'];
        if (title is! String) continue;
        final fields = <VbuPropertiesField>[];
        final rawFields = s['fields'];
        if (rawFields is List) {
          for (final f in rawFields) {
            if (f is! Map) continue;
            final label = f['label'];
            if (label is! String) continue;
            final enumValues = <String>[];
            final rawEnum = f['enumValues'];
            if (rawEnum is List) {
              for (final v in rawEnum) {
                if (v is String) enumValues.add(v);
              }
            }
            fields.add(
              VbuPropertiesField(
                label: label,
                kind: f['kind'] is String ? f['kind'] as String : 'text',
                value: f['value'] is String ? f['value'] as String : null,
                hint: f['hint'] is String ? f['hint'] as String : null,
                enumValues: enumValues,
                onChange: _valueCallback<String>(f['onChange'], context),
              ),
            );
          }
        }
        sections.add(VbuPropertiesSection(title: title, fields: fields));
      }
    }
    final widget = VbuPropertiesForm(
      sections: sections,
      contextLabel: context.resolve<String?>(props['contextLabel']),
      contextStripeColor: context.resolve<String?>(props['contextStripeColor']),
      emptyText:
          context.resolve<String?>(props['emptyText']) ?? 'No focused layer',
    );
    return applyCommonWrappers(widget, props, context);
  }
}

// ---------------------------------------------------------------------------
// VbuInspectorPanel — debug-mode inspector with variant strip + toolbar +
// render/log split. Render and log slots are caller-supplied so the atom
// stays free of mcp_ui_runtime dependencies.
// ---------------------------------------------------------------------------

class _VbuInspectorPanelFactory extends WidgetFactory {
  @override
  Widget build(Map<String, dynamic> definition, RenderContext context) {
    final props = extractProperties(definition);
    final rawVariants = context.resolve<Object?>(props['variants']);
    final variants = <VbuInspectorVariant>[];
    if (rawVariants is List) {
      for (final m in rawVariants) {
        if (m is! Map) continue;
        final id = m['id'];
        final label = m['label'];
        if (id is! String || label is! String) continue;
        // Parse status keyword → enum. Unknown = notBuilt.
        final rawStatus = m['status'];
        VbuInspectorVariantStatus status = VbuInspectorVariantStatus.notBuilt;
        if (rawStatus is String) {
          switch (rawStatus) {
            case 'idle':
              status = VbuInspectorVariantStatus.idle;
              break;
            case 'spawning':
              status = VbuInspectorVariantStatus.spawning;
              break;
            case 'running':
              status = VbuInspectorVariantStatus.running;
              break;
            case 'error':
              status = VbuInspectorVariantStatus.error;
              break;
            case 'notBuilt':
            default:
              status = VbuInspectorVariantStatus.notBuilt;
          }
        }
        variants.add(
          VbuInspectorVariant(
            id: id,
            label: label,
            icon: _icon(m['icon']),
            transport:
                m['transport'] is String ? m['transport'] as String : null,
            status: status,
          ),
        );
      }
    }
    final widget = VbuInspectorPanel(
      variants: variants,
      activeVariantId: context.resolve<String?>(props['activeVariantId']),
      onVariantChange: _valueCallback<String>(
        props['onVariantChange'],
        context,
      ),
      deviceSize: context.resolve<String?>(props['deviceSize']),
      orientation: context.resolve<String?>(props['orientation']) ?? 'portrait',
      brightness: context.resolve<String?>(props['brightness']) ?? 'auto',
      onSizeChange: _valueCallback<String>(props['onSizeChange'], context),
      onOrientChange: _valueCallback<String>(props['onOrientChange'], context),
      onBrightnessChange: _valueCallback<String>(
        props['onBrightnessChange'],
        context,
      ),
      renderChild: _child(props['renderChild'], context),
      logChild: _child(props['logChild'], context),
    );
    return applyCommonWrappers(widget, props, context);
  }
}
