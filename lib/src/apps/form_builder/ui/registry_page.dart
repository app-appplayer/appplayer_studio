/// Document REGISTRY (문서대장) — the finding/browsing surface for issued
/// documents at organisational scale. Not a longer list: a ledger.
///
/// Left: FACETS derived entirely from existing records (year/month from
/// the issue number + issuedAt, form = templateId, status =
/// current/correction/superseded, approval MARK presence, recipient =
/// the document's key field value). Right: a sortable ledger table with
/// month sections. Approval is shown as a mark only — the acting/waiting
/// process lives in Ops and arrives here through the `studio.app.open`
/// deep link. Design: `docs/form_builder/document-registry.md`.
library;

import 'package:flutter/material.dart';
import 'package:appplayer_studio/base.dart' show VibeTokens, vibeMono;

import '../init/form_init.dart';
import 'issues_page.dart' show IssueDetailDialog;

enum _SortBy { number, date, form, recipient, issuedBy }

class RegistryPage extends StatefulWidget {
  const RegistryPage({
    super.key,
    required this.init,
    this.onCorrect,
    this.landingIssueId,
  });

  final FormInit init;

  /// Registry → Compose correction handoff (shell wires the route switch).
  final void Function(Map<String, dynamic> issue)? onCorrect;

  /// Deep-link focus: the issue whose detail opens once the ledger loads.
  final String? landingIssueId;

  @override
  State<RegistryPage> createState() => _RegistryPageState();
}

/// One ledger row, with its facet keys precomputed.
class _Entry {
  _Entry(this.issue, {required this.superseded});

  final Map<String, dynamic> issue;
  final bool superseded;

  String get number => '${issue['issueNumber'] ?? ''}';
  String get year =>
      number.contains('-') ? number.split('-').first : 'unknown';
  String get form => '${issue['templateId'] ?? '?'}';
  String get issuedBy => '${issue['issuedBy'] ?? ''}';
  String get issuedAt => '${issue['issuedAt'] ?? ''}';
  String get month =>
      issuedAt.length >= 7 ? issuedAt.substring(0, 7) : year;
  bool get isCorrection => issue['supersedes'] != null;
  bool get hasApproval => issue['approval'] != null;

  /// current | correction | superseded — superseded wins (a newer issue
  /// replaced this one), else correction (this one replaced an older).
  String get status =>
      superseded ? 'superseded' : (isCorrection ? 'correction' : 'current');

  /// The document's representative value (the "recipient" ledger column).
  /// Preference order: the keyValue FROZEN at issue time (stable against
  /// template evolution) → the stamped keyField resolved over the frozen
  /// data → the first field of the frozen data (pre-stamp issues).
  String get recipient {
    final stamped = issue['keyValue'];
    if (stamped is String && stamped.isNotEmpty) return stamped;
    final data = ((issue['content'] as Map?)?['data'] as Map?) ?? const {};
    if (data.isEmpty) return '';
    final key = issue['keyField'];
    if (key is String && data[key] != null) return '${data[key]}';
    return '${data.values.first}';
  }
}

class _RegistryPageState extends State<RegistryPage> {
  List<_Entry> _all = const [];
  bool _loading = true;
  bool _landed = false;

  // Facet selections — null = all. Single-select toggles per axis.
  String? _year;
  String? _form;
  String? _status;
  bool? _approval;
  String? _recipient;

