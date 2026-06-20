import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:appplayer_studio/base.dart';

/// 5-target taxonomy a Build dialog can produce.
///
/// Two axes for the four server / native variants:
///   * **bundle vs inline** — `.mbd/` lives next to the binary, or its
///     JSON is baked into the source as a string constant.
///   * **headless vs native** — plain Dart MCP server, or a Flutter app
///     that serves over MCP **and** renders the UI itself.
///
/// Plus `mcpb` — a single archive AppPlayer can install in place.
enum BuildTarget { mcpb, bundle, inline, nativeBundle, nativeInline }

/// Which footer button the user clicked.
///
/// - `saveOnly` — persist the selection as the project's build preset
///   and close. No artifacts touched.
/// - `saveAndBuild` — same as Save, then run the build pipeline.
enum BuildAction { saveOnly, saveAndBuild }

/// Controls how the dialog renders.
///
/// - `previewBuild` — the project header's Build icon. Shows the
///   saved preset as a single read-only target card with the
///   channel / outDir / flutter-create values displayed but not
///   editable; footer is Cancel · Build. The user previews what
///   will be built, then either confirms or cancels — settings
///   changes go through the dedicated Settings dialog.
/// - `settingsOnly` — the project header's Settings (tune) icon.
///   Full target card list, channel picker, outDir field, and
///   flutter-create checkbox are all interactive; footer is
///   Cancel · Save (no Build button). Pure preset edit mode.
enum BuildDialogMode { previewBuild, settingsOnly }

/// Map a target's canonical slug (`mcpb`, `bundle`, `inline`,
/// `native_bundle`, `native_inline`) to the dialog enum. Used when
/// hydrating from a saved `BuildConfig`.
BuildTarget? buildTargetFromSlug(String slug) {
  switch (slug) {
    case 'mcpb':
      return BuildTarget.mcpb;
    case 'bundle':
      return BuildTarget.bundle;
    case 'inline':
      return BuildTarget.inline;
    case 'native_bundle':
      return BuildTarget.nativeBundle;
    case 'native_inline':
      return BuildTarget.nativeInline;
  }
  return null;
}

/// Inverse of [buildTargetFromSlug] — used when the dialog persists
/// its choice back to `BuildConfig`.
String buildTargetSlug(BuildTarget t) {
  switch (t) {
    case BuildTarget.mcpb:
      return 'mcpb';
    case BuildTarget.bundle:
      return 'bundle';
    case BuildTarget.inline:
      return 'inline';
    case BuildTarget.nativeBundle:
      return 'native_bundle';
    case BuildTarget.nativeInline:
      return 'native_inline';
  }
}

/// Outcome of [showBuildDialog]. Null = user cancelled.
class BuildRequest {
  const BuildRequest({
    required this.action,
    required this.target,
    required this.bundleChannel,
    required this.outDir,
    required this.runFlutterCreate,
  });

  final BuildAction action;

  final BuildTarget target;

  /// Channel id (`serving` / `native`) the build sources its UI from.
  /// `mcpb` packs the chosen channel verbatim; the Dart-source targets
  /// transpile the chosen channel's canonical bundle.
  final String bundleChannel;

  /// Absolute path of the directory the artifact lands in.
  final String outDir;

  /// Only meaningful for native targets — when true, the caller runs
  /// `flutter create --project-name <slug> .` after emit so platform
  /// scaffolding (android/ios/macos/...) lands without a manual
  /// second step.
  final bool runFlutterCreate;
}

