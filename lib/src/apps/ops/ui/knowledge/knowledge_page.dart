import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../registries/knowledge_registry.dart';
import '../../state/providers.dart';
import '../../widgets/empty_state.dart';
import 'graph_tab.dart';

class KnowledgePage extends ConsumerStatefulWidget {
  const KnowledgePage({super.key});

  @override
  ConsumerState<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends ConsumerState<KnowledgePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) {
      return const Center(child: Text('Select a workspace'));
    }
    return Column(
      children: [
        TabBar(
          controller: _tab,
          tabs: const [
            Tab(icon: Icon(Icons.fact_check_outlined), text: 'Facts'),
            Tab(icon: Icon(Icons.hub_outlined), text: 'Graph'),
            Tab(icon: Icon(Icons.folder_outlined), text: 'Files'),
            Tab(icon: Icon(Icons.upload_file_outlined), text: 'Ingest'),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _FactsTab(wsId: wsId),
              GraphTab(wsId: wsId),
              _FilesTab(wsId: wsId),
              _IngestTab(wsId: wsId),
            ],
          ),
        ),
      ],
    );
  }
}

// --- Facts ---

class _FactsTab extends ConsumerStatefulWidget {
  const _FactsTab({required this.wsId});
  final String wsId;

  @override
  ConsumerState<_FactsTab> createState() => _FactsTabState();
}

class _FactsTabState extends ConsumerState<_FactsTab> {
  final _queryCtrl = TextEditingController();
  List<KvFactEntry>? _kvResults;
  List<dynamic>? _graphResults; // bundle.FactRecord values
  String? _error;
  bool _loading = false;
  bool _initialLoaded = false;

