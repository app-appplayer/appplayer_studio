/// Top-level metadata editor for a bundle's `manifest.json`. Renders
/// the IDENTITY (id · name · version), DESCRIPTION, REQUIRES, and CHAT
/// blocks of the manifest as a single scrollable form. Editable fields
/// (`name`, `description`) autosave on every keystroke to the bundle's
/// `manifest.json`; read-only fields (`id`, `version`, requires atoms,
/// chat agent ref) surface as mono labels so the user sees the live
/// state without ambiguity. Canonical authoring path is still the chat
/// — these inline fields are the manual fallback.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/ui.dart';

class BundleManifestView extends StatefulWidget {
  const BundleManifestView({
    super.key,
    required this.bundlePath,
    this.reloadCounter = 0,
  });

  /// Absolute path to the bundle directory (the `.mbd/` folder).
  final String bundlePath;

  /// External reload trigger — bumped by the host when a chat-driven
  /// mutator (`studio.builder.patchManifest`) writes the file. The view
  /// re-reads disk on bump so its fields reflect the canonical state.
  final int reloadCounter;

  @override
  State<BundleManifestView> createState() => _BundleManifestViewState();
}

class _BundleManifestViewState extends State<BundleManifestView> {
  Map<String, dynamic>? _raw;
  String _id = '';
  String _version = '';
  List<String> _requires = const <String>[];
  List<String> _requiresTools = const <String>[];
  String? _chatAgent;
  // Capability declaration derived from manifest wiring / atom usage:
  //   * `appplayer` — runs on AppPlayer + Studio (no studio-only wiring).
  //   * `studio` — declares one of: wiring.lifecycle[], wiring.domainActions[],
  //     wiring.settings[], chat.slashCommands[], or studio-only builtinAtoms.
  String _capability = 'appplayer';

  late TextEditingController _name;
  late TextEditingController _description;
  late TextEditingController _titlebar;
  late TextEditingController _statusbar;

  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController()..addListener(_onFieldChanged);
    _description = TextEditingController()..addListener(_onFieldChanged);
    _titlebar = TextEditingController()..addListener(_onFieldChanged);
    _statusbar = TextEditingController()..addListener(_onFieldChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant BundleManifestView old) {
    super.didUpdateWidget(old);
    if (old.bundlePath != widget.bundlePath ||
        old.reloadCounter != widget.reloadCounter) {
      _load();
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _name.dispose();
    _description.dispose();
    _titlebar.dispose();
    _statusbar.dispose();
    super.dispose();
  }

  void _load() {
    try {
      final f = File(p.join(widget.bundlePath, 'manifest.json'));
      if (!f.existsSync()) {
        if (mounted) setState(() => _raw = null);
        return;
      }
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! Map<String, dynamic>) {
        if (mounted) setState(() => _raw = null);
        return;
      }
      // Identity block — canonical home is the `manifest` wrapper; the
      // older draft layout put these at the top level so we tolerate
      // both shapes when reading.
      final mblock = raw['manifest'];
      final identity = (mblock is Map<String, dynamic>) ? mblock : raw;
      final id = identity['id']?.toString() ?? '';
      final name = identity['name']?.toString() ?? '';
      final version = identity['version']?.toString() ?? '';
      final description = identity['description']?.toString() ?? '';
      // Requires + chat blocks always sit at the top level.
      final req = raw['requires'];
      final atoms = (req is Map<String, dynamic>) ? req['builtinAtoms'] : null;
      final tools = (req is Map<String, dynamic>) ? req['builtinTools'] : null;
      final requires = <String>[
        if (atoms is List)
          for (final a in atoms) a.toString(),
      ];
      final requiresTools = <String>[
        if (tools is List)
          for (final t in tools) t.toString(),
      ];
      final chat = raw['chat'];
      final chatAgent =
          (chat is Map<String, dynamic>) ? chat['agent']?.toString() : null;
      // Capability classification — Studio-extended when ANY of the
      // host-specific wiring slots is non-empty (lifecycle / domain
      // actions / settings) or a slash command is wired. Otherwise
      // the bundle is AppPlayer-runnable.
      final wiring = raw['wiring'];
      final slashCommands =
          (chat is Map<String, dynamic>) ? chat['slashCommands'] : null;
      bool _listNonEmpty(Object? v) => v is List && v.isNotEmpty;
      final hasStudioWiring =
          wiring is Map<String, dynamic> &&
          (_listNonEmpty(wiring['lifecycle']) ||
              _listNonEmpty(wiring['domainActions']) ||
              _listNonEmpty(wiring['settings']));
      final hasSlashCommand = _listNonEmpty(slashCommands);
      final capability =
          (hasStudioWiring || hasSlashCommand) ? 'studio' : 'appplayer';
      // Chrome user-zone payload templates (wiring.titlebar /
      // wiring.statusbar — spec §6.4a). Single-string fields, optional.
      final titlebar =
          wiring is Map<String, dynamic>
              ? wiring['titlebar']?.toString() ?? ''
              : '';
      final statusbar =
          wiring is Map<String, dynamic>
              ? wiring['statusbar']?.toString() ?? ''
              : '';
      if (!mounted) return;
      _saveDebounce?.cancel();
      setState(() {
        _raw = raw;
        _id = id;
        _version = version;
        _requires = requires;
        _requiresTools = requiresTools;
        _capability = capability;
        _chatAgent = chatAgent;
        // Skip the listener while we sync the controllers from disk —
        // otherwise the loaded value flips an autosave round-trip.
        _name.removeListener(_onFieldChanged);
        _description.removeListener(_onFieldChanged);
        _titlebar.removeListener(_onFieldChanged);
        _statusbar.removeListener(_onFieldChanged);
        _name.text = name;
        _description.text = description;
        _titlebar.text = titlebar;
        _statusbar.text = statusbar;
        _name.addListener(_onFieldChanged);
        _description.addListener(_onFieldChanged);
        _titlebar.addListener(_onFieldChanged);
        _statusbar.addListener(_onFieldChanged);
      });
    } catch (_) {
      // Best-effort — surface the empty / unparseable case via _raw == null.
      if (mounted) setState(() => _raw = null);
    }
  }

