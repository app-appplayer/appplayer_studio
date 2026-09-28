/// Secret values in tool-call arguments never leave the dispatch log.
library;

import 'package:appplayer_studio/src/base/infra/arg_redaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('secret-named fields are masked at any depth, whatever the type', () {
    final out = redactToolArgs('config_set_llm_provider', {
      'provider': 'claude',
      'apiKey': 'sk-live-123',
      'nested': {
        'password': 'hunter2',
        'accessToken': {'raw': 'abc'},
      },
      'list': [
        {'client_secret': 's'},
      ],
    });
    expect(out, {
      'provider': 'claude',
      'apiKey': kRedacted,
      'nested': {'password': kRedacted, 'accessToken': kRedacted},
      'list': [
        {'client_secret': kRedacted},
      ],
    });
  });

  test('credential tools mask every string except the naming fields', () {
    expect(redactToolArgs('secret.set', {'ref': 'db', 'value': 'p@ss'}), {
      'ref': 'db',
      'value': kRedacted,
    });
    expect(
      redactToolArgs('channel.credential_set', {
        'id': 'mail',
        'platform': 'smtp',
        'params': {'host': 'smtp.example.com', 'user': 'me', 'port': 587},
      }),
      {
        'id': 'mail',
        'platform': 'smtp',
        'params': {'host': kRedacted, 'user': kRedacted, 'port': 587},
      },
    );
  });

  test('ordinary tools pass through untouched', () {
    final args = {'category': 'product', 'key': 'price', 'value': '10 USD'};
    expect(redactToolArgs('knowledge_fact_save', args), args);
  });

  test('the input is not modified', () {
    final args = {'apiKey': 'sk-1'};
    redactToolArgs('x', args);
    expect(args['apiKey'], 'sk-1');
  });
}
