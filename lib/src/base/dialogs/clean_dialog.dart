// Clean build artifacts dialog — mirrors `showBuildDialog` for the
// destructive side. Lists every existing `<projectPath>/build/<target>/`
// directory with its size, lets the user pick one (or "all"), and
// returns the selection. Caller dispatches to `proj.cleanBuild`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:appplayer_studio/base.dart';

/// Selection from [showCleanDialog]. `target == null` means "wipe the
/// entire `build/` directory"; otherwise just `build/<target>/`.
class CleanRequest {
  const CleanRequest({required this.target});
  final String? target;
}

/// One entry in the dialog's target list — discovered subdir under
/// `<projectPath>/build/`.
class _CleanEntry {
  _CleanEntry({
    required this.target,
    required this.path,
    required this.bytes,
    required this.fileCount,
  });
  final String target;
  final String path;
  final int bytes;
  final int fileCount;

  String get sizeLabel {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

Future<CleanRequest?> showCleanDialog(
  BuildContext context, {
  required String projectPath,
  String? lastTarget,
}) async {
  final entries = await _scanBuildDir(projectPath);
  if (!context.mounted) return null;
  return showDialog<CleanRequest?>(
    context: context,
    builder: (ctx) => _CleanDialog(entries: entries, lastTarget: lastTarget),
  );
}

Future<List<_CleanEntry>> _scanBuildDir(String projectPath) async {
  final root = Directory(p.join(projectPath, 'build'));
  if (!await root.exists()) return const <_CleanEntry>[];
  final out = <_CleanEntry>[];
  await for (final entity in root.list(followLinks: false)) {
    if (entity is! Directory) continue;
    var bytes = 0;
    var count = 0;
    try {
      await for (final inner in entity.list(
        recursive: true,
        followLinks: false,
      )) {
        if (inner is File) {
          try {
            bytes += (await inner.stat()).size;
            count++;
          } catch (_) {
            /* skip unreadable */
          }
        }
      }
    } catch (_) {
      /* skip dirs we can't enumerate */
    }
    out.add(
      _CleanEntry(
        target: p.basename(entity.path),
        path: entity.path,
        bytes: bytes,
        fileCount: count,
      ),
    );
  }
  out.sort((a, b) => a.target.compareTo(b.target));
  return out;
}

class _CleanDialog extends StatefulWidget {
  const _CleanDialog({required this.entries, this.lastTarget});
  final List<_CleanEntry> entries;
  final String? lastTarget;

  @override
  State<_CleanDialog> createState() => _CleanDialogState();
}

class _CleanDialogState extends State<_CleanDialog> {
  /// `null` = "all". String = specific target.
  String? _selected;

  @override
  void initState() {
    super.initState();
    final last = widget.lastTarget;
    if (last != null && widget.entries.any((e) => e.target == last)) {
      _selected = last;
    } else if (widget.entries.length == 1) {
      _selected = widget.entries.first.target;
    } else {
      _selected = null; // default to "all" when nothing else specified
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final entries = widget.entries;
    final totalBytes = entries.fold<int>(0, (sum, e) => sum + e.bytes);
    return Dialog(
      backgroundColor: c.surface2,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: SizedBox(
        width: 480,
        child: Padding(
          padding: const EdgeInsets.all(VibeTokens.space4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.cleaning_services_outlined,
                    size: 18,
                    color: c.coral,
                  ),
                  const SizedBox(width: VibeTokens.space2),
                  Text(
                    'Clean build artifacts',
                    style: TextStyle(
                      fontFamily: VibeTokens.fontSans,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: VibeTokens.space2),
              Text(
                'Deletes the chosen target\'s output. Source files '
                '(bundles, prefs, history) are not touched. No undo.',
                style: vibeMono(size: 10, color: c.textTertiary),
              ),
              const SizedBox(height: VibeTokens.space3),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Nothing to clean — `build/` is empty or missing.',
                    style: vibeMono(size: 11, color: c.textTertiary),
                  ),
                )
              else ...<Widget>[
                _RadioRow(
                  selected: _selected == null,
                  title: 'All targets',
                  subtitle:
                      'Wipe the entire `build/` directory '
                      '(${entries.length} target${entries.length == 1 ? '' : 's'}, '
                      '${_formatBytes(totalBytes)})',
                  onTap: () => setState(() => _selected = null),
                ),
                Divider(color: c.borderSubtle, height: 1),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final entry in entries)
                          _RadioRow(
                            selected: _selected == entry.target,
                            title: entry.target,
                            subtitle:
                                '${entry.fileCount} file${entry.fileCount == 1 ? '' : 's'} · '
                                '${entry.sizeLabel}',
                            onTap:
                                () => setState(() => _selected = entry.target),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: VibeTokens.space4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  inspectTag(
                    type: 'dialog_action',
                    id: 'clean.cancel',
                    label: 'Cancel',
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: VibeTokens.space2),
                  inspectTag(
                    type: 'dialog_action',
                    id: 'clean.confirm',
                    label: 'Clean',
                    child: FilledButton.tonal(
                      onPressed:
                          entries.isEmpty
                              ? null
                              : () => Navigator.of(
                                context,
                              ).pop(CleanRequest(target: _selected)),
                      style: FilledButton.styleFrom(
                        backgroundColor: c.coral.withValues(alpha: 0.18),
                        foregroundColor: c.coral,
                      ),
                      child: const Text('Clean'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 16,
              color: selected ? c.mint : c.textSecondary,
            ),
            const SizedBox(width: VibeTokens.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: VibeTokens.fontMono,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: vibeMono(size: 10, color: c.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