  void _onFieldChanged() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), _save);
  }

  Future<void> _save() async {
    final raw = _raw;
    if (raw == null) return;
    try {
      final mblock = raw['manifest'];
      final identity = (mblock is Map<String, dynamic>) ? mblock : raw;
      identity['name'] = _name.text;
      identity['description'] = _description.text;
      // Chrome user-zone payloads — write back to `wiring.titlebar` /
      // `wiring.statusbar`. Empty string clears the key (omit from
      // wiring map) so the host falls back to the spec default.
      final wiringMap = raw['wiring'];
      final wiring =
          (wiringMap is Map<String, dynamic>) ? wiringMap : <String, dynamic>{};
      final tb = _titlebar.text.trim();
      final sb = _statusbar.text.trim();
      if (tb.isEmpty) {
        wiring.remove('titlebar');
      } else {
        wiring['titlebar'] = tb;
      }
      if (sb.isEmpty) {
        wiring.remove('statusbar');
      } else {
        wiring['statusbar'] = sb;
      }
      if (wiring.isNotEmpty) raw['wiring'] = wiring;
      final f = File(p.join(widget.bundlePath, 'manifest.json'));
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(raw));
    } catch (e) {
      // Autosave is best-effort, but a swallowed WRITE failure means the
      // user's manifest edit is lost on disk with no indication. Surface
      // it instead of silently dropping it (data-loss class).
      stderr.writeln(
        'bundle_manifest_view: manifest autosave failed — edit not '
        'persisted: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = VbuTokens.colorOf(context);
    if (_raw == null) {
      return Container(
        color: c.bg,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(VbuTokens.space5),
            child: Text(
              'No manifest.json at this path yet.\n${widget.bundlePath}',
              textAlign: TextAlign.center,
              style: vbuMono(size: 11, color: c.textTertiary),
            ),
          ),
        ),
      );
    }
    return Container(
      color: c.bg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(VbuTokens.space5),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _sectionHeader('IDENTITY'),
              _readOnlyRow('id', _id),
              const SizedBox(height: VbuTokens.space2),
              VbuLabelledField(
                label: 'name',
                controller: _name,
                hint: 'human-readable name',
              ),
              const SizedBox(height: VbuTokens.space2),
              _readOnlyRow('version', _version),
              const SizedBox(height: VbuTokens.space4),
              _sectionHeader('DESCRIPTION'),
              _multilineField(_description),
              const SizedBox(height: VbuTokens.space4),
              _sectionHeader('CAPABILITY'),
              _capabilityRow(),
              const SizedBox(height: VbuTokens.space4),
              _sectionHeader('CHROME ZONES'),
              Text(
                'Single-string payloads the host renders in the chrome '
                'titlebar / statusbar user areas (after the fixed pills). '
                'Supports `{{key}}` bindings against the active tab\'s '
                'runtime state — any tool that writes the bound key '
                'triggers an automatic chrome re-render. Leave blank to '
                'omit. Spec §6.4a · manual `docs/builder/manual/'
                '02-bundle-schema.md` §Chrome user-zone payloads.',
                style: vbuMono(size: 10, color: c.textTertiary),
              ),
              const SizedBox(height: VbuTokens.space2),
              VbuLabelledField(
                label: 'titlebar',
                controller: _titlebar,
                hint: 'e.g. build {{status}} · 5 jobs',
              ),
              const SizedBox(height: VbuTokens.space2),
              VbuLabelledField(
                label: 'statusbar',
                controller: _statusbar,
                hint: 'e.g. recordings: {{recordingsCount}}',
              ),
              const SizedBox(height: VbuTokens.space4),
              _sectionHeader('REQUIRES — builtinAtoms (${_requires.length})'),
              if (_requires.isEmpty)
                Text(
                  'No atoms declared.',
                  style: vbuMono(size: 11, color: c.textTertiary),
                )
              else
                Wrap(
                  spacing: VbuTokens.space1,
                  runSpacing: VbuTokens.space1,
                  children: <Widget>[for (final atom in _requires) _chip(atom)],
                ),
              const SizedBox(height: VbuTokens.space4),
              _sectionHeader(
                'REQUIRES — builtinTools (${_requiresTools.length})',
              ),
              if (_requiresTools.isEmpty)
                Text(
                  'No host tools declared. Bundle still runs — chat / '
                  'JS-tool calls bind dynamically at activation.',
                  style: vbuMono(size: 11, color: c.textTertiary),
                )
              else ...<Widget>[
                Wrap(
                  spacing: VbuTokens.space1,
                  runSpacing: VbuTokens.space1,
                  children: <Widget>[
                    for (final tool in _requiresTools) _chip(tool),
                  ],
                ),
                const SizedBox(height: VbuTokens.space1),
                Text(
                  'Host validates these at activation. Missing tools are '
                  'logged via `recordBootEvent` and surface in '
                  'Debug → Boot.',
                  style: vbuMono(size: 10, color: c.textTertiary),
                ),
              ],
              const SizedBox(height: VbuTokens.space4),
              _sectionHeader('CHAT'),
              _readOnlyRow(
                'agent',
                (_chatAgent == null || _chatAgent!.isEmpty)
                    ? '(none — chat panel falls back to studio.manager)'
                    : _chatAgent!,
              ),
              const SizedBox(height: VbuTokens.space5),
              Container(
                padding: const EdgeInsets.all(VbuTokens.space3),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
                  border: Border.all(color: c.borderSubtle),
                ),
                child: Text(
                  'Inline edits autosave to manifest.json. The canonical '
                  'authoring path is still the chat — `studio.builder'
                  '.patchManifest` understands the full schema including '
                  'requires / chat / nested blocks. Version edits stay '
                  'out of this form by design.',
                  style: vbuMono(size: 10, color: c.textTertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Capability badge — pill showing the bundle's host requirement
  /// (AppPlayer-runnable vs Studio-extended). Phase F surface.
  Widget _capabilityRow() {
    final c = VbuTokens.colorOf(context);
    final isStudio = _capability == 'studio';
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isStudio ? c.mintDim.withValues(alpha: 0.12) : c.surface2,
        borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
        border: Border.all(
          color: isStudio ? c.mintDim : c.borderSubtle,
          width: 1,
        ),
      ),
      child: Text(
        isStudio ? 'Studio-extended' : 'AppPlayer-runnable',
        style: vbuMono(size: 11, color: isStudio ? c.mint : c.textSecondary),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        badge,
        const SizedBox(width: VbuTokens.space2),
        Expanded(
          child: Text(
            isStudio
                ? 'Uses wiring.lifecycle / wiring.domainActions / '
                    'wiring.settings / chat.slashCommands — runs in '
                    'Studio host only.'
                : 'No studio-only wiring detected — runs on AppPlayer '
                    'as well as Studio. capability declaration auto-'
                    'derived from manifest content.',
            style: vbuMono(size: 10, color: c.textTertiary),
          ),
        ),
      ],
    );
  }

  /// Standard "chip" pill used for builtin atom / tool labels.
  Widget _chip(String label) {
    final c = VbuTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(VbuTokens.radiusFull),
        border: Border.all(color: c.borderSubtle),
      ),
      child: Text(label, style: vbuMono(size: 10, color: c.mintDim)),
    );
  }

  Widget _sectionHeader(String title) {
    final c = VbuTokens.colorOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: VbuTokens.space2),
      child: Text(
        title,
        style: TextStyle(
          fontFamily: VbuTokens.fontMono,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.0,
          color: c.textTertiary,
        ),
      ),
    );
  }

  Widget _readOnlyRow(String label, String value) {
    final c = VbuTokens.colorOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: 92,
          child: Text(label, style: vbuMono(size: 11, color: c.textSecondary)),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '(empty)' : value,
            style: vbuMono(
              size: 12,
              color: value.isEmpty ? c.textTertiary : c.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _multilineField(TextEditingController c) {
    final col = VbuTokens.colorOf(context);
    return Container(
      decoration: BoxDecoration(
        color: col.surface,
        borderRadius: BorderRadius.circular(VbuTokens.radiusSm),
        border: Border.all(color: col.borderSubtle),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: VbuTokens.space3,
        vertical: VbuTokens.space2,
      ),
      child: TextField(
        controller: c,
        minLines: 4,
        maxLines: 12,
        style: vbuMono(size: 12, color: col.textPrimary),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
          hintText:
              'What this bundle does — paragraph form. Surfaced in the '
              'package picker and the chat agent\'s context.',
        ),
      ),
    );
  }
}
