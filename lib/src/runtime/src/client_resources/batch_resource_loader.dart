/// Batch resource loading for MCP UI DSL v1.1
///
/// Supports loading multiple resources in a single declaration with
/// configurable load strategy and failure policy (spec §Batch Resource Loading).
library batch_resource_loader;

import 'client_resource_resolver.dart';

/// A single source entry in a batch resource declaration
class BatchResourceSource {
  /// Key used to access this resource in results
  final String key;

  /// The client:// URI to load
  final String source;

  /// Whether failure of this source should be silently ignored
  final bool optional;

  /// Optional transformation pipeline to apply after loading
  final List<Map<String, dynamic>>? transform;

  const BatchResourceSource({
    required this.key,
    required this.source,
    this.optional = false,
    this.transform,
  });

  factory BatchResourceSource.fromJson(Map<String, dynamic> json) {
    return BatchResourceSource(
      key: json['key'] as String,
      source: json['source'] as String,
      optional: json['optional'] as bool? ?? false,
      transform: (json['transform'] as List<dynamic>?)
          ?.cast<Map<String, dynamic>>(),
    );
  }
}

/// Result of a batch resource load operation
class BatchResourceResult {
  /// Results keyed by source key — value is the resolved content or null if failed
  final Map<String, dynamic> results;

  /// Errors keyed by source key (only present entries that failed)
  final Map<String, String> errors;

  /// Whether the overall batch succeeded (depends on failurePolicy)
  final bool success;

  /// Error message if the batch failed as a whole
  final String? error;

  const BatchResourceResult._({
    required this.results,
    required this.errors,
    required this.success,
    this.error,
  });

  factory BatchResourceResult.success({
    required Map<String, dynamic> results,
    required Map<String, String> errors,
  }) =>
      BatchResourceResult._(
        results: results,
        errors: errors,
        success: true,
      );

  factory BatchResourceResult.failure(String message) =>
      BatchResourceResult._(
        results: {},
        errors: {},
        success: false,
        error: message,
      );
}

/// Loads multiple client resources in a single operation.
///
/// Supports parallel and sequential load strategies with configurable
/// failure policies per spec §Batch Resource Loading.
class BatchResourceLoader {
  final ClientResourceResolver _resolver;

  BatchResourceLoader(this._resolver);

  /// Load a batch of resources.
  ///
  /// [sources] — list of source entries to load.
  /// [loadStrategy] — `"parallel"` (default) or `"sequential"`.
  /// [failurePolicy] — `"fail-fast"`, `"continue"` (default), or `"retry"`.
  Future<BatchResourceResult> loadBatch({
    required List<BatchResourceSource> sources,
    String loadStrategy = 'parallel',
    String failurePolicy = 'continue',
  }) async {
    if (sources.isEmpty) {
      return BatchResourceResult.success(results: {}, errors: {});
    }

    switch (loadStrategy) {
      case 'sequential':
        return _loadSequential(sources, failurePolicy);
      case 'parallel':
      default:
        return _loadParallel(sources, failurePolicy);
    }
  }

  /// Load sources in parallel using Future.wait
  Future<BatchResourceResult> _loadParallel(
    List<BatchResourceSource> sources,
    String failurePolicy,
  ) async {
    final futures = sources.map((s) => _loadOne(s));
    final entries = await Future.wait(futures);

    return _buildResult(sources, entries, failurePolicy);
  }

  /// Load sources one after another in declaration order
  Future<BatchResourceResult> _loadSequential(
    List<BatchResourceSource> sources,
    String failurePolicy,
  ) async {
    final entries = <_SourceLoadResult>[];
    for (final source in sources) {
      final result = await _loadOne(source);
      entries.add(result);

      // fail-fast: abort immediately on first non-optional failure
      if (!result.ok && !source.optional && failurePolicy == 'fail-fast') {
        return BatchResourceResult.failure(
            'Batch load failed at key "${source.key}": ${result.error}');
      }
    }
    return _buildResult(sources, entries, failurePolicy);
  }

  /// Build the final BatchResourceResult from individual load results
  BatchResourceResult _buildResult(
    List<BatchResourceSource> sources,
    List<_SourceLoadResult> entries,
    String failurePolicy,
  ) {
    final results = <String, dynamic>{};
    final errors = <String, String>{};

    for (var i = 0; i < sources.length; i++) {
      final source = sources[i];
      final entry = entries[i];

      if (entry.ok) {
        // Apply transforms if specified
        dynamic value = entry.value;
        if (source.transform != null && source.transform!.isNotEmpty) {
          value = ResourceTransformer.applyTransforms(value, source.transform!);
        }
        results[source.key] = value;
      } else {
        errors[source.key] = entry.error ?? 'Unknown error';
        if (!source.optional) {
          results[source.key] = null;
          if (failurePolicy == 'fail-fast') {
            return BatchResourceResult.failure(
                'Batch load failed at key "${source.key}": ${entry.error}');
          }
        }
        // optional source failure: omit from results silently
      }
    }

    // fail-fast with non-optional errors should have already returned above
    return BatchResourceResult.success(results: results, errors: errors);
  }

  /// Load a single source and return a typed result wrapper
  Future<_SourceLoadResult> _loadOne(BatchResourceSource source) async {
    final result = await _resolver.resolve(source.source);
    if (!result.success) {
      return _SourceLoadResult(ok: false, error: result.error);
    }
    return _SourceLoadResult(ok: true, value: result.jsonContent ?? result.content);
  }
}

/// Internal wrapper for a single source load outcome
class _SourceLoadResult {
  final bool ok;
  final dynamic value;
  final String? error;

  const _SourceLoadResult({required this.ok, this.value, this.error});
}
