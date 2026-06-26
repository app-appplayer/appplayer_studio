/// Reference — standard construction of a real `AnalysisPort` for hosts.
///
/// Recipe-level **wiring**: composes `mcp_analysis`'s already-public
/// components into a working in-memory `AnalysisPort` so a host adopts the
/// full engine in ONE line (`standardAnalysisPort()`) instead of hand-wiring
/// ~20 components — which would diverge across Studio / AppPlayer. No
/// `mcp_analysis` modification; pure composition over its public API. A
/// persistent variant swaps the in-memory `StoragePort` + no-op ports below
/// for host-supplied implementations.
library;

import 'package:mcp_analysis/mcp_analysis.dart';
import 'package:mcp_bundle/ports.dart';

/// Build a ready-to-use in-memory [AnalysisPort] — the full engine
/// (spec / execution [batch·adhoc·stream] / artifact / audit / RBAC) with the
/// seven built-in analysis functions registered. [eventPort] / [metricPort]
/// wire alert delivery / telemetry; both default to no-op.
AnalysisPort standardAnalysisPort({
  EventPort? eventPort,
  MetricPort? metricPort,
}) {
  final specManager = SpecManager(
    storage: _InMemoryStorage<AnalysisSpec>(),
    validator: SpecValidator(),
    parameterResolver: ParameterResolver(),
  );
  final jobManager = JobManager(storage: _InMemoryStorage<AnalysisJob>());
  final artifactStore = ArtifactStore(
    storage: _InMemoryStorage<AnalysisArtifact>(),
  );
  final dataSourceRegistry = DataSourceRegistry();

  final catalog = FunctionCatalog();
  final functionDispatcher = FunctionDispatcher(catalog: catalog);
  for (final fn in <AnalysisFunction>[
    DescriptiveStatsFunction(),
    AnomalyDetectFunction(),
    EventAnalysisFunction(),
    TimeSeriesFunction(),
    CorrelationRegressionFunction(),
    RuleBasedClassificationFunction(),
    SeasonalityFunction(),
  ]) {
    catalog.register(fn.info);
    functionDispatcher.registerImplementation(fn.info.functionName, fn);
  }

  final alertEvaluator = AlertEvaluator(
    publisher: AlertPublisher(eventPort: eventPort ?? _NoopEventPort()),
  );
  final transformPipeline = TransformPipeline();
  final artifactBuilder = ArtifactBuilder();
  final provenanceTracker = ProvenanceTracker();

  final batchExecutor = BatchExecutor(
    jobManager: jobManager,
    dataSourceRegistry: dataSourceRegistry,
    transformPipeline: transformPipeline,
    functionDispatcher: functionDispatcher,
    artifactBuilder: artifactBuilder,
    artifactStore: artifactStore,
    provenanceTracker: provenanceTracker,
    alertEvaluator: alertEvaluator,
  );
  final adhocExecutor = AdhocExecutor(
    jobManager: jobManager,
    dataSourceRegistry: dataSourceRegistry,
    transformPipeline: transformPipeline,
    functionDispatcher: functionDispatcher,
    artifactBuilder: artifactBuilder,
    artifactStore: artifactStore,
    provenanceTracker: provenanceTracker,
    alertEvaluator: alertEvaluator,
  );
  final streamExecutor = StreamExecutor(
    jobManager: jobManager,
    dataSourceRegistry: dataSourceRegistry,
    transformPipeline: transformPipeline,
    artifactBuilder: artifactBuilder,
    artifactStore: artifactStore,
    provenanceTracker: provenanceTracker,
    alertEvaluator: alertEvaluator,
  );

  final executionEngine = ExecutionEngine(
    specManager: specManager,
    jobManager: jobManager,
    batchExecutor: batchExecutor,
    adhocExecutor: adhocExecutor,
    streamExecutor: streamExecutor,
    rbac: RbacPolicy(),
    auditLogger: AuditLogger(storage: _InMemoryStorage<AuditRecord>()),
    metricPort: metricPort ?? _NoopMetricPort(),
  );

  return AnalysisPortAdapter(
    specManager: specManager,
    executionEngine: executionEngine,
    artifactStore: artifactStore,
    dataSourceRegistry: dataSourceRegistry,
    alertEvaluator: alertEvaluator,
  );
}

/// Trivial in-memory [StoragePort] — recipe wiring helper (not package core).
class _InMemoryStorage<T> implements StoragePort<T> {
  final Map<String, T> _store = <String, T>{};

  @override
  Future<void> save(String id, T item) async => _store[id] = item;

  @override
  Future<T?> get(String id) async => _store[id];

  @override
  Future<void> delete(String id) async => _store.remove(id);

  @override
  Future<List<T>> getAll() async => _store.values.toList();

  @override
  Future<List<T>> query(Map<String, dynamic> criteria) async =>
      _store.values.toList();

  @override
  Future<bool> exists(String id) async => _store.containsKey(id);
}

class _NoopEventPort implements EventPort {
  @override
  Future<void> publish(PortEvent event) async {}

  @override
  Stream<PortEvent> subscribe(String eventType) =>
      const Stream<PortEvent>.empty();

  @override
  Stream<PortEvent> subscribeAll() => const Stream<PortEvent>.empty();

  @override
  Future<void> unsubscribe(String eventType) async {}
}

class _NoopMetricPort implements MetricPort {
  @override
  Future<MetricValue> compute(
    String metricName,
    Map<String, dynamic> context,
  ) async => MetricValue(value: 0.0, timestamp: DateTime.now());

  @override
  Future<void> record(
    String metricName,
    double value, {
    Map<String, String>? tags,
  }) async {}

  @override
  Stream<MetricEvent> watch(String metricName) =>
      const Stream<MetricEvent>.empty();

  @override
  Future<List<MetricValue>> history(
    String metricName, {
    DateTime? start,
    DateTime? end,
    int? limit,
  }) async => <MetricValue>[];
}
