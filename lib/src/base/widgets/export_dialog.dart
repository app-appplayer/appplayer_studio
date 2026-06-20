import 'package:flutter/material.dart';

import 'package:appplayer_studio/base.dart';

/// User's choice for an export operation. Symmetric with
/// `ImportSelection` but without collision policy (target is a fresh
/// `.mbd`, so every picked id lands without conflict). When
/// `everything` is true the caller copies the channel directory
/// verbatim — no per-section filtering.
class ExportSelection {
  ExportSelection.everything()
    : everything = true,
      pages = const <String>{},
      templates = const <String>{},
      assets = const <String>{},
      includeDashboard = false,
      includeTheme = false,
      includeNavigation = false,
      includeManifestMeta = true;

  ExportSelection.partial({
    required this.pages,
    required this.templates,
    required this.assets,
    required this.includeDashboard,
    required this.includeTheme,
    required this.includeNavigation,
    this.includeManifestMeta = true,
  }) : everything = false;

  /// True when the user picked "Whole .mbd" — caller short-circuits
  /// to a directory copy instead of building a fresh bundle.
  final bool everything;
  final Set<String> pages;
  final Set<String> templates;
  final Set<String> assets;
  final bool includeDashboard;
  final bool includeTheme;
  final bool includeNavigation;

  /// Whether the manifest's identity fields (id / name / version /
  /// description / icon) are copied. Defaults true — most users
  /// exporting want the bundle to keep its identity. Turn off when
  /// extracting a portable subset for inclusion in a different app.
  final bool includeManifestMeta;

  bool get hasAnyPick =>
      everything ||
      pages.isNotEmpty ||
      templates.isNotEmpty ||
      assets.isNotEmpty ||
      includeDashboard ||
      includeTheme ||
      includeNavigation ||
      includeManifestMeta;
}

