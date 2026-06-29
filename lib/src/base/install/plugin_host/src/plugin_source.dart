/// A plugin source — the unit a host registers as a tool provider.
///
/// Generalizes the host's "saved server" (e.g. AppPlayer's `ServerConfig`)
/// across three substrates. The physical platform reach falls out of the
/// substrate — it is a fact, not a quality ranking:
///
/// | kind     | substrate                         | reach          |
/// |----------|-----------------------------------|----------------|
/// | `bundle` | in-process bundle activation      | all platforms  |
/// | `server` | a local MCP server (subprocess)   | desktop only   |
/// | `hub`    | a remote server / gateway (network) | all platforms |
///
/// (`server` over a network endpoint is also all-platform; only the local
/// subprocess form is desktop-bound, exactly like the io process driver.)
library;

import 'package:brain_kernel/brain_kernel.dart' show KernelTransportKind;

enum PluginKind { bundle, server, hub }

class PluginSource {
  const PluginSource({
    required this.id,
    required this.kind,
    this.name = '',
    this.description = '',
    this.transport,
    this.endpoint,
    this.options,
  });

  /// Stable id — also the tool namespace: tools register as `<id>.<tool>`.
  final String id;

  final PluginKind kind;
  final String name;
  final String description;

  /// Transport for `server`/`hub` kinds. Ignored for `bundle`.
  final KernelTransportKind? transport;

  /// Endpoint (URL / command) for `server`/`hub` kinds.
  final String? endpoint;

  /// Transport options (access token, headers, env, …).
  final Map<String, dynamic>? options;

  /// A network-reachable source works on every platform; a local subprocess
  /// `server` does not (no process spawn on mobile). The host gates on this.
  bool get isNetwork =>
      transport == KernelTransportKind.streamableHttp ||
      transport == KernelTransportKind.sse;
}
