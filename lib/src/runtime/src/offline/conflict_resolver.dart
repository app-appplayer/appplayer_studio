/// Conflict resolution for MCP UI DSL v1.1
///
/// Provides strategies for resolving conflicts between client-side
/// queued changes and server-side state during sync operations.
library conflict_resolver;

/// Available conflict resolution strategies
enum ConflictStrategy {
  /// Client's queued value overwrites server state
  clientWins,

  /// Server's current value takes precedence
  serverWins,

  /// Most recent timestamp wins
  lastWriteWins,

  /// Deep merge client and server objects
  merge,

  /// Notify user via callback for manual resolution
  manual,
}

/// Result of a conflict resolution attempt
class ConflictResult {
  /// The resolved value after applying the strategy
  final dynamic resolvedValue;

  /// Which strategy was actually applied
  final ConflictStrategy appliedStrategy;

  /// Whether the conflict requires user input (true when strategy is manual)
  final bool requiresUserInput;

  const ConflictResult({
    required this.resolvedValue,
    required this.appliedStrategy,
    this.requiresUserInput = false,
  });
}

/// Resolves conflicts between client and server values using a configured strategy
class ConflictResolver {
  /// The strategy to use for resolving conflicts
  final ConflictStrategy strategy;

  const ConflictResolver({this.strategy = ConflictStrategy.lastWriteWins});

  /// Parse a strategy string into the enum
  static ConflictStrategy parseStrategy(String? strategyStr) {
    switch (strategyStr) {
      case 'clientWins':
        return ConflictStrategy.clientWins;
      case 'serverWins':
        return ConflictStrategy.serverWins;
      case 'lastWriteWins':
        return ConflictStrategy.lastWriteWins;
      case 'merge':
        return ConflictStrategy.merge;
      case 'manual':
        return ConflictStrategy.manual;
      default:
        return ConflictStrategy.lastWriteWins;
    }
  }

  /// Resolve a conflict between client and server values.
  ///
  /// [clientValue] is the locally queued value.
  /// [serverValue] is the current server-side value.
  /// [clientTimestamp] and [serverTimestamp] are used for lastWriteWins.
  ConflictResult resolve(
    dynamic clientValue,
    dynamic serverValue, {
    DateTime? clientTimestamp,
    DateTime? serverTimestamp,
  }) {
    switch (strategy) {
      case ConflictStrategy.clientWins:
        return ConflictResult(
          resolvedValue: clientValue,
          appliedStrategy: ConflictStrategy.clientWins,
        );

      case ConflictStrategy.serverWins:
        return ConflictResult(
          resolvedValue: serverValue,
          appliedStrategy: ConflictStrategy.serverWins,
        );

      case ConflictStrategy.lastWriteWins:
        final clientTime = clientTimestamp ?? DateTime.fromMillisecondsSinceEpoch(0);
        final serverTime = serverTimestamp ?? DateTime.fromMillisecondsSinceEpoch(0);
        final clientIsNewer = clientTime.isAfter(serverTime);
        return ConflictResult(
          resolvedValue: clientIsNewer ? clientValue : serverValue,
          appliedStrategy: ConflictStrategy.lastWriteWins,
        );

      case ConflictStrategy.merge:
        return ConflictResult(
          resolvedValue: _deepMerge(serverValue, clientValue),
          appliedStrategy: ConflictStrategy.merge,
        );

      case ConflictStrategy.manual:
        return const ConflictResult(
          resolvedValue: null,
          appliedStrategy: ConflictStrategy.manual,
          requiresUserInput: true,
        );
    }
  }

  /// Deep merge two values, with [override] taking precedence for leaf values
  dynamic _deepMerge(dynamic base, dynamic override) {
    if (base is Map && override is Map) {
      final merged = Map<String, dynamic>.from(base);
      for (final entry in override.entries) {
        final key = entry.key.toString();
        if (merged.containsKey(key)) {
          merged[key] = _deepMerge(merged[key], entry.value);
        } else {
          merged[key] = entry.value;
        }
      }
      return merged;
    }
    // For non-map values, override wins
    return override ?? base;
  }
}
