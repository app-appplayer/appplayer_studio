/// Resource dependency graph resolution for MCP UI DSL v1.1
///
/// Resolves resource load order based on `dependsOn` declarations,
/// detects circular dependencies at parse time, and ensures dependent
/// resources receive resolved data from their dependencies before loading.
/// (spec §Resource Dependencies)
library resource_dependency_resolver;

import 'client_resource_resolver.dart';

/// Declaration of a single resource with optional dependency info
class ResourceDeclaration {
  /// Unique key for this resource (used in bindings as {{resources.<key>}})
  final String key;

  /// The client:// URI to load (may contain binding expressions)
  final String source;

  /// Keys of resources that must be ready before this one loads
  final List<String> dependsOn;

  /// Whether failure is silently ignored for this resource
  final bool optional;

  /// Optional transformation pipeline
  final List<Map<String, dynamic>>? transform;

  const ResourceDeclaration({
    required this.key,
    required this.source,
    this.dependsOn = const [],
    this.optional = false,
    this.transform,
  });

  factory ResourceDeclaration.fromJson(String key, Map<String, dynamic> json) {
    return ResourceDeclaration(
      key: key,
      source: json['source'] as String,
      dependsOn: (json['dependsOn'] as List<dynamic>?)?.cast<String>() ?? [],
      optional: json['optional'] as bool? ?? false,
      transform: (json['transform'] as List<dynamic>?)
          ?.cast<Map<String, dynamic>>(),
    );
  }
}

/// Exception thrown when a circular dependency is detected at parse time
class ResourceCircularDependencyException implements Exception {
  final String message;
  final List<String> cycle;

  const ResourceCircularDependencyException(this.message, this.cycle);

  @override
  String toString() => 'ResourceCircularDependencyException: $message (cycle: $cycle)';
}

/// Result of resolving all resources in a dependency graph
class DependencyResolveResult {
  /// Resolved resource data keyed by resource key
  final Map<String, dynamic> resources;

  /// Errors keyed by resource key (only failed entries present)
  final Map<String, String> errors;

  const DependencyResolveResult({
    required this.resources,
    required this.errors,
  });
}

/// Resolves a set of resource declarations respecting dependency order.
///
/// Usage:
/// ```dart
/// final resolver = ResourceDependencyResolver(clientResolver);
/// resolver.validate(declarations); // throws ResourceCircularDependencyException if cycles exist
/// final result = await resolver.resolve(declarations);
/// ```
class ResourceDependencyResolver {
  final ClientResourceResolver _resolver;

  ResourceDependencyResolver(this._resolver);

  /// Validate dependency declarations for circular references.
  ///
  /// Throws [ResourceCircularDependencyException] with error code `CIRCULAR_DEPENDENCY`
  /// if any cycle is detected. Should be called at parse time before loading.
  void validate(List<ResourceDeclaration> declarations) {
    final graph = _buildGraph(declarations);
    _detectCycles(graph);
  }

