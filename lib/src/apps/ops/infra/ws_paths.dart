/// Per-workspace content root inside an Ops project.
///
/// Per the mcp_bundle project layout (DDD MOD-APPS-007), each workspace's
/// operational + knowledge content lives inside its `<wsId>.mbd` bundle
/// directory (slug-safe name — `/` → `_`, e.g. `org/sales` →
/// `org_sales.mbd`). The reserved `_system` workspace is a free runtime
/// dir (escape hatch / cache), not a bundle, so its content stays directly
/// under it.
///
/// Returns an empty string when [projectRoot] is empty (no Ops project
/// bound) so callers surface the existing "workspacesRoot not bound" guard.
library;

const String systemWorkspaceSlot = '_system';

String wsContentRoot(String projectRoot, String wsId) {
  if (projectRoot.isEmpty) return '';
  final slot =
      wsId == systemWorkspaceSlot
          ? systemWorkspaceSlot
          : '${wsId.replaceAll('/', '_')}.mbd';
  return '$projectRoot/$slot';
}
