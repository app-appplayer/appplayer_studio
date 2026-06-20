import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/ops_config.dart';
import '../../state/providers.dart';
import '../../util/llm_model_catalog.dart';
import '../../widgets/llm_model_dropdown.dart';

final _configLoaderProvider = FutureProvider.autoDispose<OpsConfig>((
  ref,
) async {
  return OpsConfig.load();
});

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_configLoaderProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load settings: $e')),
      data:
          (cfg) => _SettingsForm(
            // Re-key on every distinct cfg instance so the form's local state
            // (checkbox toggles, port text) is re-initialized from disk
            // whenever the underlying file changes — avoids stale UI after
            // an external edit or another session's save.
            key: ObjectKey(cfg),
            initial: cfg,
            onSaved: () => ref.invalidate(_configLoaderProvider),
          ),
    );
  }
}

class _SettingsForm extends ConsumerStatefulWidget {
  const _SettingsForm({
    super.key,
    required this.initial,
    required this.onSaved,
  });
  final OpsConfig initial;
  final VoidCallback onSaved;

  @override
  ConsumerState<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends ConsumerState<_SettingsForm> {
  late final TextEditingController _appName;
  late String _themeMode;
  late String _provider;
  late final TextEditingController _apiKey;
  // Model selection — `_modelId` matches one of the catalog ids for the
  // current `_provider` or equals [kCustomModelOption.id] when the user
  // wants a free-text id not in the dropdown. The TextField below only
  // takes precedence in the custom branch.
  late String _modelId;
  late final TextEditingController _customModel;
  late final TextEditingController _chromium;
  late final TextEditingController _kvPath;
  late bool _sseEnabled;
  late bool _streamableHttpEnabled;
  late final TextEditingController _ssePort;
  late final TextEditingController _streamableHttpPort;
  bool _saving = false;
  String? _status;

  late bool _useInternalLlm;

  @override
  void initState() {
    super.initState();
    _appName = TextEditingController(text: widget.initial.appName);
    _themeMode =
        OpsConfig.themeModes.contains(widget.initial.themeMode)
            ? widget.initial.themeMode
            : 'dark';
    _useInternalLlm = widget.initial.llm.defaultProvider.isNotEmpty;
    _provider =
        widget.initial.llm.defaultProvider.isEmpty
            ? 'claude'
            : widget.initial.llm.defaultProvider;
    final prov = widget.initial.llm.providers[_provider];
    _apiKey = TextEditingController(text: prov?.apiKey ?? '');
    final providerOpt = findProviderOption(_provider);
    final savedModel = prov?.model ?? '';
    final inCatalog =
        savedModel.isNotEmpty &&
        providerOpt != null &&
        providerOpt.models.any((m) => m.id == savedModel);
    if (savedModel.isEmpty) {
      _modelId = providerOpt?.defaultModel.id ?? kCustomModelOption.id;
    } else {
      _modelId = inCatalog ? savedModel : kCustomModelOption.id;
    }
    _customModel = TextEditingController(text: inCatalog ? '' : savedModel);
    _chromium = TextEditingController(
      text: widget.initial.browser.chromiumPath ?? '',
    );
    _kvPath = TextEditingController(text: widget.initial.storage.localKvPath);
    final mcp = widget.initial.mcp.inbound;
    _sseEnabled = mcp.sseEnabled;
    _streamableHttpEnabled = mcp.streamableHttpEnabled;
    _ssePort = TextEditingController(text: '${mcp.ssePort}');
    _streamableHttpPort = TextEditingController(
      text: '${mcp.streamableHttpPort}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final skills = ref.watch(appSkillListProvider);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text('Settings', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const _SectionTitle('App name'),
          TextField(
            controller: _appName,
            decoration: InputDecoration(
              labelText: 'Display name (AppBar title)',
              hintText: OpsConfig.defaultAppName,
            ),
          ),
          const Divider(height: 32),
          const _SectionTitle('Appearance'),
          DropdownButtonFormField<String>(
            initialValue: _themeMode,
            decoration: const InputDecoration(
              labelText: 'Theme mode',
              helperText:
                  'system follows the OS preference. Switch takes effect immediately; persisted to config.yaml on save.',
            ),
            items: const [
              DropdownMenuItem(value: 'system', child: Text('System (auto)')),
              DropdownMenuItem(value: 'light', child: Text('Light')),
              DropdownMenuItem(value: 'dark', child: Text('Dark')),
            ],
            onChanged: (v) {
              if (v == null || v == _themeMode) return;
              setState(() => _themeMode = v);
              // Live preview — flips MaterialApp the moment the dropdown
              // closes; on Save we also write the choice to disk.
              ref.read(opsThemeModeProvider.notifier).state = parseThemeMode(v);
            },
          ),
          const Divider(height: 32),
          const _SectionTitle('LLM provider (optional)'),
          CheckboxListTile(
            title: const Text('Use internal LLM provider'),
            subtitle: const Text(
              'When off, the app runs using only external Claude Desktop/Code',
            ),
            value: _useInternalLlm,
            onChanged:
                (v) => setState(() => _useInternalLlm = v ?? _useInternalLlm),
          ),
          if (_useInternalLlm) ...[
            DropdownButtonFormField<String>(
              initialValue: _provider,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: [
                for (final p in kLlmProviderCatalog)
                  DropdownMenuItem(value: p.id, child: Text(p.label)),
              ],
              onChanged: (v) {
                if (v == null || v == _provider) return;
                setState(() {
                  _provider = v;
                  // Reset model to the new provider's default — keeps the
                  // model dropdown options consistent with the chosen
                  // provider catalog.
                  final opt = findProviderOption(v);
                  _modelId = opt?.defaultModel.id ?? kCustomModelOption.id;
                  _customModel.text = '';
                });
              },
            ),
            TextField(
              controller: _apiKey,
              decoration: const InputDecoration(labelText: 'API key'),
              obscureText: true,
            ),
            const SizedBox(height: 8),
            LlmModelDropdown(
              providerId: _provider,
              modelId: _modelId,
              customController: _customModel,
              onChanged: (v) => setState(() => _modelId = v),
            ),
          ],
          const Divider(height: 32),
          const _SectionTitle('MCP inbound'),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              'stdio is auto-enabled when a client launches the app as a subprocess — not configured here.\n'
              'SSE / Streamable HTTP listen only when selected.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          CheckboxListTile(
            dense: true,
            title: const Text('SSE (legacy) listen'),
            subtitle: const Text('endpoint: /sse · messages: /messages'),
            value: _sseEnabled,
            onChanged: (v) => setState(() => _sseEnabled = v ?? _sseEnabled),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16, bottom: 8),
            child: TextField(
              controller: _ssePort,
              enabled: _sseEnabled,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'SSE port',
                isDense: true,
              ),
            ),
          ),
          CheckboxListTile(
            dense: true,
            title: const Text('Streamable HTTP (2025-03-26) listen'),
            subtitle: const Text('endpoint: /mcp · POST + GET SSE on one path'),
            value: _streamableHttpEnabled,
            onChanged:
                (v) => setState(
                  () => _streamableHttpEnabled = v ?? _streamableHttpEnabled,
                ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 56, right: 16, bottom: 8),
            child: TextField(
              controller: _streamableHttpPort,
              enabled: _streamableHttpEnabled,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Streamable HTTP port',
                isDense: true,
              ),
            ),
          ),
          const Divider(height: 32),
          const _SectionTitle('Browser capability'),
          TextField(
            controller: _chromium,
            decoration: const InputDecoration(
              labelText: 'Chromium path',
              hintText: 'Empty to disable',
            ),
          ),
          const Divider(height: 32),
          const _SectionTitle('Storage'),
          TextField(
            controller: _kvPath,
            decoration: const InputDecoration(labelText: 'Local KV root'),
          ),
          const Divider(height: 32),
          _SectionTitle('Loaded skills (${skills.length})'),
          ...skills.map(
            (id) => ListTile(
              dense: true,
              leading: const Icon(Icons.extension_outlined),
              title: Text(id),
            ),
          ),
          const Divider(height: 32),
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.save),
                onPressed: _saving ? null : _save,
                label: const Text('Save settings'),
              ),
              const SizedBox(width: 12),
              if (_status != null) Text(_status!),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final current = widget.initial;
      final LlmSettings llm;
      if (_useInternalLlm) {
        final providers = Map<String, LlmProviderSettings>.from(
          current.llm.providers,
        );
        final resolvedModel =
            _modelId == kCustomModelOption.id
                ? _customModel.text.trim()
                : _modelId;
        providers[_provider] = LlmProviderSettings(
          apiKey: _apiKey.text,
          model: resolvedModel,
        );
        llm = LlmSettings(
          defaultProvider: _provider,
          providers: providers,
          timeoutSeconds: current.llm.timeoutSeconds,
        );
      } else {
        llm = const LlmSettings.empty();
      }
      final updated = OpsConfig(
        version: current.version,
        appName:
            _appName.text.trim().isEmpty
                ? OpsConfig.defaultAppName
                : _appName.text.trim(),
        activeWorkspace: current.activeWorkspace,
        workspacesRoot: current.workspacesRoot,
        themeMode: _themeMode,
        llm: llm,
        mcp: McpSettings(
          inbound: InboundMcpSettings(
            sseEnabled: _sseEnabled,
            streamableHttpEnabled: _streamableHttpEnabled,
            ssePort: int.tryParse(_ssePort.text) ?? current.mcp.inbound.ssePort,
            streamableHttpPort:
                int.tryParse(_streamableHttpPort.text) ??
                current.mcp.inbound.streamableHttpPort,
          ),
          outbound: current.mcp.outbound,
        ),
        browser: BrowserSettings(
          chromiumPath: _chromium.text.isEmpty ? null : _chromium.text,
          userAgent: current.browser.userAgent,
          defaultViewport: current.browser.defaultViewport,
          downloadDir: current.browser.downloadDir,
          maxConcurrentContexts: current.browser.maxConcurrentContexts,
          respectRobots: current.browser.respectRobots,
        ),
        storage: StorageSettings(
          localKvPath: _kvPath.text,
          backupIntervalHours: current.storage.backupIntervalHours,
          retentionDays: current.storage.retentionDays,
        ),
        channel: current.channel,
        security: current.security,
        systemAgent: current.systemAgent,
      );
      await updated.save();
      ref.read(opsConfigProvider.notifier).state = updated;
      widget.onSaved();
      setState(
        () =>
            _status =
                'Saved. App name updates immediately; other settings need a restart.',
      );
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
