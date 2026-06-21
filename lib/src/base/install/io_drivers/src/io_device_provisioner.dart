/// Configuration-driven provisioning of connection-oriented io device
/// adapters, with per-driver platform gating.
///
/// See `specs/platform/11-io-devices.md` §3–§5. Dep-free of `mcp_io` core
/// internals — references only the public `AdapterBase`.
library;

import 'package:mcp_io/mcp_io.dart';

/// Host platform classes a driver may declare support for.
enum DevicePlatform { mobile, desktop, web }

/// Declarative description of one io device instance.
class IoDeviceConfig {
  const IoDeviceConfig({
    required this.type,
    required this.id,
    this.params = const <String, dynamic>{},
  });

  factory IoDeviceConfig.fromJson(Map<String, dynamic> json) => IoDeviceConfig(
        type: json['type'] as String,
        id: json['id'] as String,
        params: (json['params'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      );

  /// Adapter type key (e.g. `modbus`, `mqtt`).
  final String type;

  /// Device id — the `io.execute` target for this instance.
  final String id;

  /// Connection target + options (host / port / url / unitId / …).
  final Map<String, dynamic> params;

  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        if (params.isNotEmpty) 'params': params,
      };
}

/// Builds an adapter instance from its [IoDeviceConfig] — constructing the
/// transport and adapter. Each instance must carry a unique adapter id (the
/// registry keys adapters by `manifest.adapterId`).
typedef IoDeviceBuilder = AdapterBase Function(IoDeviceConfig config);

/// Raised when a config cannot be provisioned.
class ProvisionException implements Exception {
  ProvisionException(this.code, this.message);

  /// `unknown_type` | `unsupported_platform`.
  final String code;
  final String message;

  @override
  String toString() => 'ProvisionException($code): $message';
}

class _Registration {
  const _Registration(this.builder, this.platforms);
  final IoDeviceBuilder builder;
  final Set<DevicePlatform> platforms;
}

/// Type-keyed driver registry with platform gating. Turns an
/// [IoDeviceConfig] into an adapter instance only when the driver supports
/// the current platform.
class IoDriverRegistry {
  final Map<String, _Registration> _drivers = {};

  /// Register a driver [type] supported on [platforms].
  void registerDriver(
    String type, {
    required Set<DevicePlatform> platforms,
    required IoDeviceBuilder builder,
  }) {
    _drivers[type] = _Registration(builder, platforms);
  }

  /// Whether a driver is registered for [type].
  bool has(String type) => _drivers.containsKey(type);

  /// Driver types available on [platform].
  Set<String> typesFor(DevicePlatform platform) => {
        for (final e in _drivers.entries)
          if (e.value.platforms.contains(platform)) e.key,
      };

  /// Build the adapter for [config] on [platform]. Throws
  /// [ProvisionException] for an unknown type or an unsupported platform.
  AdapterBase build(IoDeviceConfig config, {required DevicePlatform platform}) {
    final registration = _drivers[config.type];
    if (registration == null) {
      throw ProvisionException(
        'unknown_type',
        'no driver registered for type "${config.type}"',
      );
    }
    if (!registration.platforms.contains(platform)) {
      throw ProvisionException(
        'unsupported_platform',
        'driver "${config.type}" is not supported on ${platform.name}',
      );
    }
    return registration.builder(config);
  }
}
