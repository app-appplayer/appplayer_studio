/// Configuration-driven provisioning of channel connectors, with per-platform
/// gating. Mirrors the io_drivers provisioner: a type-keyed registry turns a
/// declarative [ChannelConnectorConfig] into a live `ExtendedChannelPort` only
/// when the connector supports the current host platform.
///
/// Dep-free of `mcp_channel` internals — references only the public
/// `ExtendedChannelPort`.
library;

import 'package:mcp_channel/mcp_channel.dart';

/// Host platform classes a connector may declare support for.
enum ChannelPlatform { mobile, desktop, web }

/// Declarative description of one channel connector instance. [params] carries
/// the platform-specific config **including resolved credentials** — a host
/// populates it from its credential store (e.g. `mcp_channel`'s
/// `CredentialManager`) so no secret is hardcoded in the recipe or the bundle.
class ChannelConnectorConfig {
  const ChannelConnectorConfig({
    required this.platform,
    required this.id,
    this.params = const <String, dynamic>{},
  });

  factory ChannelConnectorConfig.fromJson(Map<String, dynamic> json) =>
      ChannelConnectorConfig(
        platform: json['platform'] as String,
        id: json['id'] as String,
        params: (json['params'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      );

  /// Connector platform key (e.g. `slack`, `email`, `kakao`, `telegram`).
  final String platform;

  /// Connector id — the `channelId` this instance registers as.
  final String id;

  /// Connection target + credentials (token / host / port / botId / …).
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'id': id,
        if (params.isNotEmpty) 'params': params,
      };
}

/// Builds a connector instance from its [ChannelConnectorConfig].
typedef ChannelConnectorBuilder = ExtendedChannelPort Function(
    ChannelConnectorConfig config);

/// Raised when a config cannot be provisioned.
class ChannelProvisionException implements Exception {
  ChannelProvisionException(this.code, this.message);

  /// `unknown_platform` | `unsupported_platform` | `missing_param`.
  final String code;
  final String message;

  @override
  String toString() => 'ChannelProvisionException($code): $message';
}

class _Registration {
  const _Registration(this.builder, this.platforms);
  final ChannelConnectorBuilder builder;
  final Set<ChannelPlatform> platforms;
}

/// Platform-keyed connector registry with platform gating. Turns a
/// [ChannelConnectorConfig] into a connector instance only when the platform
/// supports the current host platform.
class ChannelDriverRegistry {
  final Map<String, _Registration> _drivers = {};

  /// Register a connector [platform] supported on [platforms].
  void registerConnector(
    String platform, {
    required Set<ChannelPlatform> platforms,
    required ChannelConnectorBuilder builder,
  }) {
    _drivers[platform] = _Registration(builder, platforms);
  }

  /// Whether a connector is registered for [platform].
  bool has(String platform) => _drivers.containsKey(platform);

  /// Connector platforms available on [platform].
  Set<String> platformsFor(ChannelPlatform platform) => {
        for (final e in _drivers.entries)
          if (e.value.platforms.contains(platform)) e.key,
      };

  /// Build the connector for [config] on [platform]. Throws
  /// [ChannelProvisionException] for an unknown or unsupported platform.
  ExtendedChannelPort build(
    ChannelConnectorConfig config, {
    required ChannelPlatform platform,
  }) {
    final registration = _drivers[config.platform];
    if (registration == null) {
      throw ChannelProvisionException(
        'unknown_platform',
        'no connector registered for platform "${config.platform}"',
      );
    }
    if (!registration.platforms.contains(platform)) {
      throw ChannelProvisionException(
        'unsupported_platform',
        'connector "${config.platform}" is not supported on ${platform.name}',
      );
    }
    return registration.builder(config);
  }
}

/// Read a required string param, or throw a `missing_param` provision error.
String requireParam(ChannelConnectorConfig c, String key) {
  final v = c.params[key];
  if (v is! String || v.isEmpty) {
    throw ChannelProvisionException(
      'missing_param',
      'connector "${c.platform}" (${c.id}) requires param "$key"',
    );
  }
  return v;
}
