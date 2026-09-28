/// `kind: cloud` bundle tools — the input is POSTed as JSON to an https
/// `target.url` and the JSON response is the result. Failures carry the
/// reason and are never turned into an empty result.
library;

import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart';
import 'package:brain_kernel/brain_kernel.dart' as mk;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

String _bundleWithCloudTool(Object? url) {
  final dir = Directory.systemTemp.createTempSync('vibe_cloud_tool_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
    jsonEncode({
      'manifest': {'id': 'com.test.cloud', 'name': 'Cloud', 'version': '1'},
      'tools': {
        'tools': [
          {
            'name': 'score',
            'kind': 'cloud',
            'target': {'url': url},
          },
        ],
      },
    }),
  );
  return dir.path;
}

Future<(HostBundleActivationContext, mk.InProcessKernelServerHost)> _activate(
  Object? url,
  http.Client client,
) async {
  final root = _bundleWithCloudTool(url);
  final bundle = readBundleAt(root)!;
  final boot = mk.InProcessKernelServerHost();
  final ctx = HostBundleActivationContext(
    boot: boot,
    tabKey: root,
    bundle: bundle,
    exposedShortId: bundle.shortId,
    httpClient: client,
  );
  addTearDown(ctx.unregisterAll);
  final reg = await ctx.registerTool(bundle.tools!.tools.single);
  expect(reg.ok, isTrue, reason: reg.error ?? 'register failed');
  return (ctx, boot);
}

String _text(mk.KernelToolResult r) =>
    (r.content.single as mk.KernelTextContent).text;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('posts the input as JSON and answers the JSON body', () async {
    http.Request? seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response(
        jsonEncode({'score': 7, 'label': 'café'}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final (ctx, boot) = await _activate('https://api.example.com/score', client);
    final r = await boot.callTool('${ctx.exposedShortId}.score', {'n': 3});
    expect(r.isError, isFalse, reason: _text(r));
    expect(jsonDecode(_text(r)), {'score': 7, 'label': 'café'});
    expect(seen!.method, 'POST');
    expect(seen!.url.toString(), 'https://api.example.com/score');
    expect(seen!.headers['content-type'], startsWith('application/json'));
    expect(jsonDecode(seen!.body), {'n': 3});
  });

  test('an empty body answers an empty object', () async {
    final client = MockClient((_) async => http.Response('', 204));
    final (ctx, boot) = await _activate('https://api.example.com/x', client);
    final r = await boot.callTool('${ctx.exposedShortId}.score', {});
    expect(r.isError, isFalse);
    expect(jsonDecode(_text(r)), <String, dynamic>{});
  });

  test('a non-2xx status fails with the status', () async {
    final client = MockClient((_) async => http.Response('nope', 503));
    final (ctx, boot) = await _activate('https://api.example.com/x', client);
    final r = await boot.callTool('${ctx.exposedShortId}.score', {});
    expect(r.isError, isTrue);
    expect(_text(r), contains('503'));
  });

  test('a body that is not JSON fails with the reason', () async {
    final client = MockClient((_) async => http.Response('<html>', 200));
    final (ctx, boot) = await _activate('https://api.example.com/x', client);
    final r = await boot.callTool('${ctx.exposedShortId}.score', {});
    expect(r.isError, isTrue);
    expect(_text(r), contains('not JSON'));
  });

  test('a non-https or missing url fails without a request', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    for (final url in <Object?>['http://api.example.com/x', null]) {
      final (ctx, boot) = await _activate(url, client);
      final r = await boot.callTool('${ctx.exposedShortId}.score', {});
      expect(r.isError, isTrue);
      expect(_text(r), contains('https'));
      await ctx.unregisterAll();
    }
    expect(requests, 0);
  });

  test('a transport failure fails with the reason', () async {
    final client = MockClient(
      (_) async => throw const SocketException('unreachable'),
    );
    final (ctx, boot) = await _activate('https://api.example.com/x', client);
    final r = await boot.callTool('${ctx.exposedShortId}.score', {});
    expect(r.isError, isTrue);
    expect(_text(r), contains('unreachable'));
  });
}
