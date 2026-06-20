/// Permission groups for MCP UI DSL v1.1
///
/// Groups related permissions together for easier management
/// and user-facing display.
library permission_groups;

/// Represents a named group of related permissions
///
/// Permission groups allow bundling related permissions (e.g., all file
/// permissions) under a single label for easier management and display.
class PermissionGroup {
  /// Unique identifier for the group
  final String id;

  /// Human-readable label for the group
  final String label;

  /// Optional icon identifier for the group
  final String? icon;

  /// Optional description explaining what this group covers
  final String? description;

  /// List of permission type strings in this group
  final List<String> permissions;

  /// Whether this permission group is required for the app to function
  final bool required;

  /// Create a permission group
  const PermissionGroup({
    required this.id,
    required this.label,
    this.icon,
    this.description,
    required this.permissions,
    this.required = false,
  });

  /// Create a permission group from a JSON map
  factory PermissionGroup.fromJson(Map<String, dynamic> json) {
    return PermissionGroup(
      id: json['id'] as String,
      label: json['label'] as String,
      icon: json['icon'] as String?,
      description: json['description'] as String?,
      permissions: (json['permissions'] as List<dynamic>)
          .map((e) => e as String)
          .toList(),
      required: json['required'] as bool? ?? false,
    );
  }

  /// Serialize this group to a JSON map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'label': label,
      if (icon != null) 'icon': icon,
      if (description != null) 'description': description,
      'permissions': permissions,
      if (required) 'required': required,
    };
  }

  /// Check if this group contains a specific permission
  bool containsPermission(String permission) {
    return permissions.contains(permission);
  }

  @override
  String toString() {
    return 'PermissionGroup(id: $id, label: $label, '
        'permissions: ${permissions.length})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PermissionGroup && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// Manages registration and lookup of permission groups
class PermissionGroupManager {
  final Map<String, PermissionGroup> _groups = {};

  /// Reverse index: permission -> group id
  final Map<String, String> _permissionToGroup = {};

  /// Register a permission group
  ///
  /// If a group with the same [id] already exists, it will be replaced.
  /// Permissions are re-indexed on each registration.
  void registerGroup(PermissionGroup group) {
    // Remove old reverse index entries if replacing
    final existing = _groups[group.id];
    if (existing != null) {
      for (final permission in existing.permissions) {
        _permissionToGroup.remove(permission);
      }
    }

    _groups[group.id] = group;

    // Build reverse index
    for (final permission in group.permissions) {
      _permissionToGroup[permission] = group.id;
    }
  }

  /// Unregister a permission group by its id
  void unregisterGroup(String id) {
    final group = _groups.remove(id);
    if (group != null) {
      for (final permission in group.permissions) {
        if (_permissionToGroup[permission] == id) {
          _permissionToGroup.remove(permission);
        }
      }
    }
  }

  /// Get a permission group by its id
  PermissionGroup? getGroup(String id) {
    return _groups[id];
  }

  /// Get all permission type strings for a group
  ///
  /// Returns an empty list if the group is not found.
  List<String> getPermissionsForGroup(String groupId) {
    final group = _groups[groupId];
    if (group == null) return [];
    return List<String>.unmodifiable(group.permissions);
  }

  /// Get the group id that contains a specific permission
  ///
  /// Returns null if the permission is not in any group.
  String? getGroupForPermission(String permission) {
    return _permissionToGroup[permission];
  }

  /// Get all registered group ids
  List<String> get groupIds => _groups.keys.toList();

  /// Get all registered groups
  List<PermissionGroup> get groups => _groups.values.toList();

  /// Check if a group is registered
  bool hasGroup(String id) => _groups.containsKey(id);

  /// Clear all registered groups
  void clear() {
    _groups.clear();
    _permissionToGroup.clear();
  }

  @override
  String toString() {
    return 'PermissionGroupManager(groups: ${_groups.length})';
  }
}
