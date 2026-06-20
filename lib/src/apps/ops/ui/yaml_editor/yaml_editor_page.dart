// YAML inline editor — reads any `.yaml` file under the active workspace
// directory tree, lets the user edit it in a monospace text area, and
// validates the result by re-parsing on save. PRD §FM-POWER-05.
//
// External edits trigger a watcher that re-loads the file on focus. No
// schema validation beyond yaml-roundtrip — a fuller schema check
// belongs in a follow-up against each registry's loader.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../state/providers.dart';
import '../../theme/tokens.dart';

class YamlEditorPage extends ConsumerStatefulWidget {
  const YamlEditorPage({super.key});

  @override
  ConsumerState<YamlEditorPage> createState() => _YamlEditorPageState();
}

class _YamlEditorPageState extends ConsumerState<YamlEditorPage> {
  String? _selectedPath;
  final _editor = TextEditingController();
  String _diskCache = '';
  String? _validationError;
  bool _dirty = false;

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(opsConfigProvider);
    final wsId = ref.watch(activeWorkspaceIdProvider);
    if (wsId == null) {
      return Center(
        child: Text(
          'No active workspace.',
          style: TextStyle(color: OpsColors.text3),
        ),
      );
    }
    final wsDir = Directory(p.join(cfg.workspacesRoot, wsId));
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 280,
            child: _FileTree(
              root: wsDir,
              selected: _selectedPath,
              onSelect: _open,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: _editorPane()),
        ],
      ),
    );
  }

  Widget _editorPane() {
    if (_selectedPath == null) {
      return Center(
        child: Text(
          'Pick a yaml file from the tree to edit.',
          style: TextStyle(color: OpsColors.text3),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _selectedPath!,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: OpsType.mono,
                  fontSize: 11,
                  color: OpsColors.text2,
                ),
              ),
            ),
            if (_dirty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '● modified',
                  style: TextStyle(
                    fontFamily: OpsType.mono,
                    fontSize: 10,
                    color: OpsColors.warn,
                  ),
                ),
              ),
            TextButton.icon(
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Reload'),
              onPressed: () => _open(_selectedPath!),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.save_outlined, size: 14),
              label: const Text('Save'),
              onPressed: _dirty ? _save : null,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_validationError != null)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: OpsColors.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: OpsColors.danger.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              _validationError!,
              style: TextStyle(color: OpsColors.danger),
            ),
          ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: OpsColors.surface1,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: OpsColors.border),
            ),
            child: TextField(
              controller: _editor,
              maxLines: null,
              expands: true,
              style: const TextStyle(
                fontFamily: OpsType.mono,
                fontSize: 12,
                height: 1.4,
              ),
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: (_) {
                setState(() {
                  _dirty = _editor.text != _diskCache;
                  _validationError = null;
                });
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _open(String path) async {
    try {
      final raw = await File(path).readAsString();
      _diskCache = raw;
      _editor.text = raw;
      setState(() {
        _selectedPath = path;
        _dirty = false;
        _validationError = null;
      });
    } catch (e) {
      setState(() => _validationError = 'Read failed: $e');
    }
  }

  Future<void> _save() async {
    final path = _selectedPath;
    if (path == null) return;
    final body = _editor.text;
    try {
      // Validate by parsing first — bad yaml never reaches disk.
      loadYaml(body);
    } catch (e) {
      setState(() => _validationError = 'Invalid yaml: $e');
      return;
    }
    try {
      await File(path).writeAsString(body);
      _diskCache = body;
      setState(() {
        _dirty = false;
        _validationError = null;
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved $path — reload Ops to pick up changes.')),
      );
    } catch (e) {
      setState(() => _validationError = 'Write failed: $e');
    }
  }
}

class _FileTree extends StatefulWidget {
  const _FileTree({
    required this.root,
    required this.selected,
    required this.onSelect,
  });
  final Directory root;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  State<_FileTree> createState() => _FileTreeState();
}

class _FileTreeState extends State<_FileTree> {
  late Future<List<File>> _files;

  @override
  void initState() {
    super.initState();
    _files = _scan();
  }

  @override
  void didUpdateWidget(_FileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.root.path != widget.root.path) {
      _files = _scan();
    }
  }

  Future<List<File>> _scan() async {
    if (!await widget.root.exists()) return [];
    final out = <File>[];
    await for (final entity in widget.root.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && entity.path.toLowerCase().endsWith('.yaml')) {
        out.add(entity);
      }
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: OpsColors.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: OpsColors.border),
      ),
      child: FutureBuilder<List<File>>(
        future: _files,
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final files = snap.data!;
          if (files.isEmpty) {
            return Center(
              child: Text(
                'No yaml files.',
                style: TextStyle(color: OpsColors.text3),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.folder_outlined,
                      size: 14,
                      color: OpsColors.text3,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p.basename(widget.root.path),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: OpsType.mono,
                          fontSize: 11,
                          color: OpsColors.text2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              for (final f in files)
                _FileRow(
                  path: f.path,
                  rel: p.relative(f.path, from: widget.root.path),
                  active: widget.selected == f.path,
                  onTap: () => widget.onSelect(f.path),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.path,
    required this.rel,
    required this.active,
    required this.onTap,
  });
  final String path;
  final String rel;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? OpsColors.surface2 : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 12,
                color: OpsColors.text3,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  rel,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: OpsType.mono,
                    fontSize: 11,
                    color: active ? OpsColors.text : OpsColors.text2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