  /// Resolve all resources in dependency order.
  ///
  /// Resources with no dependencies load in parallel first. Dependent
  /// resources wait for all their dependencies to reach ready state before
  /// loading (spec §Resource Dependencies rule 2).
  Future<DependencyResolveResult> resolve(
    List<ResourceDeclaration> declarations,
  ) async {
    // Validate first — throws on circular dependency
    validate(declarations);

    final byKey = {for (final d in declarations) d.key: d};
    final resolved = <String, dynamic>{};
    final errors = <String, String>{};
    final pending = declarations.map((d) => d.key).toSet();

    // Topological load: repeatedly resolve resources whose deps are all ready
    while (pending.isNotEmpty) {
      // Find all resources whose dependencies are satisfied
      final ready = pending.where((key) {
        final decl = byKey[key]!;
        return decl.dependsOn.every(
          (dep) => resolved.containsKey(dep) || errors.containsKey(dep),
        );
      }).toList();

      if (ready.isEmpty) {
        // Should not happen after cycle validation, but guard anyway
        for (final key in pending) {
          errors[key] = 'Dependency resolution stalled';
        }
        break;
      }

      // Load all ready resources in parallel
      await Future.wait(ready.map((key) async {
        pending.remove(key);
        final decl = byKey[key]!;

        // Check if any required dependency has failed
        final failedDep = decl.dependsOn.firstWhere(
          (dep) => errors.containsKey(dep) && !(byKey[dep]?.optional ?? false),
          orElse: () => '',
        );
        if (failedDep.isNotEmpty) {
          if (decl.optional) {
            // Optional resources resolve to null on dependency failure
            resolved[key] = null;
          } else {
            errors[key] = 'Dependency "$failedDep" failed';
          }
          return;
        }

        // Resolve binding expressions in source URI using ready dependency data
        final uri = _resolveSourceUri(decl.source, resolved);

        final result = await _resolver.resolve(uri);
        if (!result.success) {
          if (decl.optional) {
            // Optional resources resolve to null on load failure
            resolved[key] = null;
          } else {
            errors[key] = result.error ?? 'Failed to load $uri';
          }
          return;
        }

        dynamic value = result.jsonContent ?? result.content;
        if (decl.transform != null && decl.transform!.isNotEmpty) {
          value = ResourceTransformer.applyTransforms(value, decl.transform!);
        }
        resolved[key] = value;
      }));
    }

    return DependencyResolveResult(resources: resolved, errors: errors);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Build adjacency map: key → list of keys it depends on
  Map<String, List<String>> _buildGraph(List<ResourceDeclaration> declarations) {
    final allKeys = declarations.map((d) => d.key).toSet();
    final graph = <String, List<String>>{};

    for (final decl in declarations) {
      for (final dep in decl.dependsOn) {
        if (!allKeys.contains(dep)) {
          throw ArgumentError(
              'Resource "${decl.key}" depends on unknown key "$dep"');
        }
      }
      graph[decl.key] = decl.dependsOn;
    }
    return graph;
  }

  /// Detect cycles via DFS with coloring (white/grey/black)
  void _detectCycles(Map<String, List<String>> graph) {
    // 0 = unvisited, 1 = in stack (grey), 2 = done (black)
    final color = <String, int>{for (final k in graph.keys) k: 0};
    final path = <String>[];

    void dfs(String node) {
      color[node] = 1;
      path.add(node);

      for (final dep in graph[node] ?? []) {
        if (color[dep] == 1) {
          // Found a back-edge — extract the cycle from path
          final cycleStart = path.indexOf(dep);
          final cycle = <String>[...path.sublist(cycleStart), dep];
          throw ResourceCircularDependencyException(
            'CIRCULAR_DEPENDENCY: ${cycle.join(' → ')}',
            cycle,
          );
        }
        if (color[dep] == 0) {
          dfs(dep);
        }
      }

      path.removeLast();
      color[node] = 2;
    }

    for (final key in graph.keys) {
      if (color[key] == 0) dfs(key);
    }
  }

  /// Replace `{{resources.<key>.<path>}}` binding expressions in a source URI
  /// using already-resolved resource data.
  String _resolveSourceUri(String source, Map<String, dynamic> resolved) {
    return source.replaceAllMapped(
      RegExp(r'\{\{resources\.(\w+)\.([^}]+)\}\}'),
      (match) {
        final key = match.group(1)!;
        final path = match.group(2)!;
        final data = resolved[key];
        if (data == null) return '';
        return _selectPath(data, path)?.toString() ?? '';
      },
    );
  }

  /// Navigate a dot-notation path into nested data
  dynamic _selectPath(dynamic data, String path) {
    final parts = path.split('.');
    dynamic current = data;
    for (final part in parts) {
      if (current is Map<String, dynamic>) {
        current = current[part];
      } else {
        return null;
      }
    }
    return current;
  }
}
