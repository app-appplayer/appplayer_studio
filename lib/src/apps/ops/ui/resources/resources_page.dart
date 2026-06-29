import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/knowledge_registry.dart' show KvFactEntry;
import '../../state/providers.dart';

/// Resources — the active workspace's operational assets
/// (ops-asset-management track P1). Reads the `category:"asset"` facts
/// ([assetsProvider]) and renders one card per asset: kind, title, locator,
/// capability, and whether a credential is attached. Read-only surface here;
/// assets are written through the `knowledge_fact_save` tool (built-in parity
/// rule — UI never mutates a registry directly). Internal and external assets
/// are shown alike — `location` (local/embedded/external) is just a chip.
class ResourcesPage extends ConsumerWidget {
  const ResourcesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final assets = ref.watch(assetsProvider);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Resources', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              IconButton(
                tooltip: 'Migrate credentials (export / import)',
                icon: const Icon(Icons.import_export),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _MigrateDialog(),
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(assetsProvider),
              ),
            ],
          ),
          Text(
            'Operational assets of this workspace — DB · files · code · '
            'homepages · deploy targets · APIs (internal or external). '
            'Add via knowledge_fact_save (category:"asset").',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: assets.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  Center(child: Text('Failed to load assets: $e')),
              data: (list) => list.isEmpty
                  ? Center(
                      child: Text(
                        'No assets yet.',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _AssetCard(list[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssetCard extends StatelessWidget {
  const _AssetCard(this.asset);
  final KvFactEntry asset;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = asset.metadata;
    final kind = (m['kind'] ?? 'data').toString();
    final location = (m['location'] ?? '').toString();
    final locator = (m['locator'] ?? '').toString();
    final capability = (m['capability'] ?? '').toString();
    final credRef = (m['credentialRef'] ?? '').toString();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: cs.surfaceContainerHighest,
              child: Icon(_iconForKind(kind), size: 18, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    asset.value.isEmpty ? asset.key : asset.value,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (locator.isNotEmpty)
                    Text(
                      locator,
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            _Chip(kind),
            if (location.isNotEmpty) ...[const SizedBox(width: 6), _Chip(location)],
            if (capability.isNotEmpty) ...[
              const SizedBox(width: 6),
              _Chip(capability),
            ],
            _OpenButton(assetId: asset.key),
            if (credRef.isNotEmpty) _CredentialButton(credentialRef: credRef),
          ],
        ),
      ),
    );
  }

  static IconData _iconForKind(String kind) {
    switch (kind) {
      case 'db':
        return Icons.storage_outlined;
      case 'file':
        return Icons.insert_drive_file_outlined;
      case 'code':
      case 'repo':
        return Icons.code;
      case 'homepage':
        return Icons.public;
      case 'deploy':
        return Icons.rocket_launch_outlined;
      case 'api':
      case 'mcp':
        return Icons.api;
      default:
        return Icons.folder_outlined;
    }
  }
}

/// Operate an asset through its capability (`asset_open` tool — fs.read /
/// db.query / browser.page_view / authenticated HTTP GET). The credential is
/// resolved internally by the tool; the dialog shows only the result.
class _OpenButton extends ConsumerWidget {
  const _OpenButton({required this.assetId});
  final String assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: 'Open / operate',
      icon: const Icon(Icons.play_circle_outline, size: 18),
      onPressed: () => _open(context, ref),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    Map<String, dynamic> r;
    try {
      r = await opsCallTool(ref, 'asset_open', {'assetId': assetId});
    } catch (e) {
      r = {'ok': false, 'error': '$e'};
    }
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Open · $assetId'),
        content: SingleChildScrollView(
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(r),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Lock indicator + credential editor for an asset with a `credentialRef`.
/// Shows the vault state (`secret.exists`) as a lock, and lets the operator
/// set / change / clear the secret. The value is obscured on input and never
/// read back (vault discipline — only set / exists / remove are exposed).
class _CredentialButton extends ConsumerWidget {
  const _CredentialButton({required this.credentialRef});
  final String credentialRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final exists =
        ref.watch(credentialExistsProvider(credentialRef)).valueOrNull ?? false;
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: exists ? 'Credential set — edit' : 'Set credential',
      icon: Icon(
        exists ? Icons.lock : Icons.lock_open,
        size: 18,
        color: exists ? cs.primary : cs.onSurfaceVariant,
      ),
      onPressed: () => _edit(context, ref, exists),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, bool exists) async {
    final controller = TextEditingController();
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Credential · $credentialRef'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              exists
                  ? 'A secret is stored. Enter a new value to replace it.'
                  : 'Enter the secret value (stored in the OS keychain).',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Secret',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          if (exists)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'clear'),
              child: const Text(
                'Clear',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    try {
      if (action == 'save') {
        if (controller.text.isEmpty) return;
        await opsCallTool(ref, 'secret.set', {
          'ref': credentialRef,
          'value': controller.text,
        });
      } else if (action == 'clear') {
        await opsCallTool(ref, 'secret.remove', {'ref': credentialRef});
      } else {
        return;
      }
      ref.invalidate(credentialExistsProvider(credentialRef));
    } finally {
      controller.dispose();
    }
  }
}

/// Cross-machine credential migration (ops-asset-management P4). Export seals
/// the workspace's asset credentials under a passphrase into an opaque blob
/// (`credentials_export`); import restores them into this machine's keychain
/// (`credentials_import`). The keychain key never travels — only the passphrase
/// and the encrypted blob. Secrets are never shown in plaintext either way.
class _MigrateDialog extends ConsumerStatefulWidget {
  const _MigrateDialog();

  @override
  ConsumerState<_MigrateDialog> createState() => _MigrateDialogState();
}

class _MigrateDialogState extends ConsumerState<_MigrateDialog> {
  final _exportPass = TextEditingController();
  final _importPass = TextEditingController();
  final _blob = TextEditingController();
  String? _status;
  bool _busy = false;

  @override
  void dispose() {
    _exportPass.dispose();
    _importPass.dispose();
    _blob.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    if (_exportPass.text.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await opsCallTool(ref, 'credentials_export', {
        'passphrase': _exportPass.text,
      });
      if (r['ok'] == true) {
        _blob.text = (r['sealed'] ?? '').toString();
        _status = 'Sealed ${r['count']} credential(s): '
            '${(r['refsDeclared'] as List?)?.join(', ') ?? ''}. '
            'Copy the blob below to the target machine.';
      } else {
        _status = 'Export failed: ${r['error']}';
      }
    } catch (e) {
      _status = 'Export error: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_importPass.text.isEmpty || _blob.text.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = await opsCallTool(ref, 'credentials_import', {
        'passphrase': _importPass.text,
        'sealed': _blob.text,
      });
      if (r['ok'] == true) {
        final restored = (r['restored'] as List?) ?? const [];
        _status = 'Restored ${restored.length} credential(s) into the keychain: '
            '${restored.join(', ')}.';
        ref.invalidate(assetsProvider);
      } else {
        _status = 'Import failed: ${r['error']}';
      }
    } catch (e) {
      _status = 'Import error: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Migrate credentials'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Seal this workspace’s asset credentials under a passphrase '
              'to move them to another computer, then unseal them there. The '
              'keychain key never leaves this machine.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text('Export', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _exportPass,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Passphrase',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _export,
                  child: const Text('Seal'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Sealed blob', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            TextField(
              controller: _blob,
              maxLines: 4,
              minLines: 2,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              decoration: const InputDecoration(
                hintText: 'Sealed credential blob (paste here to import)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Text('Import', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _importPass,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Passphrase',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _busy ? null : _import,
                  child: const Text('Restore'),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(
                _status!,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
      ),
    );
  }
}
