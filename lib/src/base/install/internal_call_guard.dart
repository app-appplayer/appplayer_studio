/// Reject-when-external guard for MCP tools the studio classifies as
/// **internal** (chrome backdoors: create_package, bundle.install,
/// bundle.activate, bundle.uninstall). The same handler is callable
/// from two contexts:
///
///   * UI tap — the chrome buttons invoke the [ChromeBridge] slot
///     (`bridge.createNewPackage`, `bridge.activatePackage`, etc.)
///     directly. The MCP handler is not in the path, so this guard
///     never runs on a user click.
///   * MCP dispatch — external LLMs, scenario engine, in-process
///     `boot.callTool` all go through the registered handler.
///     The handler invokes [internalGuard] as its first line; the
///     call is rejected unless [ChromeBridge.internalCallsEnabled] is
///     true (set by the scenario engine for `scenario.internal=true`
///     runs and by any future host-internal automation).
///
/// The host never marks tools "internal" by hiding them from the
/// `tools/list` response — they remain visible so callers see *why*
/// a call rejected ("internal tool: ... requires internal context").
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/chrome_bridge.dart';

/// Returns a rejection [mk.KernelToolResult] when [bridge] is in the
/// external dispatch context (default `internalCallsEnabled = false`).
/// Returns `null` when the call may proceed — the handler should fall
/// through to its normal body. Always call as the **first** statement
/// in the handler so the guard precedes any state read or mutation.
mk.KernelToolResult? internalGuard(ChromeBridge bridge, String toolName) {
  if (bridge.internalCallsEnabled) return null;
  return mk.KernelToolResult(
    content: <mk.KernelContent>[
      mk.KernelTextContent(
        text:
            '{"ok":false,"error":"internal tool: $toolName requires '
            'internal context (UI action or special scenario)"}',
      ),
    ],
    isError: true,
  );
}
