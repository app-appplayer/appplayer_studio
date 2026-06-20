import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/types.dart';

/// Per-project UI state that should follow the project across sessions
/// — focused layer, last-selected page / component, last preview size.
/// Lives at `<projectPath>/prefs.json` next to project.json.
///
/// Distinct from [VibeSettings] (tool-global, follows the user) and
/// from the bundle (which only holds DSL content). Loss of prefs.json
/// is non-fatal — the shell falls back to defaults.
class VibeProjectPrefs {
  VibeProjectPrefs({
    Map<String, Map<CenterMode, LayerId>>? focusedByChannelMode,
    this.selectedPageId,
    this.selectedComponentId,
    this.previewSizeChoice,
    this.previewOrientation,
    this.previewBrightness,
    this.previewCustomW,
    this.previewCustomH,
    this.buildConfig,
  }) : focusedByChannelMode =
           focusedByChannelMode ?? <String, Map<CenterMode, LayerId>>{};

  /// Last-focused overview layer card keyed by (active channel, centre
  /// mode). Each coordinate keeps its own focused layer so toggling
  /// modes or channels does not bleed selection across.
  ///
  /// Empty map → first-run defaults take over (UI = appStructure /
  /// Bundle = manifest, resolved at read time).
  Map<String, Map<CenterMode, LayerId>> focusedByChannelMode;

  /// Last-selected page id within the Pages layer. Validated against
  /// the live projection on restore — invalid ids fall through to the
  /// app home.
  String? selectedPageId;

  /// Last-selected component id within the Components layer.
  String? selectedComponentId;

  /// Preview tab-bar size choice ('mobile' / 'tablet' / 'pc' / 'custom').
  String? previewSizeChoice;

  /// Preview orientation ('portrait' / 'landscape').
  String? previewOrientation;

  /// Preview brightness override ('system' / 'light' / 'dark').
  String? previewBrightness;

  /// Custom preview width / height (only meaningful when
  /// [previewSizeChoice] is `custom`).
  int? previewCustomW;
  int? previewCustomH;

  /// Saved build preset — what the Build dialog last committed via
  /// "Save" or "Build". When set, the dialog opens with these values
  /// preselected and an LLM driving via MCP can run `vibe_build_run`
  /// without arguments.
  BuildConfig? buildConfig;

  static const String fileName = 'prefs.json';

  Map<String, dynamic> toJson() {
    final byChannelJson = <String, Map<String, String>>{};
    focusedByChannelMode.forEach((channel, byMode) {
      if (byMode.isEmpty) return;
      byChannelJson[channel] = <String, String>{
        for (final entry in byMode.entries) entry.key.name: entry.value.name,
      };
    });
    return <String, dynamic>{
      'schemaVersion': 2,
      if (byChannelJson.isNotEmpty) 'focusedByChannelMode': byChannelJson,
      if (selectedPageId != null) 'selectedPageId': selectedPageId,
      if (selectedComponentId != null)
        'selectedComponentId': selectedComponentId,
      if (previewSizeChoice != null) 'previewSizeChoice': previewSizeChoice,
      if (previewOrientation != null) 'previewOrientation': previewOrientation,
      if (previewBrightness != null) 'previewBrightness': previewBrightness,
      if (previewCustomW != null) 'previewCustomW': previewCustomW,
      if (previewCustomH != null) 'previewCustomH': previewCustomH,
      if (buildConfig != null) 'buildConfig': buildConfig!.toJson(),
    };
  }

