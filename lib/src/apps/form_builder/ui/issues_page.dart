import 'dart:convert' show JsonEncoder, jsonDecode;
import 'dart:io';

import 'package:appplayer_form_view/appplayer_form_view.dart';
import 'package:appplayer_studio/base.dart' show VibeTokens, vibeMono;
import 'package:flutter/material.dart';
import 'package:mcp_bundle/mcp_bundle.dart'
    show FormDocument, FormDocumentMetadata, FormSection;
import 'package:path/path.dart' as p;

import '../../../ui/atoms/vbu_document_viewer.dart';
import '../init/form_init.dart';

const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

/// Issued snapshots — the immutable record, managed for scale:
///   - search (issue number / recipient-ish content / templateId),
///   - superseded snapshots dim behind a "current only" toggle,
///   - tap = DOCUMENT view (the as-issued markdown artifact rendered in the
///     Studio viewer kit; frozen values as fallback for pre-markdown issues),
///   - "correct & reissue" hands the snapshot to Compose with `supersedes`
///     pre-set (corrections never edit an issue).
class IssuesPage extends StatefulWidget {
  const IssuesPage({
    super.key,
    required this.init,
    this.onCorrect,
    this.landingIssueId,
  });

  final FormInit init;

  /// Issues → Compose handoff (shell wires the route switch + prefill).
  final void Function(Map<String, dynamic> issue)? onCorrect;

  /// Deep-link focus (`studio.app.open … route:issues entity:<issueId>`):
  /// the issue whose detail opens once the list loads. One-shot.
  final String? landingIssueId;

  @override
  State<IssuesPage> createState() => _IssuesPageState();
}

class _IssuesPageState extends State<IssuesPage> {
  late Future<List<Map<String, dynamic>>> _issues;
  final TextEditingController _search = TextEditingController();
  bool _currentOnly = false;
  bool _landed = false;

