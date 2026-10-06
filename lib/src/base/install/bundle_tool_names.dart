/// How a tool name written inside a bundle reaches a registered tool
/// (platform spec 04-ui-host "Name isolation").
///
/// A host registers a bundle's tools as `<namespace>.<name>`, and the
/// namespace is chosen at activation (it can differ from the manifest id),
/// so a bundle cannot write its own full names. Every name that comes from
/// inside a bundle — a screen `tool` action, `host.mcp.callTool` in js,
/// a wiring slot, an agent's tool list — therefore resolves to the
/// bundle's own namespace first and, when that is not registered, to the
/// name as written (a full name, a host tool, another bundle's tool).
/// Outside a bundle ([namespace] null) only full names reach.
library;

/// The registered name [name] resolves to when called from inside the
/// bundle running under [namespace]. [isRegistered] answers whether a
/// full tool name is registered on the host.
String resolveBundleToolName(
  String name, {
  required String? namespace,
  required bool Function(String fullName) isRegistered,
}) {
  if (namespace == null || namespace.isEmpty) return name;
  final own = '$namespace.$name';
  return isRegistered(own) ? own : name;
}

/// [resolveBundleToolName] for an allowlist pattern (`<name>` or a
/// trailing-star `<prefix>.*`): the bundle's own namespace when any
/// registered name matches it there, else the pattern as written.
String resolveBundleToolPattern(
  String pattern, {
  required String? namespace,
  required Iterable<String> registered,
}) {
  if (namespace == null || namespace.isEmpty) return pattern;
  final own = '$namespace.$pattern';
  if (own.endsWith('*')) {
    final prefix = own.substring(0, own.length - 1);
    return registered.any((n) => n.startsWith(prefix)) ? own : pattern;
  }
  return registered.contains(own) ? own : pattern;
}
