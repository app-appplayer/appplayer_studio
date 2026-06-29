/// Ops **Files** route — browse and (for text formats) edit the bound project's
/// files in the Studio viewer kit ([VbuDocumentPanel] + [VbuDocumentViewer]).
///
/// The kit widgets are data-injected (no filesystem access of their own); this
/// page is the host that feeds them — listing / reading / writing the project
/// directory. Ops is host-privileged code operating its own bound project, so
/// it reaches the project tree directly (the jailed `fs.*` capability is rooted
/// at the config datastore, not the project). Browsing is confined to the
/// project root (Up clamps there). The first consumer of the viewer kit; App
/// Builder / Scene Builder can embed the same panel.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../ui/atoms/vbu_document_panel.dart';
import '../../../../ui/atoms/vbu_document_viewer.dart';
import '../../state/providers.dart';
import '../../theme/tokens.dart';

class FilesPage extends ConsumerStatefulWidget {
  const FilesPage({super.key});

  @override
  ConsumerState<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends ConsumerState<FilesPage> {
  String _root = '';
  String? _dir;
  List<VbuFileEntry> _entries = const [];

  void _list(String dir) {
    final out = <VbuFileEntry>[];
    try {
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue; // hide dotfiles
        out.add(VbuFileEntry(
          name: name,
          path: e.path,
          isDir: e is Directory,
        ));
      }
    } catch (_) {
      /* unreadable dir → empty */
    }
    out.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    setState(() {
      _dir = dir;
      _entries = out;
    });
  }

  Future<({String? text, Uint8List? bytes})> _load(VbuFileEntry e) async {
    final file = File(e.path);
    switch (vbuDocKindForPath(e.name)) {
      case VbuDocKind.image:
        return (text: null, bytes: await file.readAsBytes());
      case VbuDocKind.markdown:
      case VbuDocKind.code:
        return (text: await file.readAsString(), bytes: null);
      case VbuDocKind.pdf:
      case VbuDocKind.binary:
        return (text: null, bytes: null);
    }
  }

  Future<void> _save(VbuFileEntry e, String text) async {
    await File(e.path).writeAsString(text);
  }

  @override
  Widget build(BuildContext context) {
    final root = ref.watch(knowledgeInitProvider).projectRoot;
    if (root.isEmpty) {
      return Center(
        child: Text(
          'No project bound — open a project to browse its files.',
          style: TextStyle(color: OpsColors.text2),
        ),
      );
    }
    // Re-root when the bound project changes.
    if (_root != root) {
      _root = root;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _list(root);
      });
    }
    final dir = _dir ?? root;
    final rel = p.relative(dir, from: root);
    final atRoot = p.equals(dir, root);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Files', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Browse and edit this project\'s documents — Markdown renders, '
            'text / code / data are editable and saved in place, images preview. '
            'PDF preview is on the way.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: OpsColors.text2),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: VbuDocumentPanel(
              entries: _entries,
              breadcrumb: atRoot ? '/' : rel,
              onLoad: _load,
              onSave: _save,
              onEnterDir: (e) => _list(e.path),
              onUp: atRoot ? null : () => _list(p.dirname(dir)),
              onRefresh: () => _list(dir),
            ),
          ),
        ],
      ),
    );
  }
}
