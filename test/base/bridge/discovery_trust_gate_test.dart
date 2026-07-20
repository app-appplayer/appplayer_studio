/// The discovery trust SEAM (spec 17 §6) wired into `discovery_tools`:
/// probe-confirmed candidates carry signature evidence, and — when signature
/// enforcement is on — the auto-connect sweep and `connectCandidate` gate on
/// it (fail-closed). Uses a fake evaluator (the real-crypto verifier is
/// covered by discovery_trust_test); the gate decision is observed WITHOUT any
/// socket by connecting a bogus-transport candidate — the trust gate fires
/// before the transport is built.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:appplayer_studio/base.dart' show registerDiscoveryTools;
import 'package:appplayer_studio/src/base/bridge/device_discovery/device_discovery.dart';
import 'package:appplayer_studio/src/base/bridge/discovery_trust.dart';
import 'package:brain_kernel/brain_kernel.dart' as fb;
import 'package:brain_kernel/mcp_host.dart' show McpClientKernelHost;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_client/mcp_client.dart' show ClientTransport;

class _FakeMdnsScanner extends MdnsBoardScanner {
  _FakeMdnsScanner(this.candidates);
  final List<MdnsBoardCandidate> candidates;

  @override
  Stream<MdnsBoardCandidate> scan({
    Duration timeout = const Duration(seconds: 5),
    Duration recordTimeout = const Duration(seconds: 2),
  }) =>
      Stream.fromIterable(candidates);
}

MdnsBoardCandidate _cand(String name) => MdnsBoardCandidate(
      host: '192.168.0.10',
      port: 6270,
      instanceName: name,
      txt: MdnsTxt.parse('proto=ndjson\nid=acme.$name\nv=0.1.0'),
    );

/// A probe that returns an identity whose manifest carries [trust] (or none
/// when null) — the fake evaluator reads that marker.
_ProbeStub _probeReturning(Object? trust) => _ProbeStub(trust);

class _ProbeStub {
  _ProbeStub(this.trust);
  final Object? trust;

  Future<BoardIdentity?> call({
    required FutureOr<ClientTransport> Function() buildTransport,
    Duration timeout = const Duration(seconds: 10),
    String clientName = '',
    String clientVersion = '',
  }) async =>
      BoardIdentity(
        id: 'acme.good',
        name: 'Good Board',
        version: '0.1.0',
        entryPoint: 'ui://app',
        manifest: <String, Object?>{
          'id': 'acme.good',
          'name': 'Good Board',
          if (trust != null) 'trust': trust,
        },
      );
}

/// Fake evaluator: `trust:'valid'` → verified, `trust:'bad'` → signed but
/// unverified, no trust → unsigned (null evidence).
Future<TrustEvidence?> _fakeEval(BoardIdentity identity) async {
  final trust = identity.manifest?['trust'];
  if (trust == null) return null;
  final ok = trust == 'valid';
  return TrustEvidence(partnerChainValid: ok, signatureValid: ok);
}

({fb.HostToolRegistry registry, Map<String, fb.KernelToolHandler> handlers})
    _captureRegistry(fb.KernelApp app, String label) {
  final handlers = <String, fb.KernelToolHandler>{};
  final endpoint = app.addEndpoint(label: label, appName: label);
  endpoint.server.register();
  final registry = fb.HostToolRegistry(
    endpoint: endpoint.server,
    attachToDispatcher: (name, handler) => handlers[name] = handler,
    detachFromDispatcher: (_) {},
  );
  return (registry: registry, handlers: handlers);
}

