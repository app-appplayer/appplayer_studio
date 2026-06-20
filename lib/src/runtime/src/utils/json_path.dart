/// Represents a segment in a path (e.g., "items" or "[0]")
class PathSegment {
  final String key;
  final int? index;
  final bool isArrayAccess;

  PathSegment({required this.key, this.index, this.isArrayAccess = false});
}

/// Utility for accessing nested data using path notation
class JsonPath {
  /// Get a value from a nested map using a path (e.g., "user.profile.name" or "items[0].title")
  static dynamic get(Map<String, dynamic> data, String path) {
    if (path.isEmpty) return data;

    final parts = _parsePath(path);
    dynamic current = data;

    for (final part in parts) {
      if (part.isArrayAccess) {
        // Handle array access with bracket notation
        if (current is Map<String, dynamic>) {
          current = current[part.key];
          if (current is List && part.index != null) {
            if (part.index! >= 0 && part.index! < current.length) {
              current = current[part.index!];
            } else {
              return null;
            }
          } else {
            return null;
          }
        } else if (current is List && part.index != null) {
          if (part.index! >= 0 && part.index! < current.length) {
            current = current[part.index!];
          } else {
            return null;
          }
        } else {
          return null;
        }
      } else {
        // Handle regular property access
        if (current is Map<String, dynamic>) {
          current = current[part.key];
        } else if (current is Map) {
          // Handle Map that's not Map<String, dynamic>
          current = current[part.key];
        } else if (current is List) {
          // Handle special properties for List
          if (part.key == 'length') {
            current = current.length;
          } else {
            final index = int.tryParse(part.key);
            if (index != null && index >= 0 && index < current.length) {
              current = current[index];
            } else {
              return null;
            }
          }
        } else if (current is String && part.key == 'length') {
          // Handle string length
          current = current.length;
        } else {
          return null;
        }
      }
    }

    return current;
  }

  /// Set a value in a nested map using a path
  static void set(Map<String, dynamic> data, String path, dynamic value) {
    if (path.isEmpty) return;

    final parts = _parsePath(path);
    dynamic current = data;

    // Debug logging
    // Debug logging removed

    // Navigate to the parent of the target
    for (int i = 0; i < parts.length - 1; i++) {
      final part = parts[i];

      if (part.isArrayAccess) {
        // Handle array access
        if (current is Map<String, dynamic>) {
          if (!current.containsKey(part.key)) {
            current[part.key] = [];
          }
          current = current[part.key];

          if (current is List && part.index != null) {
            // Ensure list is large enough
            while (current.length <= part.index!) {
              current.add(null);
            }
            if (i < parts.length - 1) {
              // Not the final segment, ensure we have a container for next navigation
              if (current[part.index!] == null) {
                // Check if next segment is array access to decide container type
                final nextPart = parts[i + 1];
                current[part.index!] =
                    nextPart.isArrayAccess ? [] : <String, dynamic>{};
              }
              current = current[part.index!];
            }
          }
        }
      } else {
        // Handle regular property access
        if (current is Map<String, dynamic>) {
          if (!current.containsKey(part.key)) {
            // Create container for next navigation
            if (i < parts.length - 1) {
              final nextPart = parts[i + 1];
              current[part.key] =
                  nextPart.isArrayAccess ? [] : <String, dynamic>{};
            }
          }
          if (i < parts.length - 1 && current.containsKey(part.key)) {
            current = current[part.key];
          }
        } else if (current is List) {
          final index = int.tryParse(part.key);
          if (index != null) {
            // Ensure list is large enough
            while (current.length <= index) {
              current.add(null);
            }
            if (i < parts.length - 1) {
              // Not the final segment, ensure we have a container for next navigation
              if (current[index] == null) {
                final nextPart = parts[i + 1];
                current[index] =
                    nextPart.isArrayAccess ? [] : <String, dynamic>{};
              }
              current = current[index];
            }
          }
        }
      }
    }

    // Set the final value
    final lastPart = parts.last;
    // Set the final value
    if (lastPart.isArrayAccess) {
      if (current is Map<String, dynamic>) {
        if (!current.containsKey(lastPart.key)) {
          current[lastPart.key] = [];
        }
        final list = current[lastPart.key];
        if (list is List && lastPart.index != null) {
          // Ensure list is large enough
          while (list.length <= lastPart.index!) {
            list.add(null);
          }
          list[lastPart.index!] = value;
        }
      } else if (current is List && lastPart.index != null) {
        // Ensure list is large enough
        while (current.length <= lastPart.index!) {
          current.add(null);
        }
        current[lastPart.index!] = value;
      }
    } else {
      if (current is Map<String, dynamic>) {
        current[lastPart.key] = value;
      } else if (current is Map) {
        // Handle Map that's not Map<String, dynamic>
        (current)[lastPart.key] = value;
      } else if (current is List) {
        final index = int.tryParse(lastPart.key);
        if (index != null) {
          // Ensure list is large enough
          while (current.length <= index) {
            current.add(null);
          }
          current[index] = value;
        }
      }
    }
  }

