/// Plugins manager — a Studio **host-level** surface (not an app's), reached
/// from a Home entry icon (right of the BUILT-IN APPS title), the same place
/// the pro tier surfaces its Marketplace. Apps are installed from Home and
/// open as tabs; plugins are sub-features pulled in from a bundle / MCP server
/// / hub whose tools enter the shared catalog as `<id>.<tool>` for any app or
/// agent. This surface lists the installed plugins and lets the user register
/// / unregister them, with a list / icon view toggle. All logic lives in the
/// host `plugin.*` tools (reached via `chromeBridge.callHostTool`); this is UI
/// + wiring only.
library;

import 'package:flutter/material.dart';

import '../main/chrome_bridge.dart';
import 'tokens.dart';

/// Toggles the plugins overlay. The host flips it from the Home entry's
/// onTap (mirrors pro's `MarketController`).
class PluginsController extends ValueNotifier<bool> {
  PluginsController() : super(false);
  void open() => value = true;
  void close() => value = false;
}

/// Full-surface plugins overlay, mounted once in the shell's overlay stack.
/// Renders nothing until [controller] is opened, so it costs nothing while
/// the user is not managing plugins.
class PluginsOverlayHost extends StatelessWidget {
  const PluginsOverlayHost({
    super.key,
    required this.controller,
    required this.bridge,
  });

  final PluginsController controller;
  final ChromeBridge bridge;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller,
      builder: (context, open, _) {
        if (!open) return const SizedBox.shrink();
        final c = VibeTokens.colorOf(context);
        return Material(
          color: c.bg,
          child: SafeArea(
            child: _PluginsBody(bridge: bridge, onClose: controller.close),
          ),
        );
      },
    );
  }
}

enum _PluginView { list, grid }

/// The plugins surface body: header (view toggle / refresh / register /
/// close) + the installed list. Reads `plugin.list`; writes via
/// `plugin.register` / `plugin.unregister` through `chromeBridge.callHostTool`.
class _PluginsBody extends StatefulWidget {
  const _PluginsBody({required this.bridge, required this.onClose});

  final ChromeBridge bridge;
  final VoidCallback onClose;

  @override
  State<_PluginsBody> createState() => _PluginsBodyState();
}

