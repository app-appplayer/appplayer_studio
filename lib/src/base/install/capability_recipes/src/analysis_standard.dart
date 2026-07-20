/// Standard adoption of the analysis capability for hosts.
///
/// The production engine builder lives IN the package
/// (`AnalysisPortAdapter.inMemory()` — full catalog + `synthetic`
/// simulation source); this recipe contributes only what recipes own:
/// the port→tool wrap ([analysisCapabilityTools]) and the one-line
/// registration ([registerAnalysisCapability]) any host calls identically
/// (no Studio/AppPlayer divergence).
library;

import 'package:brain_kernel/brain_kernel.dart';
import 'package:mcp_analysis/mcp_analysis.dart';

import 'analysis_example.dart';
import 'capability_tool_pack.dart';

/// The standard in-memory analysis engine. Kept as the recipe's stable
/// entry name; delegates to the package builder.
AnalysisPort standardAnalysisPort({
  EventPort? eventPort,
  MetricPort? metricPort,
}) =>
    AnalysisPortAdapter.inMemory(
      eventPort: eventPort,
      metricPort: metricPort,
    );

/// Turnkey: register the `analysis.*` capability on [registry] in one line.
/// Default engine = [standardAnalysisPort]; a host with its own configured
/// port (persistent storage, extra data sources) passes it via [port].
/// Returns the exposed tool names.
List<String> registerAnalysisCapability(
  HostToolRegistry registry, {
  AnalysisPort? port,
  EventPort? eventPort,
  MetricPort? metricPort,
}) =>
    registerCapabilityTools(
      registry,
      capabilityId: analysisCapabilityId,
      tools: analysisCapabilityTools(
        port ??
            standardAnalysisPort(
              eventPort: eventPort,
              metricPort: metricPort,
            ),
      ),
    );
