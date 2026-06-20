/// App Builder's canonical authoring types are the platform's — this file
/// no longer forks a parallel flat type set. It re-exports the single
/// canonical model (LayerId / CanonicalPatch / PatchOp / PatchOriginator /
/// ValidationIssue / CanonicalChange / …) from the host + kernel, and
/// keeps only the two App-Builder-shell concepts (CenterMode, ConvertResult)
/// that have no platform equivalent.
library;

// Host (vibe_studio base) — canonical patch model, layer ids, import kind,
// builder exceptions, and the shared ChatTurn.
export 'package:appplayer_studio/base.dart'
    show
        ChatTurn,
        LayerId,
        CanonicalPatch,
        ImportKind,
        ProjectKindOption,
        DiskException,
        LoadException,
        ImportException,
        ValidationException;

// Kernel (via builtin_api) — RFC 6902 op + sealed originator provenance,
// sealed patch outcome, validation findings, and change notifications.
export 'package:appplayer_studio/builtin_api.dart'
    show
        PatchOp,
        PatchOriginator,
        UserOriginator,
        LlmOriginator,
        McpClientOriginator,
        CliOriginator,
        ImportOriginator,
        PatchResult,
        PatchApplied,
        PatchRejected,
        ValidationIssue,
        ValidationSeverity,
        ValidationLayer,
        CanonicalChange,
        CanonicalChangeKind;

import 'package:appplayer_studio/base.dart' show LayerId;

/// Centre-panel mode for the unified builder shell — selects which surface
/// the centre column shows and, alongside [LayerId], which authoring layers
/// the OverviewStrip exposes.
///
///   * `ui` — UI editor surface (OverviewStrip 8 cards · InstanceStrip ·
///     PreviewPanel / AssetGalleryView). The default landing mode.
///   * `bundle` — Bundle authoring surface (4 cards · Manifest · Tools ·
///     Knowledge · Agents — each a dedicated detail view).
///   * `debug` — Debug / inspector surface (InspectorPanel · wire log ·
///     variant cards · runtime state monitor).
enum CenterMode {
  ui,
  bundle,
  debug;

  /// Layers a given mode renders in the OverviewStrip / 4-card strip.
  static const Map<CenterMode, List<LayerId>> _layersByMode =
      <CenterMode, List<LayerId>>{
        CenterMode.ui: <LayerId>[
          LayerId.appStructure,
          LayerId.theme,
          LayerId.components,
          LayerId.dashboard,
          LayerId.navigation,
          LayerId.pages,
          LayerId.assets,
          LayerId.whole,
        ],
        CenterMode.bundle: <LayerId>[
          LayerId.manifest,
          LayerId.tools,
          LayerId.knowledge,
          LayerId.agents,
        ],
        CenterMode.debug: <LayerId>[],
      };

  static List<LayerId> layersFor(CenterMode mode) =>
      _layersByMode[mode] ?? const <LayerId>[];

  /// Resolve which mode owns [layer]. Used when a layer is focused
  /// externally (e.g. chat → focus knowledge) to switch the mode chip
  /// along with the layer selection.
  static CenterMode modeOf(LayerId layer) {
    if (_layersByMode[CenterMode.bundle]!.contains(layer)) {
      return CenterMode.bundle;
    }
    return CenterMode.ui;
  }
}

/// Result of a converter run — App Builder's code-generation output
/// (Dart / embedded). No platform equivalent; stays local.
class ConvertResult {
  const ConvertResult({
    required this.outDir,
    required this.canonicalHash,
    required this.writtenFiles,
  });
  final String outDir;
  final String canonicalHash;
  final List<String> writtenFiles;
}
