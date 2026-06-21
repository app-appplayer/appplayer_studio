/// Local (host-owned, target-less) io drivers + recommended policy.
///
/// The `process` driver is the OS itself — no connection target — so it is
/// boot-registered (not provisioned via `io.connect_device`). It lives here,
/// in the shared recipe, so AppPlayer and Studio register it identically
/// (parity) rather than each host hand-building a [ProcessAdapter].
///
/// See `specs/platform/11-io-devices.md` §3 (boot vs on-connect) and §5
/// (platform gating — process is desktop-only).
library;

import 'package:mcp_io/mcp_io.dart';
import 'package:mcp_io_process/mcp_io_process.dart';
// PolicyRule is hidden by the mcp_bundle barrel (conflicts with models/policy);
// import it directly, mirroring mcp_io's own PolicyEngine.
// ignore: implementation_imports
import 'package:mcp_bundle/src/ports/io_policy_port.dart' show PolicyRule;

import 'io_device_provisioner.dart';

/// Sandbox options for the desktop process driver.
class ProcessOptions {
  const ProcessOptions({
    this.executableAllowlist = const <String>[],
    this.allowedRoots = const <String>[],
    this.allowShell = false,
    this.roles = const ['manager', 'operator'],
  });

  /// Executables the process driver may run (empty = none).
  final List<String> executableAllowlist;

  /// Working-directory roots a command may use (empty = none).
  final List<String> allowedRoots;

  /// Whether `shell:true` execution is permitted (off by default).
  final bool allowShell;

  /// Actor roles allowed to use the process actions.
  final List<String> roles;
}

/// Boot-registered, target-less adapters for [platform]. Currently the
/// `process` driver on desktop; empty on mobile/other.
List<AdapterBase> bootAdapters({
  required DevicePlatform platform,
  ProcessOptions process = const ProcessOptions(),
}) {
  if (platform != DevicePlatform.desktop) return const [];
  return [
    ProcessAdapter(
      config: ProcessSandboxConfig(
        executableAllowlist: process.executableAllowlist,
        allowedRoots: process.allowedRoots,
        allowShell: process.allowShell,
      ),
    ),
  ];
}

/// Recommended io policy rules for the recipe's drivers. Currently the
/// process rules (deny-by-default; spawn → plan→commit). Network-driver
/// connection ACLs are added here as they gain policy.
List<PolicyRule> recommendedPolicyRules({
  List<String> roles = const ['manager', 'operator'],
}) {
  return ProcessPolicy.recommendedRules(roles: roles);
}
