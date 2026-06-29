/// `secret.*` host credential vault (ops-asset-management P2). Uses the
/// in-memory `SecureStorage` so the roundtrip runs without the OS keychain.
/// Asserts the set / exists / remove behaviour and the vault discipline — no
/// plaintext `get` verb is exposed.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_secure/appplayer_secure.dart'
    show InMemorySecureStorage;
import 'package:appplayer_studio/src/base/install/capability_recipes/capability_recipes.dart'
    show CapabilityTool, CapabilityToolError, secretCapabilityTools;

CapabilityTool _byVerb(List<CapabilityTool> tools, String verb) =>
    tools.firstWhere((t) => t.verb == verb);

void main() {
  test('surface — set/exists/remove/list, no plaintext get', () {
    final verbs = secretCapabilityTools(
      InMemorySecureStorage(),
    ).map((t) => t.verb).toSet();
    expect(verbs, containsAll(<String>['set', 'exists', 'remove', 'list']));
    expect(
      verbs.contains('get'),
      isFalse,
      reason: 'a plaintext get would defeat the vault',
    );
  });

  test('set → exists → remove roundtrip', () async {
    final tools = secretCapabilityTools(InMemorySecureStorage());
    expect(await _byVerb(tools, 'exists').invoke({'ref': 'vault:x'}), {
      'exists': false,
    });
    await _byVerb(tools, 'set').invoke({'ref': 'vault:x', 'value': 's3cr3t'});
    expect(await _byVerb(tools, 'exists').invoke({'ref': 'vault:x'}), {
      'exists': true,
    });
    await _byVerb(tools, 'remove').invoke({'ref': 'vault:x'});
    expect(await _byVerb(tools, 'exists').invoke({'ref': 'vault:x'}), {
      'exists': false,
    });
  });

  test('set requires a non-empty ref and value', () {
    final tools = secretCapabilityTools(InMemorySecureStorage());
    expect(
      () => _byVerb(tools, 'set').invoke({'ref': 'vault:x'}),
      throwsA(isA<CapabilityToolError>()),
    );
    expect(
      () => _byVerb(tools, 'set').invoke({'ref': '', 'value': 'v'}),
      throwsA(isA<CapabilityToolError>()),
    );
  });
}