class _PluginsBodyState extends State<_PluginsBody> {
  _PluginView _view = _PluginView.list;
  List<Map<String, dynamic>>? _plugins;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
    String tool,
    Map<String, dynamic> params,
  ) async {
    final fn = widget.bridge.callHostTool;
    if (fn == null) return <String, dynamic>{'ok': false, 'error': 'no host'};
    return fn(tool, params);
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await _call('plugin.list', const <String, dynamic>{});
      final raw = (r['plugins'] as List?) ?? const <dynamic>[];
      _plugins = <Map<String, dynamic>>[
        for (final e in raw)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _unregister(String id) async {
    final c = VibeTokens.colorOf(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface2,
        title: Text('Unregister · $id', style: _title(c)),
        content: Text(
          'Tear this plugin’s `$id.*` catalog entries down, close its '
          'connection, and remove it from disk.',
          style: _body(c),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: _body(c)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unregister'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _call('plugin.unregister', <String, dynamic>{'id': id});
    await _load();
  }

  Future<void> _register() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _RegisterDialog(call: _call),
    );
    if (added == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.all(VibeTokens.space5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.extension_outlined, size: 20, color: c.mint),
              const SizedBox(width: VibeTokens.space2),
              Text('Plugins', style: _title(c).copyWith(fontSize: 15)),
              const SizedBox(width: VibeTokens.space2),
              if (_busy)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: c.mint),
                ),
              const Spacer(),
              _ViewToggle(
                view: _view,
                onChanged: (v) => setState(() => _view = v),
              ),
              const SizedBox(width: VibeTokens.space2),
              IconButton(
                tooltip: 'Refresh',
                icon: Icon(Icons.refresh, size: 18, color: c.textSecondary),
                onPressed: _load,
              ),
              const SizedBox(width: VibeTokens.space1),
              FilledButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Register'),
                onPressed: _register,
              ),
              const SizedBox(width: VibeTokens.space2),
              IconButton(
                tooltip: 'Close',
                icon: Icon(Icons.close, size: 20, color: c.textSecondary),
                onPressed: widget.onClose,
              ),
            ],
          ),
          const SizedBox(height: VibeTokens.space2),
          Text(
            'Sub-features pulled in from a bundle, MCP server, or hub — each '
            'plugin’s tools join the catalog as `<id>.<tool>` for any app or '
            'agent. Registrations persist and re-connect on boot.',
            style: _body(c).copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: VibeTokens.space4),
          Expanded(child: _content(c)),
        ],
      ),
    );
  }

  Widget _content(dynamic c) {
    if (_error != null) {
      return Center(child: Text('Failed to load: $_error', style: _body(c)));
    }
    final list = _plugins;
    if (list == null) {
      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: c.mint),
        ),
      );
    }
    if (list.isEmpty) {
      return Center(
        child: Text(
          'No plugins registered yet.\nTap Register to add a bundle, server, '
          'or hub.',
          textAlign: TextAlign.center,
          style: _body(c).copyWith(color: c.textTertiary),
        ),
      );
    }
    return _view == _PluginView.list
        ? ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: VibeTokens.space2),
            itemBuilder: (_, i) => _row(c, list[i]),
          )
        : GridView.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisExtent: 132,
              crossAxisSpacing: VibeTokens.space3,
              mainAxisSpacing: VibeTokens.space3,
            ),
            itemCount: list.length,
            itemBuilder: (_, i) => _tile(c, list[i]),
          );
  }

  Widget _row(dynamic c, Map<String, dynamic> p) {
    final id = (p['id'] ?? '').toString();
    final kind = (p['kind'] ?? '').toString();
    final tools = (p['tools'] as List?) ?? const <dynamic>[];
    return Container(
      padding: const EdgeInsets.all(VibeTokens.space3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Row(
        children: <Widget>[
          Icon(_iconFor(kind), size: 18, color: c.mint),
          const SizedBox(width: VibeTokens.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(id, style: _label(c)),
                const SizedBox(height: 2),
                Text(
                  tools.isEmpty
                      ? 'no tools exposed'
                      : tools.map((t) => '$t').join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _body(c).copyWith(color: c.textTertiary),
                ),
              ],
            ),
          ),
          _chip(c, kind),
          const SizedBox(width: VibeTokens.space2),
          _chip(c, '${tools.length} tool${tools.length == 1 ? '' : 's'}'),
          IconButton(
            tooltip: 'Unregister',
            icon: Icon(Icons.delete_outline, size: 18, color: c.textSecondary),
            onPressed: () => _unregister(id),
          ),
        ],
      ),
    );
  }

  Widget _tile(dynamic c, Map<String, dynamic> p) {
    final id = (p['id'] ?? '').toString();
    final kind = (p['kind'] ?? '').toString();
    final tools = (p['tools'] as List?) ?? const <dynamic>[];
    return Container(
      padding: const EdgeInsets.all(VibeTokens.space3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(_iconFor(kind), size: 20, color: c.mint),
              const Spacer(),
              InkWell(
                onTap: () => _unregister(id),
                child: Icon(
                  Icons.delete_outline,
                  size: 16,
                  color: c.textSecondary,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(id, maxLines: 1, overflow: TextOverflow.ellipsis, style: _label(c)),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              _chip(c, kind),
              const SizedBox(width: VibeTokens.space1),
              _chip(c, '${tools.length}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(dynamic c, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          border: Border.all(color: c.borderSubtle),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: VibeTokens.fontMono,
            fontSize: 10,
            color: c.textSecondary,
          ),
        ),
      );

  static IconData _iconFor(String kind) {
    switch (kind) {
      case 'server':
        return Icons.dns_outlined;
      case 'hub':
        return Icons.hub_outlined;
      case 'bundle':
        return Icons.inventory_2_outlined;
      default:
        return Icons.extension_outlined;
    }
  }

  TextStyle _title(dynamic c) => TextStyle(
        fontFamily: VibeTokens.fontMono,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: c.textPrimary,
      );

  TextStyle _label(dynamic c) => TextStyle(
        fontFamily: VibeTokens.fontMono,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: c.textPrimary,
      );

  TextStyle _body(dynamic c) => TextStyle(
        fontFamily: VibeTokens.fontMono,
        fontSize: 11,
        color: c.textSecondary,
      );
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onChanged});

  final _PluginView view;
  final ValueChanged<_PluginView> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    Widget btn(_PluginView v, IconData icon, String tip) {
      final active = v == view;
      return Tooltip(
        message: tip,
        child: InkWell(
          onTap: () => onChanged(v),
          borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
          child: Container(
            padding: const EdgeInsets.all(VibeTokens.space1),
            decoration: BoxDecoration(
              color: active ? c.surface2 : Colors.transparent,
              borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
            ),
            child: Icon(
              icon,
              size: 16,
              color: active ? c.mint : c.textSecondary,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        btn(_PluginView.list, Icons.view_list_outlined, 'List view'),
        const SizedBox(width: 2),
        btn(_PluginView.grid, Icons.grid_view_outlined, 'Icon view'),
      ],
    );
  }
}

/// Register form — kind (server / hub / bundle) + id + endpoint (+ transport
/// for server/hub). Calls `plugin.register`; pops `true` on success.
class _RegisterDialog extends StatefulWidget {
  const _RegisterDialog({required this.call});

  final Future<Map<String, dynamic>> Function(
    String tool,
    Map<String, dynamic> params,
  ) call;

  @override
  State<_RegisterDialog> createState() => _RegisterDialogState();
}

class _RegisterDialogState extends State<_RegisterDialog> {
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  String _kind = 'server';
  String _transport = 'streamableHttp';
  String? _status;
  bool _busy = false;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _endpoint.dispose();
    super.dispose();
  }

  bool get _isBundle => _kind == 'bundle';

  Future<void> _submit() async {
    if (_id.text.isEmpty) {
      setState(() => _status = 'An id is required (the tool namespace).');
      return;
    }
    if (_endpoint.text.isEmpty) {
      setState(() => _status = _isBundle
          ? 'A bundle path (.mbd) is required.'
          : 'An endpoint (URL / command) is required.');
      return;
    }
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final r = await widget.call('plugin.register', <String, dynamic>{
        'id': _id.text,
        'kind': _kind,
        'endpoint': _endpoint.text,
        if (_name.text.isNotEmpty) 'name': _name.text,
        if (!_isBundle) 'transport': _transport,
      });
      if (r['ok'] == false || r['error'] != null) {
        setState(() => _status = 'Register failed: ${r['error']}');
        return;
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _status = 'Register error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    InputDecoration dec(String label) => InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: c.textSecondary, fontSize: 12),
          border: const OutlineInputBorder(),
          isDense: true,
        );
    return AlertDialog(
      backgroundColor: c.surface2,
      title: Text(
        'Register plugin',
        style: TextStyle(
          fontFamily: VibeTokens.fontMono,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: c.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: dec('Kind'),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem(value: 'server', child: Text('server — MCP server')),
                DropdownMenuItem(value: 'hub', child: Text('hub — remote relay')),
                DropdownMenuItem(value: 'bundle', child: Text('bundle — local .mbd')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? 'server'),
            ),
            const SizedBox(height: VibeTokens.space3),
            TextField(controller: _id, decoration: dec('Id (namespace — `<id>.<tool>`)')),
            const SizedBox(height: VibeTokens.space3),
            TextField(controller: _name, decoration: dec('Name (optional)')),
            const SizedBox(height: VibeTokens.space3),
            if (!_isBundle) ...<Widget>[
              DropdownButtonFormField<String>(
                initialValue: _transport,
                decoration: dec('Transport'),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem(
                    value: 'streamableHttp',
                    child: Text('streamableHttp'),
                  ),
                  DropdownMenuItem(value: 'sse', child: Text('sse')),
                  DropdownMenuItem(value: 'stdio', child: Text('stdio')),
                ],
                onChanged: (v) =>
                    setState(() => _transport = v ?? 'streamableHttp'),
              ),
              const SizedBox(height: VibeTokens.space3),
            ],
            TextField(
              controller: _endpoint,
              decoration: dec(
                _isBundle ? 'Bundle path (.mbd)' : 'Endpoint (URL / command)',
              ),
            ),
            if (_status != null) ...<Widget>[
              const SizedBox(height: VibeTokens.space3),
              Text(
                _status!,
                style: const TextStyle(
                  fontFamily: VibeTokens.fontMono,
                  fontSize: 11,
                  color: Colors.redAccent,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text('Cancel', style: TextStyle(color: c.textSecondary)),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Register'),
        ),
      ],
    );
  }
}