  factory VibeProjectPrefs.fromJson(Map<String, dynamic> json) {
    final focusMap = <String, Map<CenterMode, LayerId>>{};
    final raw = json['focusedByChannelMode'];
    if (raw is Map<String, dynamic>) {
      raw.forEach((channel, perMode) {
        if (perMode is! Map) return;
        final byMode = <CenterMode, LayerId>{};
        perMode.forEach((modeName, layerName) {
          if (modeName is! String || layerName is! String) return;
          CenterMode? mode;
          for (final m in CenterMode.values) {
            if (m.name == modeName) {
              mode = m;
              break;
            }
          }
          LayerId? layer;
          for (final l in LayerId.values) {
            if (l.name == layerName) {
              layer = l;
              break;
            }
          }
          if (mode != null && layer != null) {
            byMode[mode] = layer;
          }
        });
        if (byMode.isNotEmpty) focusMap[channel] = byMode;
      });
    }
    BuildConfig? bc;
    final rawBc = json['buildConfig'];
    if (rawBc is Map<String, dynamic>) {
      bc = BuildConfig.fromJson(rawBc);
    }
    return VibeProjectPrefs(
      focusedByChannelMode: focusMap,
      selectedPageId: json['selectedPageId'] as String?,
      selectedComponentId: json['selectedComponentId'] as String?,
      previewSizeChoice: json['previewSizeChoice'] as String?,
      previewOrientation: json['previewOrientation'] as String?,
      previewBrightness: json['previewBrightness'] as String?,
      previewCustomW: json['previewCustomW'] as int?,
      previewCustomH: json['previewCustomH'] as int?,
      buildConfig: bc,
    );
  }

  /// Read from `<projectPath>/prefs.json`. Returns a default-valued
  /// instance when the file is missing or unreadable.
  static Future<VibeProjectPrefs> load(String projectPath) async {
    final file = File(p.join(projectPath, fileName));
    if (!await file.exists()) return VibeProjectPrefs();
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map<String, dynamic>) return VibeProjectPrefs.fromJson(raw);
      return VibeProjectPrefs();
    } catch (_) {
      return VibeProjectPrefs();
    }
  }

  /// Persist atomically.
  Future<void> save(String projectPath) async {
    final target = File(p.join(projectPath, fileName));
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
    await tmp.rename(target.path);
  }
}

/// Saved Build dialog selection. Lets the GUI restore last choices
/// across sessions, and lets an MCP-driven LLM see what the user
/// most recently configured (via `vibe_build_config_get`) before
/// invoking `vibe_build_run` with no arguments.
class BuildConfig {
  const BuildConfig({
    required this.target,
    required this.channel,
    required this.outDir,
    required this.runFlutterCreate,
  });

  /// Converter target slug — `mcpb` / `bundle` / `inline` /
  /// `native_bundle` / `native_inline`. Stored as the canonical slug
  /// so external LLMs can pass it straight to `vibe_convert_dart`.
  final String target;

  /// Source channel id (`serving` / `native`). For `mcpb` this is
  /// the channel whose `.mbd/` is packed; for `bundle`/`inline` and
  /// the native variants this is the channel whose canonical UI is
  /// transpiled.
  final String channel;

  /// Output directory — project-relative when relative, absolute
  /// otherwise. The Build dialog auto-derives this from the target
  /// slug (`build/<target>/`) but the user can override.
  final String outDir;

  /// Native-only flag — whether the GUI's `flutter create` automation
  /// kicks in after emit. Persisted so reopening the dialog matches
  /// the last choice.
  final bool runFlutterCreate;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'target': target,
    'channel': channel,
    'outDir': outDir,
    'runFlutterCreate': runFlutterCreate,
  };

  factory BuildConfig.fromJson(Map<String, dynamic> json) => BuildConfig(
    target: (json['target'] as String?) ?? 'mcpb',
    channel: (json['channel'] as String?) ?? 'serving',
    outDir: (json['outDir'] as String?) ?? '',
    runFlutterCreate: (json['runFlutterCreate'] as bool?) ?? true,
  );

  BuildConfig copyWith({
    String? target,
    String? channel,
    String? outDir,
    bool? runFlutterCreate,
  }) => BuildConfig(
    target: target ?? this.target,
    channel: channel ?? this.channel,
    outDir: outDir ?? this.outDir,
    runFlutterCreate: runFlutterCreate ?? this.runFlutterCreate,
  );
}
