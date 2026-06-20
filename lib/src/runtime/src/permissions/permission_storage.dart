/// Permission storage for MCP UI DSL v1.1
///
/// Persists user permission decisions using shared_preferences.
library permission_storage;

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Stores and retrieves user permission decisions
// TODO: Migrate from SharedPreferences to flutter_secure_storage or platform keychain for encrypted storage (design doc 06-permissions Section 6)
class PermissionStorage {
  static const String _keyPrefix = 'mcp_permission_';
  static const String _decisionsKey = '${_keyPrefix}decisions';

  SharedPreferences? _prefs;

  /// Current server identifier for per-server permission scoping (PM-08)
  String? _serverId;

  /// Set the server identifier for per-server permission scoping
  void setServerId(String? serverId) {
    _serverId = serverId;
  }

  /// Get the effective storage key (includes server ID if set)
  String get _effectiveDecisionsKey {
    if (_serverId != null && _serverId!.isNotEmpty) {
      return '${_keyPrefix}${_serverId!}_decisions';
    }
    return _decisionsKey;
  }

  /// Initialize the storage
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  /// Get a stored permission decision
  Future<PermissionDecision?> getDecision(
    String permissionType,
    String? scope,
  ) async {
    await init();

    final decisions = await _loadDecisions();
    final key = _makeKey(permissionType, scope);

    final stored = decisions[key];
    if (stored == null) return null;

    return PermissionDecision.fromJson(stored);
  }

  /// Store a permission decision
  Future<void> storeDecision(
    String permissionType,
    String? scope,
    PermissionDecision decision,
  ) async {
    await init();

    final decisions = await _loadDecisions();
    final key = _makeKey(permissionType, scope);

    decisions[key] = decision.toJson();
    await _saveDecisions(decisions);
  }

  /// Clear a specific permission decision
  Future<void> clearDecision(String permissionType, String? scope) async {
    await init();

    final decisions = await _loadDecisions();
    final key = _makeKey(permissionType, scope);

    decisions.remove(key);
    await _saveDecisions(decisions);
  }

  /// Clear all permission decisions
  Future<void> clearAllDecisions() async {
    await init();
    await _prefs!.remove(_effectiveDecisionsKey);
  }

  /// Get all stored decisions
  Future<Map<String, PermissionDecision>> getAllDecisions() async {
    await init();

    final decisions = await _loadDecisions();
    return decisions.map(
      (key, value) => MapEntry(key, PermissionDecision.fromJson(value)),
    );
  }

  /// Check if a decision has expired
  bool isExpired(PermissionDecision decision) {
    if (decision.expiresAt == null) return false;
    return DateTime.now().isAfter(decision.expiresAt!);
  }

  /// Remove expired decisions
  Future<void> cleanupExpired() async {
    await init();

    final decisions = await _loadDecisions();
    final keysToRemove = <String>[];

    for (final entry in decisions.entries) {
      final decision = PermissionDecision.fromJson(entry.value);
      if (isExpired(decision)) {
        keysToRemove.add(entry.key);
      }
    }

    for (final key in keysToRemove) {
      decisions.remove(key);
    }

    if (keysToRemove.isNotEmpty) {
      await _saveDecisions(decisions);
    }
  }

  // Private helpers

  String _makeKey(String permissionType, String? scope) {
    if (scope == null) return permissionType;
    return '$permissionType:$scope';
  }

  Future<Map<String, Map<String, dynamic>>> _loadDecisions() async {
    final json = _prefs!.getString(_effectiveDecisionsKey);
    if (json == null) return {};

    try {
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return decoded.map(
        (key, value) => MapEntry(key, value as Map<String, dynamic>),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveDecisions(
    Map<String, Map<String, dynamic>> decisions,
  ) async {
    await _prefs!.setString(_effectiveDecisionsKey, jsonEncode(decisions));
  }
}

/// Represents a stored permission decision
class PermissionDecision {
  /// Whether permission was granted
  final bool granted;

  /// Whether permission was explicitly revoked
  final bool revoked;

  /// When the decision was made
  final DateTime decidedAt;

  /// When the decision expires (null = never)
  final DateTime? expiresAt;

  /// Whether to remember this decision
  final bool remember;

  /// Scope of the decision (e.g., specific path or domain)
  final String? scope;

  PermissionDecision({
    required this.granted,
    required this.decidedAt,
    this.revoked = false,
    this.expiresAt,
    this.remember = false,
    this.scope,
  });

  /// Create a decision that grants permission
  factory PermissionDecision.grant({
    bool remember = false,
    Duration? expiresIn,
    String? scope,
  }) {
    final now = DateTime.now();
    return PermissionDecision(
      granted: true,
      decidedAt: now,
      expiresAt: expiresIn != null ? now.add(expiresIn) : null,
      remember: remember,
      scope: scope,
    );
  }

  /// Create a decision that denies permission
  factory PermissionDecision.deny({
    bool remember = false,
    Duration? expiresIn,
    String? scope,
  }) {
    final now = DateTime.now();
    return PermissionDecision(
      granted: false,
      decidedAt: now,
      expiresAt: expiresIn != null ? now.add(expiresIn) : null,
      remember: remember,
      scope: scope,
    );
  }

  /// Create a decision that grants permission once without remembering
  factory PermissionDecision.grantOnce({
    String? scope,
  }) {
    return PermissionDecision(
      granted: true,
      decidedAt: DateTime.now(),
      remember: false,
      scope: scope,
    );
  }

  /// Create a decision marking a previously granted permission as revoked
  factory PermissionDecision.revoke({
    String? scope,
  }) {
    return PermissionDecision(
      granted: false,
      revoked: true,
      decidedAt: DateTime.now(),
      remember: true,
      scope: scope,
    );
  }

  factory PermissionDecision.fromJson(Map<String, dynamic> json) {
    return PermissionDecision(
      granted: json['granted'] as bool,
      revoked: json['revoked'] as bool? ?? false,
      decidedAt: DateTime.parse(json['decidedAt'] as String),
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
      remember: json['remember'] as bool? ?? false,
      scope: json['scope'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'granted': granted,
      if (revoked) 'revoked': true,
      'decidedAt': decidedAt.toIso8601String(),
      if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
      'remember': remember,
      if (scope != null) 'scope': scope,
    };
  }
}