  @override
  void initState() {
    super.initState();
    // Eager initial load so the user sees saved facts without typing.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runQuery());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Question (empty for full list)',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _runQuery(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _loading ? null : _runQuery,
                child: const Text('Search'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _loading ? null : _showFactSaveDialog,
                child: const Text('Save fact'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }
    if (!_initialLoaded) {
      return const SizedBox.shrink();
    }
    final items = <Widget>[];
    final graph = _graphResults ?? const [];
    if (graph.isNotEmpty) {
      items.add(_sectionHeader('Fact graph (${graph.length})'));
      for (final f in graph) {
        items.add(_graphTile(f));
      }
    }
    final kv = _kvResults ?? const <KvFactEntry>[];
    if (kv.isNotEmpty) {
      items.add(_sectionHeader('Saved facts (${kv.length})'));
      for (final e in kv) {
        items.add(_kvTile(e));
      }
    }
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.fact_check_outlined,
        headline: 'No matching results',
        hint: 'Try a different keyword, or save a new fact below.',
      );
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (_, i) => items[i],
    );
  }

  Widget _sectionHeader(String label) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(color: Colors.grey[700]),
    ),
  );

  Widget _graphTile(dynamic f) {
    final id = f.id?.toString() ?? '';
    final content = f.content?.toString() ?? '';
    final preview =
        content.length > 120 ? '${content.substring(0, 120)}…' : content;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        leading: const Icon(Icons.memory_outlined),
        title: Text(id, overflow: TextOverflow.ellipsis),
        subtitle: Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.open_in_full, size: 18),
        onTap:
            () =>
                _showDetail(title: id, subtitle: '(fact graph)', body: content),
      ),
    );
  }

  Widget _kvTile(KvFactEntry e) {
    final preview =
        e.value.length > 120 ? '${e.value.substring(0, 120)}…' : e.value;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        leading: const Icon(Icons.fact_check_outlined),
        title: Text(
          '${e.category} / ${e.key}',
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '$preview\n${e.savedAt ?? ""} · ${e.value.length} chars',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: const Icon(Icons.open_in_full, size: 18),
        onTap:
            () => _showDetail(
              title: '${e.category} / ${e.key}',
              subtitle: e.savedAt ?? '',
              body: e.value,
              metadata: e.metadata,
            ),
      ),
    );
  }

  Future<void> _runQuery() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final init = ref.read(knowledgeInitProvider);
      final q = _queryCtrl.text.trim();
      final graph = await init.registries.knowledge.query(q, limit: 20);
      final kv = await init.registries.knowledge.listKvFacts(filter: q);
      if (!mounted) return;
      setState(() {
        _graphResults = graph;
        _kvResults = kv;
        _initialLoaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showDetail({
    required String title,
    required String subtitle,
    required String body,
    Map<String, Object?>? metadata,
  }) async {
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => Dialog(
            child: SizedBox(
              width: 820,
              height: 640,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: Theme.of(ctx).textTheme.titleLarge,
                              ),
                              if (subtitle.isNotEmpty)
                                Text(
                                  subtitle,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              Text(
                                '${body.length} chars',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey[500],
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy to clipboard',
                          icon: const Icon(Icons.copy_outlined),
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: body));
                            if (ctx.mounted) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('Copied'),
                                  duration: Duration(seconds: 1),
                                ),
                              );
                            }
                          },
                        ),
                        IconButton(
                          tooltip: 'Save to file',
                          icon: const Icon(Icons.download_outlined),
                          onPressed: () => _saveToFile(ctx, title, body),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          body,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            fontFamily: 'ui-serif',
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (metadata != null && metadata.isNotEmpty) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'metadata: ${metadata.entries.map((e) => "${e.key}=${e.value}").join(" · ")}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
    );
  }

  Future<void> _saveToFile(BuildContext ctx, String name, String body) async {
    try {
      final sanitized = name.replaceAll(RegExp(r'[^\w\-./]'), '_');
      final dir = '${Platform.environment['HOME']}/Downloads';
      final path =
          '$dir/makemind-fact-$sanitized-'
          '${DateTime.now().millisecondsSinceEpoch}.txt';
      await File(path).writeAsString(body);
      if (ctx.mounted) {
        ScaffoldMessenger.of(
          ctx,
        ).showSnackBar(SnackBar(content: Text('Saved: $path')));
      }
    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(
          ctx,
        ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
  }

  Future<void> _showFactSaveDialog() async {
    final catCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    final valueCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Save fact'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: catCtrl,
                    decoration: const InputDecoration(
                      labelText: 'category (e.g. contact · policy)',
                    ),
                  ),
                  TextField(
                    controller: keyCtrl,
                    decoration: const InputDecoration(labelText: 'key'),
                  ),
                  TextField(
                    controller: valueCtrl,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      labelText: 'value',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  if (catCtrl.text.trim().isEmpty ||
                      keyCtrl.text.trim().isEmpty ||
                      valueCtrl.text.isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('category, key, and value are required'),
                      ),
                    );
                    return;
                  }
                  try {
                    await ref
                        .read(knowledgeInitProvider)
                        .registries
                        .knowledge
                        .saveFact(
                          category: catCtrl.text.trim(),
                          key: keyCtrl.text.trim(),
                          value: valueCtrl.text,
                        );
                    if (context.mounted) Navigator.pop(ctx);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('Save failed: $e')),
                      );
                    }
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
    );
  }
}

// --- Files ---

class _FilesTab extends ConsumerStatefulWidget {
  const _FilesTab({required this.wsId});
  final String wsId;

