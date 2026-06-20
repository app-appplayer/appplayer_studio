import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:appplayer_studio/ui.dart';

import '../chat/model_option.dart';
import '../shell/app_theme.dart';
import '../shell/inspect_tag.dart';
import '../shell/tokens.dart';
import 'vibe_settings.dart';

/// One section rendered inside [showVibeSettingsDialog]. Used by both
/// `extraSections` (Studio tab — host-level extras) and
/// [DomainSettingsPanel.sections] (Domain tab — content of the active
/// bundle). Sections appear in declaration order beneath the section
/// label (mono caps).
///
/// The slot is intentionally [Widget]-shaped (not a typed config) so
/// each contributor renders whatever controls fit (toggles, dropdowns,
/// free-form forms). The contributor writes the user's choices back to
/// its own store inside the widget; base does not persist contributed
/// settings.
class SettingsSection {
  const SettingsSection({required this.label, required this.body});

  /// Section header shown in mono caps above the body. Keep short
  /// (one or two words; matches base sections' style).
  final String label;

  /// Section content. Contributors typically use the standard helpers
  /// from vibe_studio_base (`_LabelledField` etc.) or build their own.
  /// The caller is responsible for state + persistence — base never
  /// reads from this widget.
  final Widget body;
}

/// Domain-side settings panel passed to [showVibeSettingsDialog]. When
/// non-null the dialog renders as two tabs (Domain first, Studio
/// second); when null the dialog collapses to a single Studio pane.
///
/// `name` is the active bundle / domain identifier shown in the Domain
/// tab label and dialog title (e.g. `app_builder`, `knowledge`).
/// `sections` are the bundle-contributed settings rows.
class DomainSettingsPanel {
  const DomainSettingsPanel({
    required this.name,
    this.sections = const <SettingsSection>[],
  });

  final String name;
  final List<SettingsSection> sections;
}

/// Modal dialog for tool-level settings (MCP server config, LLM API key, ...).
/// Returns the updated [VibeSettings] on Save, `null` on Cancel.
///
/// Knowledge management is opt-in via three callbacks. Pass any
/// non-null trio (or just install) to surface the Knowledge section;
/// the list / uninstall pair are also rendered when wired so the user
/// can manage existing bundles inline.
///
/// `extraSections` extends the Studio tab beneath the built-in
/// sections. `domain` is the Domain-tab payload — pass null when no
/// bundle is active so the dialog collapses to a single Studio pane.
Future<VibeSettings?> showVibeSettingsDialog(
  BuildContext context,
  VibeSettings current, {
  required List<VibeModelOption> modelOptions,
  required String settingsPath,
  Future<Map<String, dynamic>> Function(String mbdPath)? installKnowledgeBundle,
  Future<List<Map<String, dynamic>>> Function()? listKnowledgeBundles,
  Future<Map<String, dynamic>> Function(String mbdPath)?
  uninstallKnowledgeBundle,
  List<SettingsSection> extraSections = const <SettingsSection>[],
  DomainSettingsPanel? domain,
}) {
  return showDialog<VibeSettings?>(
    context: context,
    builder:
        (ctx) => _SettingsDialog(
          initial: current,
          modelOptions: modelOptions,
          settingsPath: settingsPath,
          installKnowledgeBundle: installKnowledgeBundle,
          listKnowledgeBundles: listKnowledgeBundles,
          uninstallKnowledgeBundle: uninstallKnowledgeBundle,
          extraSections: extraSections,
          domain: domain,
        ),
  );
}

