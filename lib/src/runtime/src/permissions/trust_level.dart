/// Trust levels for MCP UI DSL v1.1
///
/// Defines hierarchical trust levels that control access to
/// permission-gated features and actions.
library trust_level;

/// Represents the trust level granted to a UI context
///
/// Trust levels are hierarchical - higher levels include all
/// permissions of lower levels.
enum TrustLevel {
  /// No trust - all permission-gated features are denied
  untrusted,

  /// Basic trust - standard UI interactions allowed
  basic,

  /// Elevated trust - file and network access allowed with confirmation
  elevated,

  /// Full trust - all actions allowed without confirmation
  full,
}

/// Manages the current trust level and validates permission requirements
class TrustLevelManager {
  TrustLevel _currentLevel = TrustLevel.basic;

  /// The current trust level
  TrustLevel get currentLevel => _currentLevel;

  /// Set the trust level
  void setLevel(TrustLevel level) {
    _currentLevel = level;
  }

  /// Check if current level meets required level
  ///
  /// Returns true if the current trust level is equal to or higher
  /// than the [required] level.
  bool meetsLevel(TrustLevel required) {
    return _currentLevel.index >= required.index;
  }

  /// Get the trust level required for a permission type
  ///
  /// Maps permission type strings to the minimum trust level needed
  /// to perform the associated action.
  TrustLevel getRequiredLevel(String permissionType) {
    switch (permissionType) {
      // Read-only operations require basic trust
      case 'clipboard.read':
      case 'systemInfo':
      case 'notification':
        return TrustLevel.basic;

      // File and network operations require elevated trust
      case 'file.read':
      case 'http':
      case 'clipboard.write':
        return TrustLevel.elevated;

      // Write and execution operations require full trust
      case 'file.write':
      case 'shell':
      case 'exec':
        return TrustLevel.full;

      // Unknown permission types default to full trust requirement
      default:
        return TrustLevel.full;
    }
  }

  /// Check if the current trust level allows a specific permission type
  ///
  /// Convenience method that combines [getRequiredLevel] and [meetsLevel].
  bool isPermissionAllowed(String permissionType) {
    final required = getRequiredLevel(permissionType);
    return meetsLevel(required);
  }

  /// Reset trust level to default (basic)
  void reset() {
    _currentLevel = TrustLevel.basic;
  }

  @override
  String toString() {
    return 'TrustLevelManager(level: ${_currentLevel.name})';
  }
}

/// Controls when permission requests are presented to the user
///
/// Maps to the progressive permission request timing strategy
/// defined in the design document.
enum PermissionRequestTiming {
  /// Request permission when the action first needs it (Core)
  justInTime,

  /// Request permission at startup before any interaction (Standard)
  upfront,

  /// Request permission with explanation when user triggers related UI (Standard)
  contextual,
}

/// Controls how permission prompts are displayed to the user
///
/// Different variants provide different levels of interruption
/// and visual prominence.
enum PermissionPromptVariant {
  /// Full modal dialog that blocks interaction until resolved (Core)
  modal,

  /// Non-blocking inline prompt embedded in the UI (Standard)
  inline,

  /// Persistent banner at the top or bottom of the screen (Standard)
  banner,
}
