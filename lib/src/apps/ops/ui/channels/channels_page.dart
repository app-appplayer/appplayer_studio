import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// Channels — register the external messaging accounts (KakaoTalk / email /
/// Slack / …) this workspace uses, so progress can be sent out and inbound can
/// be handled. Credentials are stored in the secure vault via
/// `channel.credential_set` (keyed by id — different accounts on the same
/// platform are just different ids) and `channel.connect` resolves them, so
/// secrets never travel in the call. Pure UI over the host `channel.*` tools.
class ChannelsPage extends ConsumerStatefulWidget {
  const ChannelsPage({super.key});

  @override
  ConsumerState<ChannelsPage> createState() => _ChannelsPageState();
}

/// A field the operator fills for a platform. `secret` fields are obscured.
class _Field {
  const _Field(this.key, this.label, {this.secret = false});
  final String key;
  final String label;
  final bool secret;
}

/// The account fields per platform. Ops owns this (the accounts it uses); the
/// connector validates at connect time, so a missing field surfaces as a clear
/// `missing_param` rather than silent failure.
const Map<String, List<_Field>> _platformFields = {
  'kakao': [
    _Field('botId', 'Bot ID'),
    _Field('botToken', 'Bot token / REST API key', secret: true),
  ],
  'slack': [
    _Field('botToken', 'Bot token', secret: true),
    _Field('signingSecret', 'Signing secret', secret: true),
  ],
  'telegram': [_Field('botToken', 'Bot token', secret: true)],
  'email': [
    _Field('botEmail', 'From address'),
    _Field('host', 'IMAP/SMTP host'),
    _Field('port', 'Port'),
    _Field('username', 'Username'),
    _Field('password', 'Password', secret: true),
  ],
};

class _ChannelsPageState extends ConsumerState<ChannelsPage> {
  bool _loading = true;
  String? _error;

  /// Why the last remove did not fully succeed — shown until the next one.
  String? _removeError;
  List<Map<String, dynamic>> _channels = const [];
  List<String> _credentialIds = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await opsCallTool(ref, 'channel.list', const {});
      final creds = await opsCallTool(ref, 'channel.credential_ids', const {});
      if (!mounted) return;
      setState(() {
        _channels =
            ((list['channels'] as List?) ?? const [])
                .whereType<Map>()
                .map((e) => e.cast<String, dynamic>())
                .toList();
        _credentialIds =
            ((creds['ids'] as List?) ?? const []).map((e) => '$e').toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _remove(String id) async {
    final failures = <String>[];
    try {
      await opsCallTool(ref, 'channel.disconnect', {'id': id});
    } catch (e) {
      // A stored-only credential has no live connector; that is the one
      // disconnect failure removal is expected to meet.
      if (!'$e'.contains('channel.not_found')) {
        failures.add('disconnect failed: $e');
      }
    }
    try {
      await opsCallTool(ref, 'channel.credential_remove', {'id': id});
    } catch (e) {
      failures.add('credentials were not deleted: $e');
    }
    if (!mounted) return;
    setState(() {
      _removeError =
          failures.isEmpty ? null : 'Removing "$id": ${failures.join('; ')}';
    });
    await _refresh();
  }

  Future<void> _addDialog() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => const _AddChannelDialog(),
    );
    if (added == true) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SYSTEM',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Channels',
                      style: Theme.of(context).textTheme.displayMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _addDialog,
                icon: const Icon(Icons.add, size: 14),
                label: const Text('Add channel'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'External accounts this workspace uses. Credentials are stored in '
            'the secure vault; secrets never appear here.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_removeError != null) ...[
            Text(
              _removeError!,
              key: const ValueKey('channels.removeError'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }
    // Merge connected channels + stored credential ids into one row set.
    final ids = <String>{
      for (final c in _channels)
        if (c['channelId'] is String) c['channelId'] as String,
      ..._credentialIds,
    }..remove('in_app');
    if (ids.isEmpty) {
      return const Center(
        child: Text(
          'No channels yet. Add one to notify or receive externally.',
        ),
      );
    }
    final connectedById = <String, Map<String, dynamic>>{
      for (final c in _channels)
        if (c['channelId'] is String) c['channelId'] as String: c,
    };
    return ListView(
      children: [
        for (final id in ids)
          Card(
            child: ListTile(
              leading: Icon(
                connectedById[id]?['running'] == true
                    ? Icons.check_circle_outline
                    : Icons.radio_button_unchecked,
              ),
              title: Text(id),
              subtitle: Text(
                connectedById[id] != null
                    ? 'platform: ${connectedById[id]!['platform']} · '
                        '${connectedById[id]!['running'] == true ? "connected" : "stopped"}'
                    : 'credentials stored · not connected',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove',
                onPressed: () => _remove(id),
              ),
            ),
          ),
      ],
    );
  }
}

class _AddChannelDialog extends ConsumerStatefulWidget {
  const _AddChannelDialog();

  @override
  ConsumerState<_AddChannelDialog> createState() => _AddChannelDialogState();
}

class _AddChannelDialogState extends ConsumerState<_AddChannelDialog> {
  String _platform = 'kakao';
  final _idCtrl = TextEditingController(text: 'kakao');
  final Map<String, TextEditingController> _fieldCtrls = {};
  bool _busy = false;
  String? _msg;

  List<_Field> get _fields => _platformFields[_platform] ?? const [];

  TextEditingController _ctrl(String key) =>
      _fieldCtrls.putIfAbsent(key, () => TextEditingController());

  @override
  void dispose() {
    _idCtrl.dispose();
    for (final c in _fieldCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    final id = _idCtrl.text.trim();
    if (id.isEmpty) {
      setState(() {
        _busy = false;
        _msg = 'id required';
      });
      return;
    }
    final params = <String, dynamic>{};
    for (final f in _fields) {
      final v = _ctrl(f.key).text.trim();
      if (v.isNotEmpty) params[f.key] = v;
    }
    try {
      await opsCallTool(ref, 'channel.credential_set', {
        'id': id,
        'platform': _platform,
        'params': params,
      });
      // Try to connect now; a missing/invalid field surfaces here.
      final res = await opsCallTool(ref, 'channel.connect', {
        'platform': _platform,
        'id': id,
      });
      if (!mounted) return;
      if (res['ok'] == false) {
        setState(() {
          _busy = false;
          _msg = 'saved, but connect failed: ${res['error'] ?? res['code']}';
        });
        return;
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _msg = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add channel'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _platform,
                decoration: const InputDecoration(labelText: 'Platform'),
                items: [
                  for (final p in _platformFields.keys)
                    DropdownMenuItem(value: p, child: Text(p)),
                ],
                onChanged:
                    _busy
                        ? null
                        : (v) => setState(() {
                          _platform = v ?? _platform;
                          if (_idCtrl.text.trim().isEmpty ||
                              _platformFields.containsKey(
                                _idCtrl.text.trim(),
                              )) {
                            _idCtrl.text = _platform;
                          }
                        }),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _idCtrl,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Account id',
                  helperText:
                      'Unique per account (e.g. company-kakao, alice-email)',
                ),
              ),
              const SizedBox(height: 8),
              for (final f in _fields) ...[
                TextField(
                  controller: _ctrl(f.key),
                  enabled: !_busy,
                  obscureText: f.secret,
                  decoration: InputDecoration(labelText: f.label),
                ),
                const SizedBox(height: 8),
              ],
              if (_msg != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _msg!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child:
              _busy
                  ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                  : const Text('Save & connect'),
        ),
      ],
    );
  }
}
