/// Bundle-host-bridge session module tests. Covers session lifecycle
/// (attach / close), SessionRegistry indexing, and KbResourceRef
/// URI parsing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_studio/base.dart';

DispatchSession _session(String bundleId, {bool master = false, int n = 1}) =>
    DispatchSession(
      sessionId: '$bundleId#$n',
      bundleId: bundleId,
      master: master,
    );

void main() {
  group('DispatchSession.attach + close', () {
    test('closeAttached fires every handle', () async {
      final s = _session('a');
      final h1 = TestSessionHandle('h1');
      final h2 = TestSessionHandle('h2');
      s.attach(h1);
      s.attach(h2);
      await s.closeAttached();
      expect(h1.closed, isTrue);
      expect(h2.closed, isTrue);
      expect(s.isClosed, isTrue);
    });

    test('attach after close fires close immediately', () async {
      final s = _session('a');
      await s.closeAttached();
      final h = TestSessionHandle('h');
      s.attach(h);
      // sync close path — wait one tick for the unawaited Future.
      await Future<void>.delayed(Duration.zero);
      expect(h.closed, isTrue);
    });

    test('detach removes without firing', () async {
      final s = _session('a');
      final h = TestSessionHandle('h');
      s.attach(h);
      s.detach(h);
      await s.closeAttached();
      expect(h.closed, isFalse);
    });
  });

  group('SessionRegistry', () {
    setUp(() => SessionRegistry.instance.clearForTesting());
    tearDown(() => SessionRegistry.instance.clearForTesting());

    test('register / get / count / remove', () {
      final s = _session('a');
      SessionRegistry.instance.register(s);
      expect(SessionRegistry.instance.count, 1);
      expect(SessionRegistry.instance.get(s.sessionId), same(s));
      SessionRegistry.instance.remove(s.sessionId);
      expect(SessionRegistry.instance.count, 0);
    });

    test('forBundle returns every session for one bundle', () {
      final s1 = _session('a', n: 1);
      final s2 = _session('a', n: 2);
      final s3 = _session('b', n: 1);
      SessionRegistry.instance.register(s1);
      SessionRegistry.instance.register(s2);
      SessionRegistry.instance.register(s3);
      final aSessions = SessionRegistry.instance.forBundle('a');
      expect(aSessions, hasLength(2));
      expect(aSessions, containsAll(<DispatchSession>[s1, s2]));
    });
  });

  group('KbResourceRef.parse', () {
    test('valid 8 facade URIs', () {
      for (final facade in KbFacade.values) {
        final ref = KbResourceRef.parse('kb://${facade.scheme}/some_id');
        expect(ref, isNotNull, reason: 'failed to parse ${facade.scheme}');
        expect(ref!.facade, facade);
        expect(ref.id, 'some_id');
      }
    });

    test('preserves cross-bundle full-name id', () {
      final ref = KbResourceRef.parse('kb://fact/app_builder.preview_size');
      expect(ref?.id, 'app_builder.preview_size');
    });

    test('rejects invalid scheme / unknown facade / empty id', () {
      expect(KbResourceRef.parse('http://fact/foo'), isNull);
      expect(KbResourceRef.parse('kb://bogus/foo'), isNull);
      expect(KbResourceRef.parse('kb://fact/'), isNull);
      expect(KbResourceRef.parse('kb://fact'), isNull);
    });

    test('round-trip toUri()', () {
      const uri = 'kb://skill/app_a.compile';
      expect(KbResourceRef.parse(uri)!.toUri(), uri);
    });
  });
}
