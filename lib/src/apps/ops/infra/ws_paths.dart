/// Per-workspace content root inside an Ops project.
///
/// Per the mcp_bundle project layout, each workspace's
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

/// The workspace's **bundle directory** as published on the host tab's
/// `currentProject` — and therefore the anchor the host `fs.*` capability
/// resolves project-relative paths against ([registerFsTools.activeProjectRoot]).
///
/// Unlike [wsContentRoot], this is ALWAYS `<projectRoot>/<wsId_>.mbd`,
/// including the reserved `_system` slot: `ops_shell` appends `.mbd` uniformly
/// when it publishes `t.currentProject`. Anything that STORES a file link to be
/// read back through `fs.*` (e.g. an asset `locator`) must relativise against
/// THIS so save-side normalisation matches read-side resolution — the whole
/// point of project portability.
String wsBundleDir(String projectRoot, String wsId) {
  if (projectRoot.isEmpty) return '';
  return '$projectRoot/${wsId.replaceAll('/', '_')}.mbd';
}