  /// Delete a value from a nested map using a path
  static void delete(Map<String, dynamic> data, String path) {
    if (path.isEmpty) return;

    final parts = _parsePath(path);
    dynamic current = data;
    final List<dynamic> parents = [data];

    // Navigate to the parent of the target
    for (int i = 0; i < parts.length - 1; i++) {
      final part = parts[i];

      if (part.isArrayAccess) {
        if (current is Map<String, dynamic> && current.containsKey(part.key)) {
          current = current[part.key];
          if (current is List &&
              part.index != null &&
              part.index! >= 0 &&
              part.index! < current.length) {
            parents.add(current);
            current = current[part.index!];
          } else {
            return; // Path doesn't exist
          }
        } else {
          return; // Path doesn't exist
        }
      } else {
        if (current is Map<String, dynamic> && current.containsKey(part.key)) {
          current = current[part.key];
          parents.add(current);
        } else if (current is List) {
          final index = int.tryParse(part.key);
          if (index != null && index >= 0 && index < current.length) {
            current = current[index];
            parents.add(current);
          } else {
            return; // Path doesn't exist
          }
        } else {
          return; // Path doesn't exist
        }
      }
    }

    // Remove the final value
    final lastPart = parts.last;
    final parent = parents.last;

    if (lastPart.isArrayAccess) {
      if (parent is Map<String, dynamic> && parent.containsKey(lastPart.key)) {
        final list = parent[lastPart.key];
        if (list is List &&
            lastPart.index != null &&
            lastPart.index! >= 0 &&
            lastPart.index! < list.length) {
          list.removeAt(lastPart.index!);
        }
      }
    } else {
      if (parent is Map<String, dynamic>) {
        parent.remove(lastPart.key);
      } else if (parent is List) {
        final index = int.tryParse(lastPart.key);
        if (index != null && index >= 0 && index < parent.length) {
          parent.removeAt(index);
        }
      }
    }
  }

  /// Check if a path exists in the data
  static bool exists(Map<String, dynamic> data, String path) {
    return get(data, path) != null;
  }

  /// Get all paths that match a pattern (simple wildcard support)
  static List<String> findPaths(Map<String, dynamic> data, String pattern) {
    final paths = <String>[];
    _findPathsRecursive(data, '', pattern, paths);
    return paths;
  }

  static void _findPathsRecursive(
    dynamic current,
    String currentPath,
    String pattern,
    List<String> results,
  ) {
    if (current is Map<String, dynamic>) {
      current.forEach((key, value) {
        final newPath = currentPath.isEmpty ? key : '$currentPath.$key';

        if (_matchesPattern(newPath, pattern)) {
          results.add(newPath);
        }

        _findPathsRecursive(value, newPath, pattern, results);
      });
    } else if (current is List) {
      for (int i = 0; i < current.length; i++) {
        final newPath = currentPath.isEmpty ? i.toString() : '$currentPath.$i';

        if (_matchesPattern(newPath, pattern)) {
          results.add(newPath);
        }

        _findPathsRecursive(current[i], newPath, pattern, results);
      }
    }
  }

  static bool _matchesPattern(String path, String pattern) {
    // Simple wildcard matching (* for any segment)
    if (pattern == '*') return true;
    if (pattern == path) return true;

    final patternParts = pattern.split('.');
    final pathParts = path.split('.');

    if (patternParts.length != pathParts.length) return false;

    for (int i = 0; i < patternParts.length; i++) {
      if (patternParts[i] != '*' && patternParts[i] != pathParts[i]) {
        return false;
      }
    }

    return true;
  }

  /// Parse a path string into segments, handling bracket notation
  static List<PathSegment> _parsePath(String path) {
    final segments = <PathSegment>[];
    final buffer = StringBuffer();
    var i = 0;

    while (i < path.length) {
      final char = path[i];

      if (char == '.') {
        // End of a segment
        if (buffer.isNotEmpty) {
          segments.add(PathSegment(key: buffer.toString()));
          buffer.clear();
        }
        i++;
      } else if (char == '[') {
        // Start of array index
        if (buffer.isNotEmpty) {
          final key = buffer.toString();
          buffer.clear();

          // Find the closing bracket
          final closingIndex = path.indexOf(']', i);
          if (closingIndex == -1) {
            throw FormatException('Missing closing bracket in path: $path');
          }

          final indexStr = path.substring(i + 1, closingIndex);
          final index = int.tryParse(indexStr);

          if (index == null) {
            throw FormatException('Invalid array index: $indexStr');
          }

          segments
              .add(PathSegment(key: key, index: index, isArrayAccess: true));
          i = closingIndex + 1;

          // Skip optional dot after bracket
          if (i < path.length && path[i] == '.') {
            i++;
          }
        } else {
          throw FormatException('Array index without property name: $path');
        }
      } else {
        buffer.write(char);
        i++;
      }
    }

    // Add the last segment if any
    if (buffer.isNotEmpty) {
      segments.add(PathSegment(key: buffer.toString()));
    }

    return segments;
  }
}
