// Decorator over [bundle.LlmPort] that records every call into the
// [TelemetryStore] + [ActivityBus] before delegating to the wrapped
// implementation. Used by [LlmAdapter] when wiring the multi-provider
// pool so every agent ask shows up in the Live Feed and the Status Bar
// token counters.
//
// PRD §FM-OBSERVE-01 / 02. The wrapper is transparent: capabilities
// flow through unchanged, and unsupported methods (embedding etc.)
// keep throwing the original UnsupportedError from the inner port.

import 'package:mcp_bundle/mcp_bundle.dart' as bundle;

import 'activity_bus.dart';
import 'activity_event.dart';
import 'telemetry_store.dart';

class RecordingLlmPort extends bundle.LlmPort {
  RecordingLlmPort({
    required this.inner,
    required this.provider,
    required this.bus,
    required this.telemetry,
  });

  final bundle.LlmPort inner;
  final String provider;
  final ActivityBus bus;
  final TelemetryStore telemetry;

  @override
  bundle.LlmCapabilities get capabilities => inner.capabilities;

  @override
  Future<bool> isAvailable() => inner.isAvailable();

  @override
  Future<bundle.LlmResponse> complete(bundle.LlmRequest request) async {
    final sw = Stopwatch()..start();
    try {
      final res = await inner.complete(request);
      sw.stop();
      _record(sw.elapsedMilliseconds, res, error: false);
      return res;
    } catch (e) {
      sw.stop();
      _record(
        sw.elapsedMilliseconds,
        null,
        error: true,
        errorText: e.toString(),
      );
      rethrow;
    }
  }

  @override
  Future<bundle.LlmResponse> completeWithTools(
    bundle.LlmRequest request,
    List<bundle.LlmTool> tools,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final res = await inner.completeWithTools(request, tools);
      sw.stop();
      _record(
        sw.elapsedMilliseconds,
        res,
        error: false,
        withTools: tools.length,
      );
      return res;
    } catch (e) {
      sw.stop();
      _record(
        sw.elapsedMilliseconds,
        null,
        error: true,
        errorText: e.toString(),
        withTools: tools.length,
      );
      rethrow;
    }
  }

  @override
  Stream<bundle.LlmChunk> completeStream(bundle.LlmRequest request) =>
      inner.completeStream(request);

  @override
  Future<List<double>> embed(String text) => inner.embed(text);

  @override
  Future<List<List<double>>> embedBatch(List<String> texts) =>
      inner.embedBatch(texts);

  void _record(
    int ms,
    bundle.LlmResponse? res, {
    required bool error,
    String? errorText,
    int? withTools,
  }) {
    final tokensIn = res?.usage?.inputTokens;
    final tokensOut = res?.usage?.outputTokens;
    telemetry.recordLlmCall(
      provider: provider,
      latencyMs: ms,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      error: error,
    );
    if (error) {
      bus.error(
        provider,
        'LLM error: ${errorText ?? "unknown"}',
        kind: ActivityKind.llmCall,
        meta: {
          'provider': provider,
          'latencyMs': ms,
          if (withTools != null) 'tools': withTools,
        },
      );
    } else {
      bus.info(
        provider,
        'LLM ${withTools != null ? "tool-call" : "complete"} '
        '${tokensIn ?? 0}→${tokensOut ?? 0} tok · ${ms}ms',
        kind: ActivityKind.llmCall,
        meta: {
          'provider': provider,
          'latencyMs': ms,
          if (tokensIn != null) 'tokensIn': tokensIn,
          if (tokensOut != null) 'tokensOut': tokensOut,
          if (withTools != null) 'tools': withTools,
        },
      );
    }
  }
}
