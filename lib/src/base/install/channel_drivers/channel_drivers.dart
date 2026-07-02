/// Shared channel-connector wiring — reference recipe.
///
///   - [ChannelDriverRegistry] / [ChannelConnectorConfig] — platform-keyed
///     connector builders with per-platform gating (the provisioner).
///   - [registerChannelConnectors] — builders for the external `mcp_channel`
///     connectors (slack / telegram / email / kakao; the rest plug in the same
///     way).
///   - [channelDriverTools] — the host-agnostic `channel.connect` /
///     `channel.disconnect` tools a host registers into its dispatcher.
///
/// Consumed identically by Studio / AppPlayer / FlowBrain so the same bundle
/// sees the same `channel.*` surface. `mcp_channel` core is not modified. The
/// progress-notification and inbound→approval→execute glue convention is in the
/// README — the approval engine (`process_approve` + behaviour gate) already
/// exists in `mcp_knowledge_ops`; this recipe only provisions connectors and
/// pins the glue shape.
library;

export 'src/channel_provisioner.dart';
export 'src/connector_builders.dart';
export 'src/channel_tools.dart';
