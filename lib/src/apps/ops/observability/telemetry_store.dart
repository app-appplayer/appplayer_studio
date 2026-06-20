// Cumulative counters for token usage, latency, and call counts.
// Defined in PRD §FM-OBSERVE-02.
//
// Status Bar reads aggregates for the live readout; Diagnostic Export
// dumps the per-provider breakdown into the support bundle.

import 'dart:async';
import 'dart:collection';

class ProviderCounters {
  ProviderCounters(this.provider);

  final String provider;
  int calls = 0;
  int errors = 0;
  int tokensIn = 0;
  int tokensOut = 0;

  /// Latency samples, capped to the most recent 200. Keeps p50/p95
  /// computable without unbounded memory.
  final Queue<int> _latencySamples = Queue<int>();
  static const int _latencyCap = 200;

  void recordLatency(int ms) {
    _latencySamples.addLast(ms);
    while (_latencySamples.length > _latencyCap) {
      _latencySamples.removeFirst();
    }
  }

  int get p50 => _percentile(0.5);
  int get p95 => _percentile(0.95);

  int _percentile(double p) {
    if (_latencySamples.isEmpty) return 0;
    final sorted = List<int>.from(_latencySamples)..sort();
    final idx = (sorted.length * p).floor().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'calls': calls,
    'errors': errors,
    'tokensIn': tokensIn,
    'tokensOut': tokensOut,
    'latencyP50Ms': p50,
    'latencyP95Ms': p95,
    'samples': _latencySamples.length,
  };
}

class ToolCounters {
  ToolCounters();
  int calls = 0;
  int errors = 0;
  int totalLatencyMs = 0;

  Map<String, Object?> toJson() => {
    'calls': calls,
    'errors': errors,
    'avgLatencyMs': calls > 0 ? totalLatencyMs ~/ calls : 0,
  };
}

class TelemetryStore {
  TelemetryStore();

  final Map<String, ProviderCounters> _providers = {};
  final Map<String, ToolCounters> _tools = {};
  int _mcpInboundRequests = 0;
  int _agentAsks = 0;
  DateTime? _bootAt;

  final StreamController<void> _ticks = StreamController<void>.broadcast(
    sync: false,
  );

  Stream<void> get ticks => _ticks.stream;

  void markBoot() {
    _bootAt = DateTime.now();
  }

  Duration get uptime =>
      _bootAt == null ? Duration.zero : DateTime.now().difference(_bootAt!);

  ProviderCounters _provider(String p) =>
      _providers.putIfAbsent(p, () => ProviderCounters(p));

  ToolCounters _tool(String t) => _tools.putIfAbsent(t, () => ToolCounters());

  void recordLlmCall({
    required String provider,
    required int latencyMs,
    int? tokensIn,
    int? tokensOut,
    bool error = false,
  }) {
    final c = _provider(provider);
    c.calls += 1;
    if (error) c.errors += 1;
    if (tokensIn != null) c.tokensIn += tokensIn;
    if (tokensOut != null) c.tokensOut += tokensOut;
    c.recordLatency(latencyMs);
    _bump();
  }

  void recordToolDispatch({
    required String tool,
    required int latencyMs,
    bool error = false,
  }) {
    final c = _tool(tool);
    c.calls += 1;
    c.totalLatencyMs += latencyMs;
    if (error) c.errors += 1;
    _bump();
  }

  void recordMcpInbound() {
    _mcpInboundRequests += 1;
    _bump();
  }

  void recordAgentAsk() {
    _agentAsks += 1;
    _bump();
  }

  int get totalLlmCalls => _providers.values.fold(0, (sum, c) => sum + c.calls);
  int get totalLlmErrors =>
      _providers.values.fold(0, (sum, c) => sum + c.errors);
  int get totalTokensIn =>
      _providers.values.fold(0, (sum, c) => sum + c.tokensIn);
  int get totalTokensOut =>
      _providers.values.fold(0, (sum, c) => sum + c.tokensOut);
  int get mcpInboundRequests => _mcpInboundRequests;
  int get agentAsks => _agentAsks;

  Map<String, ProviderCounters> get providers =>
      UnmodifiableMapView(_providers);
  Map<String, ToolCounters> get tools => UnmodifiableMapView(_tools);

  void _bump() {
    if (!_ticks.isClosed) _ticks.add(null);
  }

  Map<String, Object?> toJson() => {
    'uptimeSec': uptime.inSeconds,
    'totals': {
      'llmCalls': totalLlmCalls,
      'llmErrors': totalLlmErrors,
      'tokensIn': totalTokensIn,
      'tokensOut': totalTokensOut,
      'mcpInbound': mcpInboundRequests,
      'agentAsks': agentAsks,
    },
    'providers': [for (final p in _providers.values) p.toJson()],
    'tools': {for (final e in _tools.entries) e.key: e.value.toJson()},
  };

  Future<void> dispose() async {
    await _ticks.close();
  }
}