  @override
  void initState() {
    super.initState();
    _issues = widget.init.listIssues();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _refresh() {
    // Block body — an arrow closure would return the Future and trip the
    // setState assert (see templates_page._refresh).
    final next = widget.init.listIssues();
    setState(() {
      _issues = next;
    });
  }

  bool _matches(Map<String, dynamic> issue, String q) {
    if (q.isEmpty) return true;
    final hay = StringBuffer()
      ..write(issue['issueNumber'] ?? '')
      ..write(' ')
      ..write(issue['issueId'] ?? '')
      ..write(' ')
      ..write(issue['templateId'] ?? '')
      ..write(' ')
      ..write(((issue['content'] as Map?)?['data'] ?? '').toString());
    return hay.toString().toLowerCase().contains(q.toLowerCase());
  }

  Future<void> _detail(
    Map<String, dynamic> issue, {
    required bool superseded,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _IssueDetailDialog(
        issue: issue,
        superseded: superseded,
        projectRoot: widget.init.projectRoot,
        onCorrect: widget.onCorrect == null
            ? null
            : () {
                Navigator.of(ctx).pop();
                widget.onCorrect!(issue);
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
          child: Row(
            children: [
              Text('Issues', style: theme.textTheme.titleLarge),
              const SizedBox(width: 16),
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'number · content · template…',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilterChip(
                label: const Text('current only'),
                selected: _currentOnly,
                onSelected: (v) => setState(() => _currentOnly = v),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Reload',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _issues,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(child: Text('${snap.error}'));
              }
              final all = snap.data;
              if (all == null) {
                return const Center(child: CircularProgressIndicator());
              }
              if (all.isEmpty) {
                return const Center(
                  child: Text('Nothing issued yet — compose and Issue.'),
                );
              }
              // An issue is superseded when a NEWER issue names it.
              final supersededIds = <String>{
                for (final i in all)
                  if (i['supersedes'] != null) i['supersedes'] as String,
              };
              // Deep-link landing: open the linked issue's detail once.
              final landing = widget.landingIssueId;
              if (!_landed && landing != null) {
                _landed = true;
                for (final i in all) {
                  if (i['issueId'] == landing) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _detail(
                          i,
                          superseded: supersededIds.contains(landing),
                        );
                      }
                    });
                    break;
                  }
                }
              }
              final q = _search.text.trim();
              final items = [
                for (final i in all)
                  if (_matches(i, q) &&
                      (!_currentOnly ||
                          !supersededIds.contains(i['issueId'])))
                    i,
              ];
              if (items.isEmpty) {
                return const Center(child: Text('No match.'));
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final issue = items[index];
                  final superseded = supersededIds.contains(issue['issueId']);
                  final artifacts =
                      ((issue['artifacts'] as List?) ?? const [])
                          .cast<Map>()
                          .map((a) => a['format'])
                          .join(' · ');
                  return Opacity(
                    opacity: superseded ? 0.55 : 1,
                    child: Card(
                      child: ListTile(
                        leading: Icon(
                          superseded
                              ? Icons.history_toggle_off
                              : Icons.verified_outlined,
                        ),
                        title: Row(
                          children: [
                            Text(
                              '${issue['issueNumber']}  ·  '
                              '${issue['templateId'] ?? '?'}',
                            ),
                            if (superseded) ...[
                              const SizedBox(width: 8),
                              const Chip(
                                visualDensity: VisualDensity.compact,
                                label: Text('superseded'),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          '${issue['issuedAt'] ?? ''}'
                          '${issue['issuedBy'] != null ? ' · by ${issue['issuedBy']}' : ''}'
                          '${issue['supersedes'] != null ? ' · corrects ${issue['supersedes']}' : ''}'
                          '\n$artifacts',
                        ),
                        isThreeLine: true,
                        onTap: () => _detail(issue, superseded: superseded),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _IssueDetailDialog extends StatelessWidget {
  const _IssueDetailDialog({
    required this.issue,
    required this.superseded,
    required this.projectRoot,
    this.onCorrect,
  });

  final Map<String, dynamic> issue;
  final bool superseded;
  final String projectRoot;
  final VoidCallback? onCorrect;

  String? _artifactPath(String format) {
    for (final a in ((issue['artifacts'] as List?) ?? const []).cast<Map>()) {
      if (a['format'] == format) {
        return p.join(projectRoot, a['locator'] as String);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The as-issued document view, best first: the TYPED formdoc snapshot
    // (template sections at the issued version + patch-true table rows —
    // image sizes/placement exact); then the frozen uiDsl adapted back
    // (older issues; images lose maxWidth/placement to an engine
    // serialisation gap); then markdown; then the frozen field values.
    FormDocument? formDoc;
    final formdocPath = _artifactPath('formdoc');
    if (formdocPath != null) {
      try {
        final decoded = jsonDecode(File(formdocPath).readAsStringSync());
        if (decoded is Map) {
          final snap = decoded.cast<String, dynamic>();
          formDoc = FormDocument(
            documentId: '${issue['documentId'] ?? 'issued'}',
            templateId: '${snap['templateId']}',
            templateVersion: '${snap['templateVersion'] ?? '0'}',
            metadata: FormDocumentMetadata(
              author: '${issue['issuedBy'] ?? 'issued'}',
              createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            ),
            sections: ((snap['sections'] as List?) ?? const [])
                .whereType<Map>()
                .map((m) => FormSection.fromJson(m.cast<String, dynamic>()))
                .toList(),
            data: (snap['data'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{},
          );
        }
      } catch (_) {
        formDoc = null;
      }
    }
    if (formDoc == null) {
      final uiPath = _artifactPath('uiDsl');
      if (uiPath != null) {
        try {
          final decoded = jsonDecode(File(uiPath).readAsStringSync());
          if (decoded is Map) {
            formDoc = formDocumentFromUiDsl(
              decoded.cast<String, dynamic>(),
              templateId: '${issue['templateId']}',
              templateVersion: '${issue['templateVersion'] ?? '0'}',
            );
          }
        } catch (_) {
          formDoc = null;
        }
      }
    }
    final mdPath = _artifactPath('markdown');
    String? mdText;
    if (mdPath != null) {
      try {
        mdText = File(mdPath).readAsStringSync();
      } catch (_) {
        mdText = null;
      }
    }
    final data =
        ((issue['content'] as Map?)?['data'] as Map?)?.cast<String, dynamic>();
    final issueDir = p.join(
      projectRoot,
      'forms',
      issue['issueNumber'] as String? ?? '',
    );

    return AlertDialog(
      title: Row(
        children: [
          Text('Issue ${issue['issueNumber']}'),
          if (superseded) ...[
            const SizedBox(width: 8),
            const Chip(
              visualDensity: VisualDensity.compact,
              label: Text('superseded'),
            ),
          ],
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${issue['templateId']} v${issue['templateVersion'] ?? '?'}'
              ' · ${issue['issuedAt'] ?? ''}'
              '${issue['issuedBy'] != null ? ' · by ${issue['issuedBy']}' : ''}'
              '${issue['supersedes'] != null ? ' · corrects ${issue['supersedes']}' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            // B3 artifact journey — the path this document travelled, from
            // the frozen provenance: request → each approval gate → issue
            // (+ correction link). Renders only when a trail exists.
            _JourneyStrip(issue: issue),
            const SizedBox(height: 8),
            Expanded(
              child: formDoc != null
                  ? FormView(document: formDoc, imageBaseDir: projectRoot)
                  : mdText != null
                  ? VbuDocumentViewer(
                      path: 'issue-${issue['issueNumber']}.md',
                      text: mdText,
                    )
                  : data != null
                  ? SingleChildScrollView(
                      child: SelectableText(
                        _pretty.convert(data),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    )
                  : const Center(child: Text('No viewable content')),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final a
                    in ((issue['artifacts'] as List?) ?? const []).cast<Map>())
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('${a['format']}'),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.folder_open, size: 16),
                  label: const Text('open folder'),
                  onPressed: () {
                    // Desktop convenience — reveal the frozen artifacts.
                    if (Platform.isMacOS) {
                      Process.run('open', [issueDir]);
                    } else if (Platform.isWindows) {
                      Process.run('explorer', [issueDir]);
                    } else {
                      Process.run('xdg-open', [issueDir]);
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        if (onCorrect != null)
          OutlinedButton.icon(
            onPressed: onCorrect,
            icon: const Icon(Icons.published_with_changes, size: 18),
            label: const Text('Correct & reissue'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Artifact journey (B3): a one-line chip trail — requested(requestedBy) →
/// each approval gate as-signed (● approved / ✕ rejected / ⤵ skipped,
/// with actor and time) → issued(issuedBy) → correction link. Built purely
/// from the provenance frozen INTO the issue fact; hidden when the
/// document was issued without an approval.
class _JourneyStrip extends StatelessWidget {
  const _JourneyStrip({required this.issue});

  final Map<String, dynamic> issue;

  static String _hhmm(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (t == null) return '';
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final approval = (issue['approval'] as Map?)?.cast<String, dynamic>();
    if (approval == null) return const SizedBox(height: 4);
    final line = ((approval['line'] as List?) ?? const []).cast<Map>();
    final c = VibeTokens.colorOf(context);
    Widget node(String text, {Color? color}) => Chip(
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          side: color == null
              ? null
              : BorderSide(color: color.withValues(alpha: 0.7)),
          label: Text(
            text,
            style: vibeMono(size: 11, color: color ?? c.textSecondary),
          ),
        );
    Widget arrow() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text('→', style: vibeMono(size: 11, color: c.textMuted)),
        );
    final children = <Widget>[
      node(
        'requested ${approval['requestedBy']}'
        ' ${_hhmm(approval['requestedAt'])}',
      ),
      for (final g in line) ...[
        arrow(),
        node(
          '${switch (g['status']) {
            'approved' => '●',
            'rejected' => '✕',
            'skipped' => '⤵',
            _ => '○',
          }} ${g['approverId']}'
          '${g['actedAt'] != null ? ' ${_hhmm(g['actedAt'])}' : ''}',
          color: switch (g['status']) {
            'approved' => c.mint,
            'rejected' => c.coral,
            'skipped' => c.textMuted,
            _ => c.amber,
          },
        ),
      ],
      arrow(),
      node(
        'issued ${issue['issuedBy'] ?? ''} ${_hhmm(issue['issuedAt'])}'.trim(),
        color: c.mint,
      ),
      if (issue['supersedes'] != null) ...[
        arrow(),
        node('corrects ${issue['supersedes']}'),
      ],
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: children),
      ),
    );
  }
}
