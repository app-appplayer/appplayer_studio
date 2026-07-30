/// Ecosystem dependency versions that the app-builder **templates** pin in
/// the `pubspec.yaml` they emit.
///
/// These are seed data, not free constants: an emitted app must run on the
/// same runtime the studio was built and tested against, so they MUST stay in
/// sync with the studio's own `pubspec.yaml`. Treat them like the agent
/// knowledge seed — when the studio version-ups its ecosystem deps, sync these
/// in the same step. `test/template_ecosystem_versions_test.dart` reads the
/// studio pubspec and fails on drift, so a forgotten sync is a red build, not
/// a silently stale template.
library;

/// `flutter_mcp_ui_runtime` — the runtime the emitted Flutter apps
/// (native_bundle / native_inline) load.
const String kTemplateFlutterMcpUiRuntime = '^0.5.3';

/// `mcp_server` — the MCP server core the emitted serving apps
/// (bundle / inline) and Flutter apps host.
const String kTemplateMcpServer = '^2.1.2';

/// `mcp_bundle` — the .mbd bundle format library the bundle-backed variants
/// read at runtime.
const String kTemplateMcpBundle = '^0.4.8';