  final TextEditingController _search = TextEditingController();
  _SortBy _sortBy = _SortBy.number;
  bool _ascending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await widget.init.listIssues();
    final supersededIds = <String>{
      for (final i in all)
        if (i['supersedes'] != null) i['supersedes'] as String,
    };
    if (!mounted) return;
    setState(() {
      _all = [
        for (final i in all)
          _Entry(i, superseded: supersededIds.contains(i['issueId'])),
      ];
      _loading = false;
    });
    _maybeLand();
  }

  void _maybeLand() {
    final landing = widget.landingIssueId;
    if (_landed || landing == null) return;
    _landed = true;
    for (final e in _all) {
      if (e.issue['issueId'] == landing) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _detail(e);
        });
        break;
      }
    }
  }

  Future<void> _detail(_Entry e) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => IssueDetailDialog(
        issue: e.issue,
        superseded: e.superseded,
        projectRoot: widget.init.projectRoot,
        onCorrect: widget.onCorrect == null
            ? null
            : () {
                Navigator.of(ctx).pop();
                widget.onCorrect!(e.issue);
              },
      ),
    );
  }

  List<_Entry> get _filtered {
    final q = _search.text.trim().toLowerCase();
    return [
      for (final e in _all)
        if ((_year == null || e.year == _year) &&
            (_form == null || e.form == _form) &&
            (_status == null || e.status == _status) &&
            (_approval == null || e.hasApproval == _approval) &&
            (_recipient == null || e.recipient == _recipient) &&
            (q.isEmpty ||
                '${e.number} ${e.form} ${e.recipient} ${e.issuedBy} '
                        '${(e.issue['content'] as Map?)?['data'] ?? ''}'
                    .toLowerCase()
                    .contains(q)))
          e,
    ];
  }

  List<_Entry> _sorted(List<_Entry> list) {
    int cmp(_Entry a, _Entry b) => switch (_sortBy) {
          _SortBy.number => a.number.compareTo(b.number),
          _SortBy.date => a.issuedAt.compareTo(b.issuedAt),
          _SortBy.form => a.form.compareTo(b.form),
          _SortBy.recipient => a.recipient.compareTo(b.recipient),
          _SortBy.issuedBy => a.issuedBy.compareTo(b.issuedBy),
        };
    final out = [...list]..sort(cmp);
    return _ascending ? out : out.reversed.toList();
  }

  Map<String, int> _counts(String Function(_Entry) key) {
    final m = <String, int>{};
    for (final e in _all) {
      final k = key(e);
      if (k.isEmpty) continue;
      m[k] = (m[k] ?? 0) + 1;
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final c = VibeTokens.colorOf(context);
    final entries = _sorted(_filtered);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FacetPanel(
          years: _counts((e) => e.year),
          forms: _counts((e) => e.form),
          statuses: _counts((e) => e.status),
          approvals: {
            'marked': _all.where((e) => e.hasApproval).length,
            'none': _all.where((e) => !e.hasApproval).length,
          },
          recipients: _counts((e) => e.recipient),
          year: _year,
          form: _form,
          status: _status,
          approval: _approval,
          recipient: _recipient,
          onYear: (v) => setState(() => _year = v),
          onForm: (v) => setState(() => _form = v),
          onStatus: (v) => setState(() => _status = v),
          onApproval: (v) => setState(() => _approval = v),
          onRecipient: (v) => setState(() => _recipient = v),
        ),
        VerticalDivider(width: 1, color: c.borderSubtle),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Text(
                      'Registry',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${_year ?? 'all years'} · ${entries.length} of '
                      '${_all.length} issued',
                      style: vibeMono(size: 11, color: c.textTertiary),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: 'number · content · form…',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Reload',
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
              _HeaderRow(
                sortBy: _sortBy,
                ascending: _ascending,
                onSort: (by) => setState(() {
                  if (_sortBy == by) {
                    _ascending = !_ascending;
                  } else {
                    _sortBy = by;
                    _ascending = by != _SortBy.number && by != _SortBy.date;
                  }
                }),
              ),
              Divider(height: 1, color: c.borderSubtle),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('No documents match.'))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, i) {
                          final e = entries[i];
                          final grouped = _sortBy == _SortBy.number ||
                              _sortBy == _SortBy.date;
                          final header = grouped &&
                              (i == 0 || entries[i - 1].month != e.month);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (header)
                                Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(16, 12, 16, 4),
                                  child: Text(
                                    e.month,
                                    style: vibeMono(
                                      size: 11,
                                      color: c.textTertiary,
                                    ).copyWith(letterSpacing: 1.2),
                                  ),
                                ),
                              _Row(entry: e, onTap: () => _detail(e)),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FacetPanel extends StatelessWidget {
  const _FacetPanel({
    required this.years,
    required this.forms,
    required this.statuses,
    required this.approvals,
    required this.recipients,
    required this.year,
    required this.form,
    required this.status,
    required this.approval,
    required this.recipient,
    required this.onYear,
    required this.onForm,
    required this.onStatus,
    required this.onApproval,
    required this.onRecipient,
  });

  final Map<String, int> years;
  final Map<String, int> forms;
  final Map<String, int> statuses;
  final Map<String, int> approvals;
  final Map<String, int> recipients;
  final String? year;
  final String? form;
  final String? status;
  final bool? approval;
  final String? recipient;
  final ValueChanged<String?> onYear;
  final ValueChanged<String?> onForm;
  final ValueChanged<String?> onStatus;
  final ValueChanged<bool?> onApproval;
  final ValueChanged<String?> onRecipient;

  static List<MapEntry<String, int>> _top(Map<String, int> m, [int n = 8]) {
    final list = m.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list.take(n).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
          child: Text(
            title,
            style: vibeMono(size: 10, color: c.textMuted)
                .copyWith(letterSpacing: 1.4),
          ),
        );
    Widget row(
      String label,
      int count, {
      required bool selected,
      required VoidCallback onTap,
    }) =>
        InkWell(
          onTap: onTap,
          child: Container(
            color: selected ? c.mint.withValues(alpha: 0.10) : null,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: selected ? c.mint : c.textSecondary,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: vibeMono(size: 10, color: c.textMuted),
                ),
              ],
            ),
          ),
        );

    // Sorted axes: years desc (recent first), forms/recipients by volume.
    final yearKeys = years.keys.toList()..sort((a, b) => b.compareTo(a));
    return SizedBox(
      width: 210,
      child: ListView(
        children: [
          section('YEAR'),
          for (final y in yearKeys)
            row(y, years[y]!,
                selected: year == y,
                onTap: () => onYear(year == y ? null : y)),
          section('FORM'),
          for (final f in _top(forms))
            row(f.key, f.value,
                selected: form == f.key,
                onTap: () => onForm(form == f.key ? null : f.key)),
          section('STATUS'),
          for (final st in const ['current', 'correction', 'superseded'])
            if ((statuses[st] ?? 0) > 0)
              row(st, statuses[st]!,
                  selected: status == st,
                  onTap: () => onStatus(status == st ? null : st)),
          section('APPROVAL'),
          row('marked', approvals['marked'] ?? 0,
              selected: approval == true,
              onTap: () => onApproval(approval == true ? null : true)),
          row('none', approvals['none'] ?? 0,
              selected: approval == false,
              onTap: () => onApproval(approval == false ? null : false)),
          section('RECIPIENT'),
          for (final r in _top(recipients))
            row(r.key, r.value,
                selected: recipient == r.key,
                onTap: () =>
                    onRecipient(recipient == r.key ? null : r.key)),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.sortBy,
    required this.ascending,
    required this.onSort,
  });

  final _SortBy sortBy;
  final bool ascending;
  final ValueChanged<_SortBy> onSort;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    Widget head(String label, _SortBy by, int flex) => Expanded(
          flex: flex,
          child: InkWell(
            onTap: () => onSort(by),
            child: Row(
              children: [
                Text(
                  label,
                  style: vibeMono(
                    size: 10,
                    color: sortBy == by ? c.mint : c.textMuted,
                  ).copyWith(letterSpacing: 1.2),
                ),
                if (sortBy == by)
                  Icon(
                    ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 11,
                    color: c.mint,
                  ),
              ],
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          head('NUMBER', _SortBy.number, 3),
          head('FORM', _SortBy.form, 3),
          head('RECIPIENT', _SortBy.recipient, 4),
          head('ISSUED BY', _SortBy.issuedBy, 2),
          head('DATE', _SortBy.date, 3),
          SizedBox(
            width: 120,
            child: Text(
              'STATUS · APPROVAL',
              style: vibeMono(size: 10, color: c.textMuted)
                  .copyWith(letterSpacing: 1.2),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.entry, required this.onTap});

  final _Entry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final dim = entry.status == 'superseded';
    final statusColor = switch (entry.status) {
      'superseded' => c.textMuted,
      'correction' => c.amber,
      _ => c.mint,
    };
    final date = entry.issuedAt.length >= 16
        ? entry.issuedAt.substring(0, 16).replaceFirst('T', ' ')
        : entry.issuedAt;
    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: dim ? 0.55 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: c.borderSubtle.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  entry.number,
                  style: vibeMono(size: 12, color: c.textPrimary),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  entry.form,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: c.textSecondary),
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  entry.recipient,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: c.textPrimary),
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  entry.issuedBy,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: vibeMono(size: 11, color: c.textTertiary),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  date,
                  style: vibeMono(size: 11, color: c.textTertiary),
                ),
              ),
              SizedBox(
                width: 120,
                child: Row(
                  children: [
                    Text(
                      entry.status,
                      style: vibeMono(size: 10, color: statusColor),
                    ),
                    const Spacer(),
                    if (entry.hasApproval)
                      Tooltip(
                        message: 'approval marked',
                        child: Text(
                          '●',
                          style: TextStyle(fontSize: 11, color: c.mint),
                        ),
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