/// Pick what to export from a channel. Mirrors the import dialog's
/// shape so the two flows feel symmetric — same sections, same
/// quick-select bar, same auto-include behaviour for assets that
/// picked pages / templates depend on.
Future<ExportSelection?> showExportSelectionDialog({
  required BuildContext context,
  required String channelLabel,
  required LayerProjection source,
}) {
  final c = VibeTokens.colorOf(context);
  bool everything = true;
  final pickedPages = <String>{};
  final pickedTemplates = <String>{};
  final pickedAssets = <String>{};
  final excludedAutoAssets = <String>{};
  bool includeDashboard = false;
  bool includeTheme = false;
  bool includeNavigation = false;
  bool includeManifestMeta = true;

  final pageIds = source.pages.keys.toList()..sort();
  final templateIds = source.components.templates.keys.toList()..sort();
  final assetIds =
      source.assets.entries
          .map((e) => '${e['id'] ?? ''}')
          .where((id) => id.isNotEmpty)
          .toList()
        ..sort();
  final hasDashboard = source.dashboard != null;
  final hasTheme = (source.lookup('/ui/theme') is Map);
  final hasNavigation = source.navigation != null;

  return showDialog<ExportSelection?>(
    context: context,
    builder:
        (ctx) => Dialog(
          backgroundColor: c.surface2,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          child: StatefulBuilder(
            builder: (ctx, setLocal) {
              // Re-scan picked pages / templates / dashboard for
              // `bundle://<id>` references and auto-include those
              // assets — same algorithm the import dialog uses, just
              // pulling source data from the live projection instead of
              // a peek.
              final autoAssets = <String>{};
              for (final id in pickedPages) {
                final raw = source.pages[id]?.raw;
                if (raw != null) autoAssets.addAll(_collectAssetRefs(raw));
              }
              for (final id in pickedTemplates) {
                final tpl = source.components.templates[id];
                if (tpl != null) autoAssets.addAll(_collectAssetRefs(tpl));
              }
              if (includeDashboard && source.dashboard != null) {
                autoAssets.addAll(_collectAssetRefs(source.dashboard!.raw));
              }
              autoAssets.removeWhere(excludedAutoAssets.contains);
              autoAssets.removeWhere((id) => !assetIds.contains(id));
              final effectiveAssets = <String>{...pickedAssets, ...autoAssets};
              final hasAny =
                  !everything &&
                  (pickedPages.isNotEmpty ||
                      pickedTemplates.isNotEmpty ||
                      effectiveAssets.isNotEmpty ||
                      includeDashboard ||
                      includeTheme ||
                      includeNavigation ||
                      includeManifestMeta);

              Widget radioRow({
                required bool value,
                required String title,
                String? subtitle,
                VoidCallback? onTap,
              }) {
                return InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          value
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 16,
                          color: value ? c.mint : c.textSecondary,
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                title,
                                style: TextStyle(
                                  fontFamily: VibeTokens.fontSans,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: c.textPrimary,
                                ),
                              ),
                              if (subtitle != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    subtitle,
                                    style: vibeMono(
                                      size: 10,
                                      color: c.textTertiary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              Widget itemRow({
                required bool checked,
                required String label,
                required VoidCallback onTap,
              }) {
                return InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: VibeTokens.space2,
                      vertical: 4,
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          checked
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 14,
                          color: checked ? c.mint : c.textTertiary,
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        Expanded(
                          child: Text(
                            label,
                            style: vibeMono(size: 11, color: c.textPrimary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              Widget section(String title, List<Widget> children) {
                return Container(
                  margin: const EdgeInsets.only(bottom: VibeTokens.space2),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                    border: Border.all(color: c.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          VibeTokens.space2,
                          VibeTokens.space2,
                          VibeTokens.space2,
                          4,
                        ),
                        child: Text(
                          title,
                          style: vibeMono(size: 10, color: c.textSecondary),
                        ),
                      ),
                      ...children,
                      const SizedBox(height: 4),
                    ],
                  ),
                );
              }

              Widget quickButton({
                required String label,
                required bool enabled,
                required VoidCallback onTap,
              }) {
                return InkWell(
                  onTap: enabled ? onTap : null,
                  borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: VibeTokens.space2,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(VibeTokens.radiusSm),
                      border: Border.all(color: c.borderDefault),
                    ),
                    child: Text(
                      label,
                      style: vibeMono(
                        size: 10,
                        color: enabled ? c.textPrimary : c.textTertiary,
                      ),
                    ),
                  ),
                );
              }

              return SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        VibeTokens.space4,
                        VibeTokens.space3,
                        VibeTokens.space4,
                        VibeTokens.space2,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            'EXPORT $channelLabel',
                            style: vibeMono(size: 11, color: c.textSecondary),
                          ),
                          const SizedBox(height: VibeTokens.space2),
                          radioRow(
                            value: everything,
                            title: 'Whole .mbd',
                            subtitle:
                                'Copy the channel directory verbatim — manifest + ui + assets/',
                            onTap: () => setLocal(() => everything = true),
                          ),
                          radioRow(
                            value: !everything,
                            title: 'Pick',
                            subtitle:
                                'Build a fresh .mbd with the slices you choose',
                            onTap: () => setLocal(() => everything = false),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: c.borderDefault),
                    if (!everything)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: VibeTokens.space2,
                          vertical: VibeTokens.space2,
                        ),
                        child: Wrap(
                          spacing: VibeTokens.space1,
                          runSpacing: VibeTokens.space1,
                          children: <Widget>[
                            quickButton(
                              label: 'All pages',
                              enabled: pageIds.isNotEmpty,
                              onTap:
                                  () => setLocal(() {
                                    pickedPages
                                      ..clear()
                                      ..addAll(pageIds);
                                  }),
                            ),
                            quickButton(
                              label: 'All templates',
                              enabled: templateIds.isNotEmpty,
                              onTap:
                                  () => setLocal(() {
                                    pickedTemplates
                                      ..clear()
                                      ..addAll(templateIds);
                                  }),
                            ),
                            quickButton(
                              label: 'All assets',
                              enabled: assetIds.isNotEmpty,
                              onTap:
                                  () => setLocal(() {
                                    pickedAssets
                                      ..clear()
                                      ..addAll(assetIds);
                                    excludedAutoAssets.clear();
                                  }),
                            ),
                            quickButton(
                              label: 'All UI',
                              enabled:
                                  pageIds.isNotEmpty ||
                                  templateIds.isNotEmpty ||
                                  hasDashboard ||
                                  hasTheme ||
                                  hasNavigation,
                              onTap:
                                  () => setLocal(() {
                                    pickedPages
                                      ..clear()
                                      ..addAll(pageIds);
                                    pickedTemplates
                                      ..clear()
                                      ..addAll(templateIds);
                                    includeDashboard = hasDashboard;
                                    includeTheme = hasTheme;
                                    includeNavigation = hasNavigation;
                                  }),
                            ),
                            quickButton(
                              label: 'Clear',
                              enabled: hasAny,
                              onTap:
                                  () => setLocal(() {
                                    pickedPages.clear();
                                    pickedTemplates.clear();
                                    pickedAssets.clear();
                                    excludedAutoAssets.clear();
                                    includeDashboard = false;
                                    includeTheme = false;
                                    includeNavigation = false;
                                  }),
                            ),
                          ],
                        ),
                      ),
                    if (!everything)
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(
                            horizontal: VibeTokens.space2,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              section('PAGES (${pageIds.length})', <Widget>[
                                if (pageIds.isEmpty)
                                  _placeholder(c)
                                else
                                  for (final id in pageIds)
                                    itemRow(
                                      checked: pickedPages.contains(id),
                                      label: id,
                                      onTap:
                                          () => setLocal(() {
                                            if (pickedPages.contains(id)) {
                                              pickedPages.remove(id);
                                            } else {
                                              pickedPages.add(id);
                                            }
                                          }),
                                    ),
                              ]),
                              section('TEMPLATES (${templateIds.length})', <
                                Widget
                              >[
                                if (templateIds.isEmpty)
                                  _placeholder(c)
                                else
                                  for (final id in templateIds)
                                    itemRow(
                                      checked: pickedTemplates.contains(id),
                                      label: id,
                                      onTap:
                                          () => setLocal(() {
                                            if (pickedTemplates.contains(id)) {
                                              pickedTemplates.remove(id);
                                            } else {
                                              pickedTemplates.add(id);
                                            }
                                          }),
                                    ),
                              ]),
                              section('DASHBOARD', <Widget>[
                                if (!hasDashboard)
                                  _placeholder(c)
                                else
                                  itemRow(
                                    checked: includeDashboard,
                                    label: 'export dashboard',
                                    onTap:
                                        () => setLocal(
                                          () =>
                                              includeDashboard =
                                                  !includeDashboard,
                                        ),
                                  ),
                              ]),
                              section('ASSETS (${assetIds.length})', <Widget>[
                                if (assetIds.isEmpty)
                                  _placeholder(c)
                                else
                                  for (final id in assetIds)
                                    itemRow(
                                      checked: effectiveAssets.contains(id),
                                      label: () {
                                        final entry = source.assets.entries
                                            .firstWhere(
                                              (e) => e['id'] == id,
                                              orElse: () => <String, dynamic>{},
                                            );
                                        final type = '${entry['type'] ?? '?'}';
                                        final ref =
                                            entry['contentRef'] ??
                                            entry['path'] ??
                                            '?';
                                        final isAuto =
                                            autoAssets.contains(id) &&
                                            !pickedAssets.contains(id);
                                        final tag = isAuto ? '  · auto' : '';
                                        return '$id  ·  $type  ·  $ref$tag';
                                      }(),
                                      onTap:
                                          () => setLocal(() {
                                            final isAuto = autoAssets.contains(
                                              id,
                                            );
                                            final isManual = pickedAssets
                                                .contains(id);
                                            if (isManual) {
                                              pickedAssets.remove(id);
                                              if (isAuto) {
                                                excludedAutoAssets.add(id);
                                              }
                                            } else if (isAuto &&
                                                !excludedAutoAssets.contains(
                                                  id,
                                                )) {
                                              excludedAutoAssets.add(id);
                                            } else {
                                              excludedAutoAssets.remove(id);
                                              pickedAssets.add(id);
                                            }
                                          }),
                                    ),
                              ]),
                              section('THEME', <Widget>[
                                if (!hasTheme)
                                  _placeholder(c)
                                else
                                  itemRow(
                                    checked: includeTheme,
                                    label: 'export theme tokens',
                                    onTap:
                                        () => setLocal(
                                          () => includeTheme = !includeTheme,
                                        ),
                                  ),
                              ]),
                              section('NAVIGATION', <Widget>[
                                if (!hasNavigation)
                                  _placeholder(c)
                                else
                                  itemRow(
                                    checked: includeNavigation,
                                    label: 'export navigation chrome',
                                    onTap:
                                        () => setLocal(
                                          () =>
                                              includeNavigation =
                                                  !includeNavigation,
                                        ),
                                  ),
                              ]),
                              section('MANIFEST', <Widget>[
                                itemRow(
                                  checked: includeManifestMeta,
                                  label:
                                      'include identity (id / name / version)',
                                  onTap:
                                      () => setLocal(
                                        () =>
                                            includeManifestMeta =
                                                !includeManifestMeta,
                                      ),
                                ),
                              ]),
                            ],
                          ),
                        ),
                      ),
                    Divider(height: 1, color: c.borderDefault),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: VibeTokens.space3,
                        vertical: VibeTokens.space2,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          inspectTag(
                            type: 'dialog_action',
                            id: 'export.cancel',
                            label: 'Cancel',
                            child: TextButton(
                              onPressed: () => Navigator.of(ctx).pop(null),
                              child: const Text('Cancel'),
                            ),
                          ),
                          const SizedBox(width: VibeTokens.space2),
                          inspectTag(
                            type: 'dialog_action',
                            id: 'export.confirm',
                            label: 'Export',
                            child: FilledButton(
                              onPressed:
                                  (everything || hasAny)
                                      ? () {
                                        final result =
                                            everything
                                                ? ExportSelection.everything()
                                                : ExportSelection.partial(
                                                  pages: Set<String>.from(
                                                    pickedPages,
                                                  ),
                                                  templates: Set<String>.from(
                                                    pickedTemplates,
                                                  ),
                                                  assets: Set<String>.from(
                                                    effectiveAssets,
                                                  ),
                                                  includeDashboard:
                                                      includeDashboard,
                                                  includeTheme: includeTheme,
                                                  includeNavigation:
                                                      includeNavigation,
                                                  includeManifestMeta:
                                                      includeManifestMeta,
                                                );
                                        Navigator.of(ctx).pop(result);
                                      }
                                      : null,
                              child: const Text('Export'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
  );
}

Widget _placeholder(dynamic c) {
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: VibeTokens.space2,
      vertical: VibeTokens.space2,
    ),
    child: Text(
      '— none in this channel —',
      style: vibeMono(size: 11, color: c.textTertiary),
    ),
  );
}

Set<String> _collectAssetRefs(dynamic node) {
  final out = <String>{};
  final re = RegExp(r'bundle://([\w\-]+)');
  void scan(dynamic n) {
    if (n is String) {
      for (final m in re.allMatches(n)) {
        final id = m.group(1);
        if (id != null && id.isNotEmpty) out.add(id);
      }
    } else if (n is Map) {
      for (final v in n.values) {
        scan(v);
      }
    } else if (n is List) {
      for (final v in n) {
        scan(v);
      }
    }
  }

  scan(node);
  return out;
}