/// Modal that picks the target + source channel + output directory for
/// a build. The caller dispatches to the matching emitter
/// (`McpBundlePacker.packDirectory` for mcpb, `DartConverter.run` for
/// the four Dart-source variants) — the dialog is presentational.
Future<BuildRequest?> showBuildDialog(
  BuildContext context, {
  required String projectName,
  required String projectPath,
  required List<String> availableChannels,
  required String activeChannel,
  BuildDialogMode mode = BuildDialogMode.previewBuild,
  BuildTarget? initialTarget,
  String? initialChannel,
  String? initialOutDir,
  bool? initialRunFlutterCreate,
}) {
  return showDialog<BuildRequest?>(
    context: context,
    builder:
        (ctx) => _BuildDialog(
          projectName: projectName,
          projectPath: projectPath,
          availableChannels: availableChannels,
          activeChannel: activeChannel,
          mode: mode,
          initialTarget: initialTarget,
          initialChannel: initialChannel,
          initialOutDir: initialOutDir,
          initialRunFlutterCreate: initialRunFlutterCreate,
        ),
  );
}

/// User-friendly metadata for each build target. Headline / subtitle /
/// body are written for non-developers; the developer-facing slug
/// (`mcpb` / `bundle` / `inline` / `native_bundle` / `native_inline`)
/// stays inside the converter.
class _TargetSpec {
  const _TargetSpec({
    required this.target,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.icon,
    required this.outDirSlug,
  });

  final BuildTarget target;
  final String title;
  final String subtitle;
  final String body;
  final IconData icon;
  final String outDirSlug;
}

class _TargetGroup {
  const _TargetGroup({required this.heading, required this.specs});

  final String heading;
  final List<_TargetSpec> specs;
}

const List<_TargetGroup> _targetGroups = <_TargetGroup>[
  _TargetGroup(
    heading: 'Installable package',
    specs: <_TargetSpec>[
      _TargetSpec(
        target: BuildTarget.mcpb,
        title: 'AppPlayer package (.mcpb)',
        subtitle: 'a single file users drop into AppPlayer',
        body:
            'Bundles the chosen channel into one archive that '
            'AppPlayer can install in place. Pick this when sharing '
            'the bundle with someone who already has AppPlayer.',
        icon: Icons.inventory_2_outlined,
        outDirSlug: 'mcpb',
      ),
    ],
  ),
  _TargetGroup(
    heading: 'MCP server — headless (external client renders)',
    specs: <_TargetSpec>[
      _TargetSpec(
        target: BuildTarget.bundle,
        title: 'Server, UI on disk',
        subtitle: 'MCP server · UI loaded from sidecar app.mbd',
        body:
            'A standalone Dart MCP server that other clients '
            '(Claude Desktop, MCP Inspector, AppPlayer) connect to '
            'and render. UI lives in a sibling `app.mbd/` folder, '
            'so the bundle stays editable post-build.',
        icon: Icons.dns_outlined,
        outDirSlug: 'bundle',
      ),
      _TargetSpec(
        target: BuildTarget.inline,
        title: 'Server, UI baked',
        subtitle: 'MCP server · UI compiled into the source',
        body:
            'Same headless role as the on-disk variant, but the '
            'UI is compiled into the executable. One file to ship; '
            'no sidecar folder. Not editable without a rebuild.',
        icon: Icons.dns,
        outDirSlug: 'inline',
      ),
    ],
  ),
  _TargetGroup(
    heading: 'MCP server + self-UI (native — renders its own UI)',
    specs: <_TargetSpec>[
      _TargetSpec(
        target: BuildTarget.nativeBundle,
        title: 'Native app, UI on disk',
        subtitle: 'MCP server + self-UI · UI loaded from app.mbd assets',
        body:
            'A Flutter app that runs the same MCP server **and** '
            'renders the UI itself via flutter_mcp_ui_runtime. The '
            'bundle ships as Flutter assets, so design tweaks land '
            'via a hot restart — best during development.',
        icon: Icons.devices_outlined,
        outDirSlug: 'native_bundle',
      ),
      _TargetSpec(
        target: BuildTarget.nativeInline,
        title: 'Native app, UI baked',
        subtitle: 'MCP server + self-UI · UI compiled into the source',
        body:
            'Same self-UI Flutter app, but the UI is compiled into '
            'the source. Ship to App Stores or distribute as a desktop '
            'installer; nothing on the side.',
        icon: Icons.devices,
        outDirSlug: 'native_inline',
      ),
    ],
  ),
];