void main() {
  late Directory tmpDir;
  late fb.KernelApp app;
  late McpClientKernelHost clientHost;

  setUpAll(() async {
    tmpDir = Directory.systemTemp.createTempSync('vibe_studio_trust_');
    clientHost = McpClientKernelHost();
    app = await fb.KernelApp.boot(
      workspaceId: 'vibe_studio_trust_test',
      kvStorage: fb.KvStoragePortAdapter(rootDir: tmpDir.path),
      bundleRegistryStorageDir: tmpDir.path,
      clientHost: clientHost,
    );
  });

  tearDownAll(() async {
    await clientHost.shutdown();
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {/* best-effort */}
  });

  test('no evaluator wired → candidates carry no trust field', () async {
    final cap = _captureRegistry(app, 'trust-none');
    final d = registerDiscoveryTools(
      cap.registry,
      clientHost,
      mdnsScanner: _FakeMdnsScanner([_cand('good')]),
      probe: _probeReturning('valid').call,
    );
    final out = await d.discover('mdns');
    final candidates = (out['candidates'] as List).cast<Map>();
    expect(candidates, hasLength(1));
    expect(candidates.first.containsKey('trust'), isFalse);
  });

  test('evaluator wired → signed+valid candidate is verified', () async {
    final cap = _captureRegistry(app, 'trust-valid');
    final d = registerDiscoveryTools(
      cap.registry,
      clientHost,
      mdnsScanner: _FakeMdnsScanner([_cand('good')]),
      probe: _probeReturning('valid').call,
      trustEvaluator: _fakeEval,
    );
    final out = await d.discover('mdns');
    final trust = (out['candidates'] as List).cast<Map>().first['trust'] as Map;
    expect(trust['signed'], isTrue);
    expect(trust['verified'], isTrue);
    expect(trust['partnerChainValid'], isTrue);
  });

  test('evaluator wired → unsigned candidate is signed:false', () async {
    final cap = _captureRegistry(app, 'trust-unsigned');
    final d = registerDiscoveryTools(
      cap.registry,
      clientHost,
      mdnsScanner: _FakeMdnsScanner([_cand('good')]),
      probe: _probeReturning(null).call, // no trust block
      trustEvaluator: _fakeEval,
    );
    final out = await d.discover('mdns');
    final trust = (out['candidates'] as List).cast<Map>().first['trust'] as Map;
    expect(trust['signed'], isFalse);
    expect(trust['verified'], isFalse);
  });

  test('enforce on + unverified → connectCandidate throws the trust error',
      () async {
    var enforce = true;
    final cap = _captureRegistry(app, 'trust-gate-on');
    final d = registerDiscoveryTools(
      cap.registry,
      clientHost,
      trustEvaluator: _fakeEval,
      enforceSignature: () => enforce,
    );
    // No 'trust' field (or unverified) + enforcement on ⇒ fail-closed reject,
    // BEFORE the (bogus) transport is ever built.
    final candidate = <String, dynamic>{
      'id': 'acme.good',
      'connectHint': <String, dynamic>{
        'tool': 'mcp.connect_extension',
        'transport': 'bogus',
      },
    };
    await expectLater(
      () => d.connectCandidate(candidate),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('signature enforcement'))),
    );

    // Enforcement off ⇒ the trust gate lets it through; it then fails on the
    // bogus transport instead — proving the gate decision flipped, no socket.
    enforce = false;
    await expectLater(
      () => d.connectCandidate(candidate),
      throwsA(isA<StateError>().having((e) => e.message, 'message',
          contains('unsupported extension transport'))),
    );
  });

  test('enforce on → sweep blocks the unverified board (no connect)', () async {
    final cap = _captureRegistry(app, 'trust-sweep');
    final d = registerDiscoveryTools(
      cap.registry,
      clientHost,
      mdnsScanner: _FakeMdnsScanner([_cand('good')]),
      probe: _probeReturning('bad').call, // signed but does not verify
      trustEvaluator: _fakeEval,
      enforceSignature: () => true,
    );
    final report = await d.sweep(
      usb: false,
      mdns: true,
      directory: false,
      autoConnect: true,
    );
    expect(report['blocked'], contains('board:acme.good'));
    expect(report['connected'], isEmpty);
    // No socket was opened — the gate fired before transport construction.
    expect(report['errors'], isEmpty);
  });
}