  @override
  ConsumerState<_FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends ConsumerState<_FilesTab> {
  List<KnowledgeFileEntry> _entries = const [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant _FilesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wsId != widget.wsId) _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final init = ref.read(knowledgeInitProvider);
      final list = await init.registries.knowledge.listFiles(widget.wsId);
      if (!mounted) return;
      setState(() => _entries = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Knowledge files · ${widget.wsId}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _reload,
                tooltip: 'Refresh',
              ),
              FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('New file'),
                onPressed:
                    () => _showEditor(
                      relativePath: 'knowledge/new-note.md',
                      initialContent: '',
                      title: 'New file',
                    ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child:
              _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(child: Text('Error: $_error'))
                  : _entries.isEmpty
                  ? const Center(child: Text('No files under knowledge/'))
                  : ListView.separated(
                    itemCount: _entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _fileTile(_entries[i]),
                  ),
        ),
      ],
    );
  }

  Widget _fileTile(KnowledgeFileEntry e) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(e.relativePath),
      subtitle: Text(
        '${e.size} bytes · ${e.modifiedAt.toIso8601String()}',
        style: const TextStyle(fontSize: 11),
      ),
      onTap: () async {
        try {
          final content = await ref
              .read(knowledgeInitProvider)
              .registries
              .knowledge
              .readFile(widget.wsId, e.relativePath);
          if (!mounted) return;
          await _showEditor(
            relativePath: e.relativePath,
            initialContent: content,
            title: 'Edit file · ${e.relativePath}',
            canRename: false,
          );
        } catch (err) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Read failed: $err')));
        }
      },
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, color: Colors.red),
        tooltip: 'Delete',
        onPressed: () async {
          final confirmed = await showDialog<bool>(
            context: context,
            builder:
                (ctx) => AlertDialog(
                  title: const Text('Delete file'),
                  content: Text(e.relativePath),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
          );
          if (confirmed == true) {
            await ref
                .read(knowledgeInitProvider)
                .registries
                .knowledge
                .deleteFile(widget.wsId, e.relativePath);
            _reload();
          }
        },
      ),
    );
  }

  Future<void> _showEditor({
    required String relativePath,
    required String initialContent,
    required String title,
    bool canRename = true,
  }) async {
    final pathCtrl = TextEditingController(text: relativePath);
    final contentCtrl = TextEditingController(text: initialContent);
    await showDialog<void>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 680,
              height: 500,
              child: Column(
                children: [
                  TextField(
                    controller: pathCtrl,
                    enabled: canRename,
                    decoration: const InputDecoration(
                      labelText: 'path (must start with knowledge/)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      controller: contentCtrl,
                      maxLines: null,
                      expands: true,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    await ref
                        .read(knowledgeInitProvider)
                        .registries
                        .knowledge
                        .writeFile(
                          widget.wsId,
                          pathCtrl.text.trim(),
                          contentCtrl.text,
                        );
                    if (context.mounted) Navigator.pop(ctx);
                    _reload();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('Save failed: $e')),
                      );
                    }
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
    );
  }
}

// --- Ingest ---

class _IngestTab extends ConsumerStatefulWidget {
  const _IngestTab({required this.wsId});
  final String wsId;

  @override
  ConsumerState<_IngestTab> createState() => _IngestTabState();
}

class _IngestTabState extends ConsumerState<_IngestTab> {
  String? _result;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            icon: const Icon(Icons.upload_file),
            label: const Text('Ingest by file path'),
            onPressed: _loading ? null : _ingestFile,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child:
                  _loading
                      ? const Center(child: CircularProgressIndicator())
                      : Text(
                        _result ?? 'Document ingest progress will appear here.',
                      ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _ingestFile() async {
    final pathCtrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('Path of file to upload'),
            content: TextField(controller: pathCtrl),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, pathCtrl.text),
                child: const Text('OK'),
              ),
            ],
          ),
    );
    if (path == null || path.isEmpty) return;

    setState(() => _loading = true);
    try {
      // Wire to the host-backed `knowledge_ingest_file` tool (host `ingest.*`
      // chunking + flowbrain FactFacade) — the UI calls the tool, no engine.
      final res = await opsCallTool(
        ref,
        'knowledge_ingest_file',
        <String, dynamic>{'path': path, 'category': 'reference'},
      );
      if (mounted) {
        setState(
          () => _result = 'Ingested: ${res['fragmentsEmitted'] ?? 0} fragments',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _result = 'Ingest error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }
}