_TargetSpec _specFor(BuildTarget t) {
  for (final group in _targetGroups) {
    for (final spec in group.specs) {
      if (spec.target == t) return spec;
    }
  }
  throw StateError('Missing target spec for $t');
}

class _BuildDialog extends StatefulWidget {
  const _BuildDialog({
    required this.projectName,
    required this.projectPath,
    required this.availableChannels,
    required this.activeChannel,
    required this.mode,
    this.initialTarget,
    this.initialChannel,
    this.initialOutDir,
    this.initialRunFlutterCreate,
  });

  final String projectName;
  final String projectPath;
  final List<String> availableChannels;
  final String activeChannel;
  final BuildDialogMode mode;

  /// Hydrates initial state from a saved `BuildConfig`. Null fields
  /// fall back to per-target defaults computed inside the state.
  final BuildTarget? initialTarget;
  final String? initialChannel;
  final String? initialOutDir;
  final bool? initialRunFlutterCreate;

  @override
  State<_BuildDialog> createState() => _BuildDialogState();
}

class _BuildDialogState extends State<_BuildDialog> {
  late BuildTarget _target;
  late String _bundleChannel;
  late final TextEditingController _outDir;
  late BuildDialogMode _mode;
  bool _runFlutterCreate = true;
  bool _userPickedOutDir = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.mode;
    _target = widget.initialTarget ?? BuildTarget.mcpb;
    _bundleChannel =
        widget.initialChannel?.isNotEmpty == true
            ? widget.initialChannel!
            : _channelForTarget(_target);
    final initialOut =
        widget.initialOutDir?.isNotEmpty == true
            ? widget.initialOutDir!
            : _defaultOutDir(_target);
    _outDir = TextEditingController(text: initialOut);
    // When the user edited the path before saving, we treat that as
    // sticky so retargeting doesn't reset their override.
    _userPickedOutDir = widget.initialOutDir?.isNotEmpty == true;
    if (widget.initialRunFlutterCreate != null) {
      _runFlutterCreate = widget.initialRunFlutterCreate!;
    }
  }

  @override
  void dispose() {
    _outDir.dispose();
    super.dispose();
  }

  /// Default output: `<project>/build/<target>/`. Each target gets
  /// its own folder so consecutive builds across targets do not stomp
  /// each other.
  String _defaultOutDir(BuildTarget t) =>
      p.join(widget.projectPath, 'build', _specFor(t).outDirSlug);

  /// Channel preference per target. Native targets default to the
  /// `native` channel when enabled (so self-rendered output reflects
  /// native UI) — falling back to active. Bundle/inline default to
  /// `serving`. mcpb tracks the active channel.
  String _channelForTarget(BuildTarget t) {
    String pickFirst(List<String> preferred) {
      for (final id in preferred) {
        if (widget.availableChannels.contains(id)) return id;
      }
      return widget.activeChannel;
    }

    switch (t) {
      case BuildTarget.nativeBundle:
      case BuildTarget.nativeInline:
        return pickFirst(<String>['native', 'serving']);
      case BuildTarget.bundle:
      case BuildTarget.inline:
        return pickFirst(<String>['serving', 'native']);
      case BuildTarget.mcpb:
        return widget.activeChannel;
    }
  }

  bool _isNative(BuildTarget t) =>
      t == BuildTarget.nativeBundle || t == BuildTarget.nativeInline;

  String _channelLabel(String channelId) {
    switch (channelId) {
      case 'serving':
        return 'Serving';
      case 'native':
        return 'Native';
      default:
        return channelId;
    }
  }

  void _onTargetChanged(BuildTarget next) {
    setState(() {
      _target = next;
      _bundleChannel = _channelForTarget(next);
      if (!_userPickedOutDir) {
        _outDir.text = _defaultOutDir(next);
      }
    });
  }

  Future<void> _pickOutDir() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose build output directory',
      initialDirectory: p.dirname(widget.projectPath),
    );
    if (picked == null) return;
    setState(() {
      _outDir.text = picked;
      _userPickedOutDir = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final native = _isNative(_target);
    final preview = _mode == BuildDialogMode.previewBuild;
    return Dialog(
      backgroundColor: c.surface2,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(VibeTokens.space4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: <Widget>[
                  Text(
                    preview ? 'Build' : 'Build settings',
                    style: vibeMono(
                      size: 14,
                      weight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(width: VibeTokens.space2),
                  Text(
                    '·',
                    style: vibeMono(
                      size: 14,
                      weight: FontWeight.w600,
                      color: c.textTertiary,
                    ),
                  ),
                  const SizedBox(width: VibeTokens.space2),
                  Flexible(
                    child: Text(
                      widget.projectName,
                      style: vibeMono(
                        size: 14,
                        weight: FontWeight.w500,
                        color: c.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: VibeTokens.space2),
              Text(
                preview
                    ? 'Reviewing the saved build settings. '
                        'Cancel to abort, Build to generate '
                        '`<project>/build/<target>/`. Change settings '
                        'via the Build settings (tune) icon.'
                    : 'Every variant runs an MCP server. Two axes pick '
                        'the shape: where the UI lives (on-disk vs '
                        'baked) and who renders it (external client '
                        'vs the app itself). Each option lands under '
                        '`<project>/build/<target>/` by default. The '
                        '.apbproj is left untouched.',
                style: TextStyle(fontSize: 11, color: c.textSecondary),
              ),
              const SizedBox(height: VibeTokens.space4),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (preview)
                        // Build preview — show only the saved target as a
                        // read-only card. Selection / hover / channel
                        // picker are all disabled; the user changes
                        // settings via the dedicated Settings dialog.
                        _TargetCard(
                          spec: _specFor(_target),
                          selected: true,
                          onTap: null,
                          readOnly: true,
                          availableChannels:
                              _isNative(_target)
                                  ? widget.availableChannels
                                  : null,
                          selectedChannel:
                              _isNative(_target) ? _bundleChannel : null,
                          channelLabelOf: _channelLabel,
                          onChannelSelected: null,
                        )
                      else
                        for (
                          var i = 0;
                          i < _targetGroups.length;
                          i++
                        ) ...<Widget>[
                          if (i > 0) const SizedBox(height: VibeTokens.space3),
                          _GroupHeading(text: _targetGroups[i].heading),
                          const SizedBox(height: VibeTokens.space2),
                          for (final spec
                              in _targetGroups[i].specs) ...<Widget>[
                            _TargetCard(
                              spec: spec,
                              selected: _target == spec.target,
                              onTap: () => _onTargetChanged(spec.target),
                              availableChannels:
                                  _isNative(spec.target)
                                      ? widget.availableChannels
                                      : null,
                              selectedChannel:
                                  _isNative(spec.target)
                                      ? _bundleChannel
                                      : null,
                              channelLabelOf: _channelLabel,
                              onChannelSelected:
                                  _isNative(spec.target)
                                      ? (id) =>
                                          setState(() => _bundleChannel = id)
                                      : null,
                            ),
                            const SizedBox(height: VibeTokens.space2),
                          ],
                        ],
                    ],
                  ),
                ),
              ),
              if (native) ...<Widget>[
                const SizedBox(height: VibeTokens.space3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Checkbox(
                      value: _runFlutterCreate,
                      onChanged:
                          preview
                              ? null
                              : (v) => setState(
                                () => _runFlutterCreate = v ?? false,
                              ),
                      visualDensity: VisualDensity.compact,
                    ),
                    Expanded(
                      child: Text(
                        'Add platform folders (android / ios / macos / …) '
                        'after building. Recommended for first-time builds.',
                        style: TextStyle(
                          fontSize: 11,
                          color: preview ? c.textTertiary : c.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: VibeTokens.space3),
              Text(
                'Output directory',
                style: TextStyle(fontSize: 11, color: c.textSecondary),
              ),
              const SizedBox(height: VibeTokens.space2),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _outDir,
                      readOnly: preview,
                      style: vibeMono(
                        size: 12,
                        color: preview ? c.textSecondary : c.textPrimary,
                      ),
                      onChanged: (_) => _userPickedOutDir = true,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: VibeTokens.space3,
                          vertical: VibeTokens.space2,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: VibeTokens.space2),
                  IconButton(
                    tooltip: 'Pick folder',
                    icon: const Icon(Icons.folder_open_outlined, size: 16),
                    onPressed: preview ? null : _pickOutDir,
                  ),
                ],
              ),
              const SizedBox(height: VibeTokens.space4),
              Row(
                children: <Widget>[
                  // Preview mode: a left-aligned Settings primary so
                  // the user can flip into edit mode without leaving
                  // the dialog. Settings dialog mode leaves the left
                  // empty — Cancel / Save sit on the right alone.
                  if (preview)
                    inspectTag(
                      type: 'dialog_action',
                      id: 'build.settings',
                      label: 'Settings',
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: c.mint),
                        onPressed:
                            () => setState(() {
                              _mode = BuildDialogMode.settingsOnly;
                            }),
                        child: const Text('Settings'),
                      ),
                    ),
                  const Spacer(),
                  inspectTag(
                    type: 'dialog_action',
                    id: 'build.cancel',
                    label: 'Cancel',
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: VibeTokens.space2),
                  // Right-side primary — Build in preview, Save in
                  // settings. Both occupy the same slot so the user's
                  // eye doesn't shift between modes.
                  if (preview)
                    inspectTag(
                      type: 'dialog_action',
                      id: 'build.confirm',
                      label: 'Build',
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: c.mint),
                        onPressed: () {
                          final path = _outDir.text.trim();
                          if (path.isEmpty) return;
                          Navigator.of(context).pop(
                            BuildRequest(
                              action: BuildAction.saveAndBuild,
                              target: _target,
                              bundleChannel: _bundleChannel,
                              outDir: path,
                              runFlutterCreate: native && _runFlutterCreate,
                            ),
                          );
                        },
                        child: const Text('Build'),
                      ),
                    )
                  else
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: c.mint),
                      onPressed: () {
                        final path = _outDir.text.trim();
                        if (path.isEmpty) return;
                        Navigator.of(context).pop(
                          BuildRequest(
                            action: BuildAction.saveOnly,
                            target: _target,
                            bundleChannel: _bundleChannel,
                            outDir: path,
                            runFlutterCreate: native && _runFlutterCreate,
                          ),
                        );
                      },
                      child: const Text('Save'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Text(
      text.toUpperCase(),
      style: vibeMono(size: 10, weight: FontWeight.w600, color: c.textTertiary),
    );
  }
}

class _TargetCard extends StatefulWidget {
  const _TargetCard({
    required this.spec,
    required this.selected,
    required this.onTap,
    this.readOnly = false,
    this.availableChannels,
    this.selectedChannel,
    this.channelLabelOf,
    this.onChannelSelected,
  });

  final _TargetSpec spec;
  final bool selected;
  final VoidCallback? onTap;

  /// Skip hover state, click handler, and pointer cursor. Used by
  /// the Build preview dialog where the saved card is shown for
  /// confirmation only.
  final bool readOnly;

  /// Set on native cards so the user can pick which channel's UI the
  /// resulting Flutter app renders. Null on non-native cards (their
  /// channel choice is automatic).
  final List<String>? availableChannels;
  final String? selectedChannel;
  final String Function(String id)? channelLabelOf;
  final ValueChanged<String>? onChannelSelected;

  bool get _hasInlineChannelPicker =>
      availableChannels != null &&
      availableChannels!.isNotEmpty &&
      onChannelSelected != null;

  @override
  State<_TargetCard> createState() => _TargetCardState();
}

class _TargetCardState extends State<_TargetCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    final selected = widget.selected;
    final borderColor =
        selected ? c.mint : (_hovered ? c.borderStrong : c.borderDefault);
    final bg = selected ? c.surface3 : (_hovered ? c.surface2 : c.surface);
    final readOnly = widget.readOnly;
    return MouseRegion(
      cursor: readOnly ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: readOnly ? null : (_) => setState(() => _hovered = true),
      onExit: readOnly ? null : (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: readOnly ? null : widget.onTap,
        child: AnimatedContainer(
          duration: VibeTokens.durFast,
          curve: VibeTokens.easeStandard,
          padding: const EdgeInsets.symmetric(
            horizontal: VibeTokens.space3,
            vertical: VibeTokens.space3,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
            border: Border.all(color: borderColor, width: selected ? 1.5 : 1.0),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  widget.spec.icon,
                  size: 18,
                  color: selected ? c.mint : c.textSecondary,
                ),
              ),
              const SizedBox(width: VibeTokens.space3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            widget.spec.title,
                            style: vibeMono(
                              size: 12,
                              weight: FontWeight.w600,
                              color: c.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: VibeTokens.space2),
                        _SlugTag(
                          slug: widget.spec.outDirSlug,
                          highlighted: selected,
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.spec.subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: c.textTertiary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.spec.body,
                      style: TextStyle(
                        fontSize: 11,
                        color: c.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    if (selected && widget._hasInlineChannelPicker) ...<Widget>[
                      const SizedBox(height: VibeTokens.space3),
                      Container(height: 1, color: c.borderDefault),
                      const SizedBox(height: VibeTokens.space3),
                      Text(
                        'Render channel',
                        style: vibeMono(
                          size: 10,
                          weight: FontWeight.w600,
                          color: c.textSecondary,
                        ),
                      ),
                      const SizedBox(height: VibeTokens.space2),
                      Wrap(
                        spacing: VibeTokens.space2,
                        runSpacing: VibeTokens.space2,
                        children: <Widget>[
                          for (final id in widget.availableChannels!)
                            _ChannelPickerChip(
                              label: widget.channelLabelOf!(id),
                              selected: widget.selectedChannel == id,
                              onTap: () => widget.onChannelSelected!(id),
                            ),
                        ],
                      ),
                      const SizedBox(height: VibeTokens.space2),
                      Text(
                        'Pick which channel\'s UI this app renders. '
                        'Use `serving` to share UI with the headless '
                        'server, or `native` for a separate variant.',
                        style: TextStyle(
                          fontSize: 11,
                          color: c.textTertiary,
                          height: 1.4,
                        ),
                      ),
                    ],
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

/// Compact monospace tag showing the converter's raw target slug
/// (`mcpb`, `bundle`, `inline`, `native_bundle`, `native_inline`) so
/// the user can connect a card to the build folder name vibe writes.
class _SlugTag extends StatelessWidget {
  const _SlugTag({required this.slug, required this.highlighted});

  final String slug;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlighted ? c.mint.withValues(alpha: 0.18) : c.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: highlighted ? c.mint : c.borderDefault,
          width: 1,
        ),
      ),
      child: Text(
        slug,
        style: vibeMono(
          size: 10,
          weight: FontWeight.w500,
          color: highlighted ? c.mint : c.textTertiary,
        ),
      ),
    );
  }
}

class _ChannelPickerChip extends StatelessWidget {
  const _ChannelPickerChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = VibeTokens.colorOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? c.surface3 : c.surface,
          borderRadius: BorderRadius.circular(VibeTokens.radiusMd),
          border: Border.all(
            color: selected ? c.mint : c.borderDefault,
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: vibeMono(
            size: 11,
            weight: FontWeight.w500,
            color: selected ? c.textPrimary : c.textSecondary,
          ),
        ),
      ),
    );
  }
}