enum _SettingsTab { domain, studio }

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({
    required this.initial,
    required this.modelOptions,
    required this.settingsPath,
    this.installKnowledgeBundle,
    this.listKnowledgeBundles,
    this.uninstallKnowledgeBundle,
    this.extraSections = const <SettingsSection>[],
    this.domain,
  });
  final VibeSettings initial;
  final List<VibeModelOption> modelOptions;
  final String settingsPath;
  final Future<Map<String, dynamic>> Function(String mbdPath)?
  installKnowledgeBundle;
  final Future<List<Map<String, dynamic>>> Function()? listKnowledgeBundles;
  final Future<Map<String, dynamic>> Function(String mbdPath)?
  uninstallKnowledgeBundle;
  final List<SettingsSection> extraSections;
  final DomainSettingsPanel? domain;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  String? _workspaceDir;
  late final TextEditingController _mcpUrl;
  late String _mcpTransport;
  late final TextEditingController _llmKey;
  late String _llmModel;
  late final TextEditingController _llmEndpoint;
  late int _autosaveDelaySec;
  late Map<String, TextEditingController> _llmKeysByProvider;
  late String _themeMode;
  late bool _debugMode;
  bool _showKey = false;
  late _SettingsTab _tab;
  // Inner tab inside the API providers section — picks one of the 3
  // API providers (Claude / OpenAI / Gemini). Claude Code lives in a
  // sibling section that is always visible; both sets of credentials
  // wire at boot independently.
  int _llmApiInnerTab = 0; // 0 = Claude, 1 = OpenAI, 2 = Gemini

  @override
  void initState() {
    super.initState();
    _workspaceDir = widget.initial.workspaceDir;
    _mcpUrl = TextEditingController(text: widget.initial.mcpServerUrl ?? '');
    _mcpTransport = widget.initial.mcpTransport;
    _llmKey = TextEditingController(text: widget.initial.llmApiKey ?? '');
    // Resolve to a known catalog id; unknown saved values fall back to
    // the catalog default so the dropdown always shows a real choice.
    final saved = widget.initial.llmModel;
    _llmModel =
        widget.modelOptions.any((m) => m.id == saved)
            ? saved!
            : widget.modelOptions.first.id;
    _llmEndpoint = TextEditingController(
      text: widget.initial.llmEndpoint ?? '',
    );
    _autosaveDelaySec = widget.initial.autosaveDelaySec;
    _themeMode = widget.initial.themeMode;
    _debugMode = widget.initial.debugMode;
    // One controller per distinct provider that appears in the model
    // catalog. Pre-fill from settings.llmProviders; legacy `llmApiKey`
    // is offered to whichever provider has no entry yet (best-effort
    // migration so users don't lose their key on schema upgrade).
    _llmKeysByProvider = <String, TextEditingController>{};
    final providers = <String>{
      for (final m in widget.modelOptions)
        if (m.provider != null) m.provider!,
    };
    for (final pid in providers) {
      final saved = widget.initial.llmProviders[pid];
      _llmKeysByProvider[pid] = TextEditingController(
        text:
            saved ??
            ((widget.initial.llmApiKey != null && providers.length == 1)
                ? widget.initial.llmApiKey!
                : ''),
      );
    }
    // Domain tab is the default when a bundle is active — matches the
    // user's typical "tweak the thing I'm working on" intent. Falls
    // back to Studio when no domain is supplied.
    _tab = widget.domain != null ? _SettingsTab.domain : _SettingsTab.studio;
  }

  @override
  void dispose() {
    _mcpUrl.dispose();
    _llmKey.dispose();
    _llmEndpoint.dispose();
    for (final c in _llmKeysByProvider.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickWorkspaceDir() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Default workspace directory (where new .mbd projects live)',
      initialDirectory: _workspaceDir,
    );
    if (picked == null) return;
    setState(() => _workspaceDir = picked);
  }

  void _save() {
    final providersMap = <String, String>{};
    for (final entry in _llmKeysByProvider.entries) {
      final v = entry.value.text.trim();
      if (v.isNotEmpty) providersMap[entry.key] = v;
    }
    // Mirror the active model's provider key into legacy `llmApiKey`
    // so older shells that haven't migrated still receive a key.
    final active = widget.modelOptions.firstWhere(
      (m) => m.id == _llmModel,
      orElse: () => widget.modelOptions.first,
    );
    final legacyKey =
        providersMap[active.provider] ??
        (_llmKey.text.trim().isEmpty ? null : _llmKey.text.trim());
    Navigator.of(context).pop(
      VibeSettings(
        workspaceDir:
            _workspaceDir == null || _workspaceDir!.isEmpty
                ? null
                : _workspaceDir,
        mcpServerUrl: _mcpUrl.text.trim().isEmpty ? null : _mcpUrl.text.trim(),
        mcpTransport: _mcpTransport,
        llmApiKey: legacyKey,
        llmModel: _llmModel,
        llmEndpoint:
            _llmEndpoint.text.trim().isEmpty ? null : _llmEndpoint.text.trim(),
        llmProviders: providersMap,
        autosaveDelaySec: _autosaveDelaySec,
        themeMode: _themeMode,
        debugMode: _debugMode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final hasDomain = widget.domain != null;
    final activeTab = hasDomain ? _tab : _SettingsTab.studio;
    final title =
        activeTab == _SettingsTab.domain
            ? '${widget.domain!.name} Settings'
            : 'Studio Settings';
    return Dialog(
      backgroundColor: c.surface2,
      child: SizedBox(
        width: hasDomain ? 720 : 460,
        height: 560,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (hasDomain)
              _SettingsSidebar(
                domainName: widget.domain!.name,
                active: activeTab,
                onPick: (t) => setState(() => _tab = t),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(VibeTokens.space4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        fontFamily: VibeTokens.fontSans,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    const SizedBox(height: VibeTokens.space2),
                    if (activeTab == _SettingsTab.studio)
                      Text(
                        'Saved at ${widget.settingsPath}',
                        style: vibeMono(size: 10, color: c.textTertiary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    const SizedBox(height: VibeTokens.space4),
                    Expanded(
                      child: SingleChildScrollView(
                        child:
                            activeTab == _SettingsTab.studio
                                ? _buildStudioBody(context)
                                : _buildDomainBody(context),
                      ),
                    ),
                    const SizedBox(height: VibeTokens.space3),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        inspectTag(
                          type: 'dialog_action',
                          id: 'settings.cancel',
                          label: 'Cancel',
                          child: TextButton(
                            onPressed: () => Navigator.of(context).pop(null),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        inspectTag(
                          type: 'dialog_action',
                          id: 'settings.save',
                          label: 'Save',
                          child: FilledButton(
                            onPressed: _save,
                            child: const Text('Save'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStudioBody(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        VbuFormSection(
          label: 'Appearance',
          children: <Widget>[
            VbuLabelledMenu<String>(
              label: 'Theme mode',
              value: _themeMode,
              options: const <String>['system', 'light', 'dark'],
              labels: const <String, String>{
                'system': 'System (follow OS)',
                'light': 'Light',
                'dark': 'Dark',
              },
              onChanged: (v) => setState(() => _themeMode = v),
            ),
          ],
        ),
        const SizedBox(height: VibeTokens.space3),
        VbuFormSection(
          label: 'Debug mode',
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Tag every rendered widget for inspect. '
                    'Required for `studio.renderer.layout_snapshot` '
                    '+ `studio.ui.tap({elementId:...})` automation '
                    '(scripted UI tests, recording tutorials). '
                    'Doubles widget RenderObject count — leave off '
                    'for fast production sessions.',
                    style: TextStyle(
                      fontFamily: VibeTokens.fontSans,
                      fontSize: 11,
                      color: VibeTokens.colorOf(context).textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: VibeTokens.space2),
                Switch(
                  value: _debugMode,
                  onChanged: (v) => setState(() => _debugMode = v),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: VibeTokens.space3),
        VbuFormSection(
          label: 'Workspace',
          children: <Widget>[
            VbuLabelledFolder(
              label: 'Default location',
              value: _workspaceDir,
              hint: '~/AppPlayerBuilder',
              onPick: _pickWorkspaceDir,
              onClear:
                  _workspaceDir == null
                      ? null
                      : () => setState(() => _workspaceDir = null),
            ),
          ],
        ),
        const SizedBox(height: VibeTokens.space3),
        VbuFormSection(
          label: 'MCP server',
          children: <Widget>[
            VbuLabelledField(
              label: 'URL',
              controller: _mcpUrl,
              hint: 'http://localhost:7830 — restart required',
            ),
            VbuLabelledMenu<String>(
              label: 'Transport',
              value: _mcpTransport,
              options: const <String>['http', 'sse'],
              labels: const <String, String>{
                'http': 'Streamable HTTP',
                'sse': 'SSE (legacy)',
              },
              onChanged: (v) => setState(() => _mcpTransport = v),
            ),
          ],
        ),
        const SizedBox(height: VibeTokens.space3),
        VbuFormSection(
          label: 'Autosave',
          children: <Widget>[
            VbuLabelledMenu<int>(
              label: 'Idle delay',
              value: _autosaveDelaySec,
              options: const <int>[0, 5, 10, 30],
              labels: const <int, String>{
                0: 'Off (manual ⌘S only)',
                5: '5 seconds',
                10: '10 seconds',
                30: '30 seconds',
              },
              onChanged: (v) => setState(() => _autosaveDelaySec = v),
            ),
          ],
        ),
        const SizedBox(height: VibeTokens.space3),
        // LLM — credentials only (no model selector). Two sibling
        // sections always visible: the 3 API providers (inner tab —
        // Claude / OpenAI / Gemini) and Claude Code (subscription via
        // CLI). Both sets of credentials wire at boot independently —
        // a user can leave either side blank. Model selection lives
        // elsewhere (chat panel chip for ad-hoc switching, agent
        // profile for per-agent defaults).
        VbuFormSection(
          label: 'API providers',
          children: <Widget>[_buildLlmApiBody(c)],
        ),
        const SizedBox(height: VibeTokens.space3),
        VbuFormSection(
          label: 'Claude Code (subscription)',
          children: <Widget>[_buildLlmClaudeCodeBody(c)],
        ),
        if (widget.installKnowledgeBundle != null) ...<Widget>[
          const SizedBox(height: VibeTokens.space3),
          VbuFormSection(
            label: 'Knowledge',
            children: <Widget>[
              if (widget.listKnowledgeBundles != null &&
                  widget.uninstallKnowledgeBundle != null)
                _InstalledBundlesList(
                  list: widget.listKnowledgeBundles!,
                  uninstall: widget.uninstallKnowledgeBundle!,
                ),
              _LabelledKnowledgeInstall(
                install: widget.installKnowledgeBundle!,
                onAfterInstall:
                    widget.listKnowledgeBundles == null
                        ? null
                        : () {
                          _bundlesRefreshNotifier.value++;
                        },
              ),
            ],
          ),
        ],
        // Studio-tab extras supplied by the host (rare).
        for (final s in widget.extraSections) ...<Widget>[
          const SizedBox(height: VibeTokens.space3),
          VbuFormSection(label: s.label, children: <Widget>[s.body]),
        ],
      ],
    );
  }

  static const List<({String id, String label})> _apiProviders =
      <({String id, String label})>[
        (id: 'anthropic', label: 'Claude'),
        (id: 'openai', label: 'OpenAI'),
        (id: 'gemini', label: 'Gemini'),
      ];

  Widget _buildLlmApiBody(VbuPalette c) {
    final idx = _llmApiInnerTab.clamp(0, _apiProviders.length - 1);
    final active = _apiProviders[idx];
    final controller = _llmKeysByProvider[active.id];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        VbuTabStrip(
          tabs: <VbuTab>[
            for (final p in _apiProviders)
              VbuTab(
                label: p.label,
                icon: Icons.bolt_outlined,
                closable: false,
              ),
          ],
          activeIndex: idx,
          onSelect: (i) => setState(() => _llmApiInnerTab = i),
          showActiveTopAccent: false,
        ),
        const SizedBox(height: VibeTokens.space2),
        if (controller != null)
          VbuLabelledField(
            label: 'API key',
            controller: controller,
            hint: _hintFor(active.id),
            obscure: !_showKey,
            trailing: IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(
                _showKey ? Icons.visibility_off : Icons.visibility,
                size: 14,
                color: c.textSecondary,
              ),
              onPressed: () => setState(() => _showKey = !_showKey),
              tooltip: _showKey ? 'Hide' : 'Show',
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: VibeTokens.space1),
          child: Text(
            'Models: ' +
                <String>[
                  for (final m in widget.modelOptions)
                    if (m.provider == active.id) m.label,
                ].join(' · '),
            style: vibeMono(size: 10, color: c.textTertiary),
          ),
        ),
      ],
    );
  }

  Widget _buildLlmClaudeCodeBody(VbuPalette c) {
    final controller = _llmKeysByProvider['claude_code'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: VibeTokens.space2),
          child: Text(
            'Uses your existing Claude subscription via the CLI — no API '
            'key. Sign in once with `claude login`.',
            style: vibeMono(size: 11, color: c.textTertiary),
          ),
        ),
        if (controller != null)
          VbuLabelledField(
            label: 'CLI path',
            controller: controller,
            hint: _hintFor('claude_code'),
          ),
        Padding(
          padding: const EdgeInsets.only(top: VibeTokens.space1),
          child: Text(
            'Models: ' +
                <String>[
                  for (final m in widget.modelOptions)
                    if (m.provider == 'claude_code') m.label,
                ].join(' · '),
            style: vibeMono(size: 10, color: c.textTertiary),
          ),
        ),
      ],
    );
  }

  String _hintFor(String providerId) {
    switch (providerId) {
      case 'anthropic':
        return 'sk-ant-…';
      case 'openai':
        return 'sk-…';
      case 'gemini':
        return 'AIza…';
      case 'claude_code':
        // Subscription path — no API key required. The field doubles
        // as an optional executable override; leave blank to use the
        // `claude` binary on PATH.
        return 'Path to `claude` (blank = PATH lookup)';
      default:
        return 'API key';
    }
  }

  Widget _buildDomainBody(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final domain = widget.domain!;
    if (domain.sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: VibeTokens.space4),
        child: Text(
          '${domain.name} exposes no settings.',
          style: vibeMono(size: 12, color: c.textTertiary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < domain.sections.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: VibeTokens.space3),
          VbuFormSection(
            label: domain.sections[i].label,
            children: <Widget>[domain.sections[i].body],
          ),
        ],
      ],
    );
  }
}

class _SettingsSidebar extends StatelessWidget {
  const _SettingsSidebar({
    required this.domainName,
    required this.active,
    required this.onPick,
  });

  final String domainName;
  final _SettingsTab active;
  final ValueChanged<_SettingsTab> onPick;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      width: 168,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.borderDefault)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: VibeTokens.space2,
        vertical: VibeTokens.space3,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SidebarItem(
            label: 'Domain',
            sublabel: domainName,
            icon: Icons.extension_outlined,
            selected: active == _SettingsTab.domain,
            onTap: () => onPick(_SettingsTab.domain),
          ),
          const SizedBox(height: 2),
          _SidebarItem(
            label: 'Studio',
            sublabel: 'AppPlayer Studio',
            icon: Icons.tune,
            selected: active == _SettingsTab.studio,
            onTap: () => onPick(_SettingsTab.studio),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.label,
    required this.sublabel,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String sublabel;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final bg =
        widget.selected
            ? c.surface3
            : (_hovered ? c.surface2 : Colors.transparent);
    final iconColor = widget.selected ? c.mint : c.textSecondary;
    final labelColor = widget.selected ? c.textPrimary : c.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: VibeTokens.durFast,
          curve: VibeTokens.easeStandard,
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space2,
            vertical: VibeTokens.space2,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Icon(widget.icon, size: 16, color: iconColor),
              const SizedBox(width: VibeTokens.space2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontFamily: VibeTokens.fontSans,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                    Text(
                      widget.sublabel,
                      style: vibeMono(size: 10, color: c.textTertiary),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared bump-counter for the installed-bundles list — incremented
/// after each successful install so the list widget re-fetches without
/// having to listen to the install widget directly.
final ValueNotifier<int> _bundlesRefreshNotifier = ValueNotifier<int>(0);

/// Read-only list of installed knowledge bundles with × per row to
/// uninstall. Polls on first build and on every bump of the refresh
/// notifier.
class _InstalledBundlesList extends StatefulWidget {
  const _InstalledBundlesList({required this.list, required this.uninstall});
  final Future<List<Map<String, dynamic>>> Function() list;
  final Future<Map<String, dynamic>> Function(String mbdPath) uninstall;

  @override
  State<_InstalledBundlesList> createState() => _InstalledBundlesListState();
}

class _InstalledBundlesListState extends State<_InstalledBundlesList> {
  List<Map<String, dynamic>>? _entries;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _bundlesRefreshNotifier.addListener(_refresh);
  }

  @override
  void dispose() {
    _bundlesRefreshNotifier.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final entries = await widget.list();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _busy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _entries = const <Map<String, dynamic>>[];
        _busy = false;
      });
    }
  }

  Future<void> _remove(String mbdPath) async {
    setState(() => _busy = true);
    try {
      await widget.uninstall(mbdPath);
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final entries = _entries;
    if (entries == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: VibeTokens.space1),
        child: Text(
          'Loading installed bundles…',
          style: vibeMono(size: 11, color: c.textTertiary),
        ),
      );
    }
    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: VibeTokens.space1),
        child: Text(
          'No knowledge bundles installed yet.',
          style: vibeMono(size: 11, color: c.textTertiary),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final e in entries) _row(context, e),
        const SizedBox(height: VibeTokens.space2),
      ],
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> e) {
    final c = VibeTokens.colorOf(context);
    final ns = e['namespace'] as String? ?? '?';
    final pathStr = e['mbdPath'] as String? ?? '';
    final installed = e['installedAt'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(
              ns,
              overflow: TextOverflow.ellipsis,
              style: vibeMono(size: 11, color: c.mint),
            ),
          ),
          Expanded(
            child: Tooltip(
              message: '$pathStr\ninstalledAt: $installed',
              child: Text(
                pathStr,
                overflow: TextOverflow.ellipsis,
                style: vibeMono(size: 11, color: c.textSecondary),
              ),
            ),
          ),
          const SizedBox(width: VibeTokens.space2),
          Tooltip(
            message: 'Remove from registry',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _busy ? null : () => _remove(pathStr),
              child: Padding(
                padding: const EdgeInsets.all(VibeTokens.space1),
                child: Icon(Icons.close, size: 13, color: c.textTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pick a `.mcpb` package (zip) and ship it through the install
/// callback. Install handler unzips the package into vibe's internal
/// knowledge cache and registers the resulting bundle for query. Shows
/// a transient one-line status under the picker so the caller doesn't
/// need a SnackBar — the result lives in the dialog while the user
/// verifies.
class _LabelledKnowledgeInstall extends StatefulWidget {
  const _LabelledKnowledgeInstall({required this.install, this.onAfterInstall});
  final Future<Map<String, dynamic>> Function(String mcpbPath) install;
  final VoidCallback? onAfterInstall;

  @override
  State<_LabelledKnowledgeInstall> createState() =>
      _LabelledKnowledgeInstallState();
}

class _LabelledKnowledgeInstallState extends State<_LabelledKnowledgeInstall> {
  String? _picked;
  bool _busy = false;
  String? _status; // last result, prefixed with ✓ or ✗
  bool _statusOk = false;

  Future<void> _pickFile() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select .mcpb package',
      type: FileType.custom,
      allowedExtensions: const <String>['mcpb'],
    );
    final path = picked?.files.singleOrNull?.path;
    if (path == null) return;
    setState(() {
      _picked = path;
      _status = null;
    });
  }

  Future<void> _pickDir() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select .mbd directory',
    );
    if (path == null) return;
    setState(() {
      _picked = path;
      _status = null;
    });
  }

  Future<void> _install() async {
    final path = _picked;
    if (path == null || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.install(path);
      final ok = result['ok'] == true;
      setState(() {
        _statusOk = ok;
        _status =
            ok
                ? 'installed · namespace=${result['namespace']}'
                : 'failed · ${result['error'] ?? 'unknown'}';
      });
      if (ok) widget.onAfterInstall?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final hint =
        _picked == null ? 'Pick a .mcpb package or .mbd directory…' : _picked!;
    final canInstall = _picked != null && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 92,
              child: Text(
                'MCPB path',
                style: vibeMono(size: 11, color: c.textSecondary),
              ),
            ),
            Expanded(
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
                  border: Border.all(color: c.borderDefault),
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    hint,
                    style: vibeMono(
                      size: 12,
                      color: _picked == null ? c.textTertiary : c.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
            const SizedBox(width: VibeTokens.space2),
            Tooltip(
              message: 'Choose .mcpb file',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _pickFile,
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
                    border: Border.all(color: c.borderDefault),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.attach_file_outlined,
                      size: 14,
                      color: c.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Tooltip(
              message: 'Choose .mbd directory',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _pickDir,
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: c.surface2,
                    borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
                    border: Border.all(color: c.borderDefault),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.folder_open_outlined,
                      size: 14,
                      color: c.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: VibeTokens.space2),
            Tooltip(
              message: 'Install into KnowledgeSystem',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: canInstall ? _install : null,
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color:
                        canInstall
                            ? c.mint.withValues(alpha: 0.18)
                            : c.surface2,
                    borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
                    border: Border.all(color: c.borderDefault),
                  ),
                  child: Center(
                    child: Text(
                      _busy ? 'Installing…' : 'Install',
                      style: vibeMono(
                        size: 12,
                        color: canInstall ? c.mint : c.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_status != null) ...<Widget>[
          const SizedBox(height: VibeTokens.space1),
          Padding(
            padding: const EdgeInsets.only(left: 92 + 8.0),
            child: Text(
              '${_statusOk ? "✓" : "✗"} $_status',
              style: vibeMono(
                size: 11,
                color: _statusOk ? c.mint : VibeTokens.status.error,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// One selectable project kind for [promptForNewProject]. Built-ins
/// contribute these via `BuiltInAppContext.projectKindsProvider` (or, in
/// future, a bundle manifest) so the host's standard new-project dialog
/// renders the kind selector without the domain forking the dialog — the
/// bundle/domain owns the *list*, the platform owns the *dialog*.
class ProjectKindOption {
  const ProjectKindOption({
    required this.id,
    required this.label,
    this.description = '',
  });

  /// Stable kind id passed back in [NewProjectInput.kind] and forwarded to
  /// the active built-in's scaffolder (e.g. `'appPlayerApp'`).
  final String id;

  /// Short label shown on the selector card.
  final String label;

  /// One-line description under the label.
  final String description;
}

/// Result of [promptForNewProject].
class NewProjectInput {
  const NewProjectInput({required this.name, required this.parent, this.kind});
  final String name;
  final String parent;

  /// Selected [ProjectKindOption.id] when the caller passed `kinds` with
  /// more than one option; null when no kind selector was shown.
  final String? kind;
}

/// Two-field dialog for explicit project creation: a project name + a
/// parent folder (with a folder picker). The new folder lands at
/// `<parent>/<name>` and is only materialised on disk when the caller
/// follows up with [VibeProject.openAt].
///
/// [kind] picks the noun shown in the dialog text — `'project'`
/// (default) shows "New project" / "Project name"; `'package'` swaps
/// to "New package" / "Package name" for Home-tab Studio Builder
/// flows. The result type is unchanged either way.
Future<NewProjectInput?> promptForNewProject(
  BuildContext context, {
  required String defaultParent,
  String kind = 'project',
  List<ProjectKindOption> kinds = const <ProjectKindOption>[],
}) async {
  final noun = kind == 'package' ? 'package' : 'project';
  final nounCap = noun[0].toUpperCase() + noun.substring(1);
  final hint = kind == 'package' ? 'my-package' : 'my-project';
  final nameCtrl = TextEditingController();
  final parentCtrl = TextEditingController(text: defaultParent);
  final c = VibeTokens.colorOf(context);
  // When the caller declares >1 kind, the dialog shows a kind selector
  // and returns the chosen id in [NewProjectInput.kind]. The active
  // built-in (via `projectKindsProvider`) owns the list, not this dialog.
  String? selectedKind = kinds.isNotEmpty ? kinds.first.id : null;
  return showDialog<NewProjectInput?>(
    context: context,
    builder:
        (ctx) => Dialog(
          backgroundColor: c.surface2,
          child: SizedBox(
            width: 520,
            child: StatefulBuilder(
              builder:
                  (ctx, setLocal) => Padding(
                    padding: const EdgeInsets.all(VibeTokens.space4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          'New $noun',
                          style: TextStyle(
                            fontFamily: VibeTokens.fontSans,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                          ),
                        ),
                        const SizedBox(height: VibeTokens.space3),
                        if (kinds.length > 1) ...<Widget>[
                          Text(
                            'Project kind',
                            style: TextStyle(
                              fontFamily: VibeTokens.fontMono,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.0,
                              color: c.textTertiary,
                            ),
                          ),
                          const SizedBox(height: VibeTokens.space1),
                          _ProjectKindSelector(
                            options: kinds,
                            selectedId: selectedKind,
                            onChanged:
                                (id) => setLocal(() => selectedKind = id),
                          ),
                          const SizedBox(height: VibeTokens.space3),
                        ],
                        Text(
                          '$nounCap name',
                          style: TextStyle(
                            fontFamily: VibeTokens.fontMono,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.0,
                            color: c.textTertiary,
                          ),
                        ),
                        const SizedBox(height: VibeTokens.space1),
                        TextField(
                          controller: nameCtrl,
                          autofocus: true,
                          style: vibeMono(size: 12, color: c.textPrimary),
                          decoration: InputDecoration(
                            hintText: hint,
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: VibeTokens.space3),
                        Text(
                          'Parent folder',
                          style: TextStyle(
                            fontFamily: VibeTokens.fontMono,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1.0,
                            color: c.textTertiary,
                          ),
                        ),
                        const SizedBox(height: VibeTokens.space1),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: TextField(
                                controller: parentCtrl,
                                style: vibeMono(size: 12, color: c.textPrimary),
                                decoration: const InputDecoration(
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: VibeTokens.space2),
                            OutlinedButton.icon(
                              onPressed: () async {
                                final picked = await FilePicker.platform
                                    .getDirectoryPath(
                                      dialogTitle: 'Choose parent folder',
                                      initialDirectory:
                                          parentCtrl.text.isNotEmpty
                                              ? parentCtrl.text
                                              : defaultParent,
                                    );
                                if (picked != null && picked.isNotEmpty) {
                                  setLocal(() => parentCtrl.text = picked);
                                }
                              },
                              icon: const Icon(Icons.folder_outlined, size: 14),
                              label: const Text('Browse'),
                            ),
                          ],
                        ),
                        const SizedBox(height: VibeTokens.space4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Widget>[
                            TextButton(
                              onPressed: () => Navigator.of(ctx).pop(null),
                              child: const Text('Cancel'),
                            ),
                            const SizedBox(width: VibeTokens.space2),
                            FilledButton(
                              onPressed: () {
                                final name = nameCtrl.text.trim();
                                final parent = parentCtrl.text.trim();
                                if (name.isEmpty || parent.isEmpty) {
                                  Navigator.of(ctx).pop(null);
                                  return;
                                }
                                Navigator.of(ctx).pop(
                                  NewProjectInput(
                                    name: name,
                                    parent: parent,
                                    kind: selectedKind,
                                  ),
                                );
                              },
                              child: const Text('Create'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
            ),
          ),
        ),
  );
}

/// Asks the user for a workspace path. Used by both `New` and `Open`.
Future<String?> promptForWorkspacePath(
  BuildContext context, {
  required String title,
  required String hint,
}) async {
  final ctrl = TextEditingController();
  final c = VibeTokens.colorOf(context);
  return showDialog<String?>(
    context: context,
    builder:
        (ctx) => Dialog(
          backgroundColor: c.surface2,
          child: SizedBox(
            width: 460,
            child: Padding(
              padding: const EdgeInsets.all(VibeTokens.space4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: VibeTokens.fontSans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: VibeTokens.space2),
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    style: vibeMono(size: 12, color: c.textPrimary),
                    decoration: InputDecoration(hintText: hint, isDense: true),
                    onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
                  ),
                  const SizedBox(height: VibeTokens.space4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(null),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: VibeTokens.space2),
                      FilledButton(
                        onPressed:
                            () => Navigator.of(ctx).pop(ctrl.text.trim()),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
  ).then((v) => v == null || v.isEmpty ? null : v);
}

/// Segmented selector over the declared [ProjectKindOption]s. Generic —
/// the host renders whatever kinds the active built-in contributed via
/// `projectKindsProvider`; this widget knows nothing about any specific
/// domain's kinds.
class _ProjectKindSelector extends StatelessWidget {
  const _ProjectKindSelector({
    required this.options,
    required this.selectedId,
    required this.onChanged,
  });
  final List<ProjectKindOption> options;
  final String? selectedId;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        for (var i = 0; i < options.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: VibeTokens.space2),
          Expanded(
            child: _ProjectKindOptionCard(
              option: options[i],
              selected: options[i].id == selectedId,
              onTap: () => onChanged(options[i].id),
            ),
          ),
        ],
      ],
    );
  }
}

class _ProjectKindOptionCard extends StatelessWidget {
  const _ProjectKindOptionCard({
    required this.option,
    required this.selected,
    required this.onTap,
  });
  final ProjectKindOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final borderColor = selected ? c.mint : c.borderDefault;
    final bgColor = selected ? c.mint.withValues(alpha: 0.10) : c.surface3;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: VibeTokens.space3,
          vertical: VibeTokens.space2,
        ),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: borderColor),
          borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              option.label,
              style: TextStyle(
                fontFamily: VibeTokens.fontSans,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? c.mint : c.textPrimary,
              ),
            ),
            if (option.description.isNotEmpty) ...<Widget>[
              const SizedBox(height: 2),
              Text(
                option.description,
                style: TextStyle(
                  fontFamily: VibeTokens.fontMono,
                  fontSize: 10,
                  color: c.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
