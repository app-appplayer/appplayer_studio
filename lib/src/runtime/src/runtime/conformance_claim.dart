import '../capabilities/runtime_capabilities.dart';
import 'runtime_engine.dart';

/// This package's version — the claim's `version_implementation` (§18.8).
/// A test holds it equal to `pubspec.yaml`.
const String runtimePackageVersion = '0.8.4';

/// The DSL version the claim is made at (§18.8 `version`).
const String dslClaimVersion = '1.4';

/// The advanced widget catalogue of spec §10.1 — what the Advanced Profile
/// requires to parse and render (§18.5). A test holds it equal to §10.1.
const List<String> advancedCatalog = [
  'barcode', 'calendar', 'canvas', 'chart', 'codeEditor', 'dataTable',
  'diffViewer', 'fileExplorer', 'gantt', 'gauge', 'graph', 'heatmap',
  'kanban', 'lightbox', 'map', 'markdown', 'mediaPlayer', 'networkGraph',
  'pdfViewer', 'qrCode', 'resizable', 'richTextEditor', 'signature',
  'splitter', 'spreadsheet', 'table', 'terminal', 'timeline', 'tree',
  'webView',
];

/// The behaviours §18.5 names in the catalogue — media plays, a web view
/// loads, a map draws tiles, a document paginates. Drawing the chrome without
/// them is not conformant at the Advanced level, so they are part of the
/// claim, not only the widgets.
const List<RuntimeCapability> advancedBehaviours = [
  RuntimeCapability.audio,
  RuntimeCapability.video,
  RuntimeCapability.webView,
  RuntimeCapability.map,
  RuntimeCapability.pdf,
];

/// The Profiles of spec §18.1, in the order the spec lists them.
enum DslProfile {
  core('Core'),
  client('Client'),
  bundle('Bundle'),
  advanced('Advanced'),
  template('Template'),
  composition('Composition'),
  payment('Payment'),
  location('Location');

  const DslProfile(this.label);

  /// The name §18.8 lists the Profile under.
  final String label;
}

/// What this runtime claims, in the shape of spec §18.8.
///
/// Derived from what is wired, so it cannot claim more than the runtime does
/// (§18.8: a runtime MUST NOT list a Profile it does not fully satisfy):
/// Core, Client, Bundle and Template are implemented by the runtime itself;
/// Advanced needs the §10.1 catalogue registered and the behaviours it
/// depicts wired (§18.5); Composition needs a host definition resolver;
/// Payment and Location need their host ports.
class ConformanceClaim {
  const ConformanceClaim({
    required this.profiles,
    required this.optional,
    this.version = dslClaimVersion,
    this.implementation = 'flutter_mcp_ui_runtime',
    this.versionImplementation = runtimePackageVersion,
  });

  /// The claim [engine] can make as it is wired now.
  factory ConformanceClaim.of(RuntimeEngine engine) {
    final registry = engine.renderer.widgetRegistry;
    final capabilities = engine.capabilities;
    return ConformanceClaim(
      profiles: [
        DslProfile.core,
        DslProfile.client,
        DslProfile.bundle,
        if (advancedCatalog.every(registry.has) &&
            advancedBehaviours.every(capabilities.supports))
          DslProfile.advanced,
        DslProfile.template,
        if (engine.renderer.definitionResolver != null)
          DslProfile.composition,
        if (capabilities.supports(RuntimeCapability.payment))
          DslProfile.payment,
        if (capabilities.supports(RuntimeCapability.location))
          DslProfile.location,
      ],
      optional: {
        // SHOULD-level i18n (§12.9), implemented by the runtime.
        'i18n.pluralization': true,
        'i18n.numberFormat': true,
        'i18n.dateFormat': true,
        'i18n.textDirection': true,
        // Host-wired surfaces outside the Profiles.
        for (final capability in const [
          RuntimeCapability.sound,
          RuntimeCapability.audio,
          RuntimeCapability.video,
          RuntimeCapability.webView,
          RuntimeCapability.pdf,
          RuntimeCapability.map,
          RuntimeCapability.lottie,
        ])
          capability.name: capabilities.supports(capability),
      },
    );
  }

  final List<DslProfile> profiles;
  final String version;
  final String implementation;
  final String versionImplementation;
  final Map<String, bool> optional;

  /// The §18.8 JSON object.
  Map<String, dynamic> toJson() => {
        'mcp_ui_dsl': {
          'profiles': [for (final profile in profiles) profile.label],
          'version': version,
          'implementation': implementation,
          'version_implementation': versionImplementation,
          'optional': Map<String, dynamic>.from(optional),
        },
      };
}
