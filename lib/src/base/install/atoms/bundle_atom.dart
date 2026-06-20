/// Bundle metadata atom — `host.bundle.*`. Read-only access to the
/// activation context's own bundle metadata. Lets a JS tool tell the
/// user (or its own logic) which bundle / version it's running inside.
///
/// Cross-bundle ops (`listInstalled`, `activate`) need access to the
/// host's bundle registry — added in a follow-up round once a stable
/// host-side surface is in place. The current atom intentionally
/// scopes to "self" so the bridge stays portable across hosts that
/// expose different registry shapes.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import 'atom_category.dart';

class BundleAtom extends AtomCategory {
  BundleAtom({required this.bundle});

  /// The bundle the activation context wraps. Same instance the host
  /// passed to [HostBundleActivationContext].
  final mb.McpBundle bundle;

  @override
  String get key => 'bundle';

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb(
      'current',
      description:
          'Returns id / name / version / shortId / directory '
          'of the bundle this tool is running inside.',
    ),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'current':
        return <String, dynamic>{
          'id': bundle.manifest.id,
          'name': bundle.manifest.name,
          'shortId': _shortId(bundle.manifest.id),
          'version': bundle.manifest.version,
          'directory': bundle.directory,
        };
      default:
        throw ArgumentError('unknown verb: bundle.$verb');
    }
  }

  String _shortId(String id) {
    final dot = id.lastIndexOf('.');
    return dot >= 0 ? id.substring(dot + 1) : id;
  }
}
