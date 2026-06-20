/// Knowledge atom — `host.kb.*`. Two surfaces:
///
///   * **Query** — BM25 search over installed knowledge bundles via
///     the host's [mk.KnowledgeQueryEngine]. Cross-bundle (a domain
///     can query the user's entire knowledge graph).
///   * **Domain storage** — namespace-scoped key/value durable state
///     via the host's [mk.DomainStorage]. Each bundle gets its own
///     slice (`namespace = bundle.manifest.id`); domains can NOT see
///     each other's state. Use cases: recents, pins, preferences,
///     per-domain caches, progressive learnings.
///
/// Both surfaces are managed by the kernel — bundles never write
/// directly to disk. Memory `feedback_knowledge_definition` formalises
/// that "knowledge" spans facts/skills/profile/philosophy/workflow/
/// agents; per-domain state lives in the same knowledge area so a
/// single backup/move carries every domain's accumulated context.
///
/// Verbs:
///   * `query(text, {topK?, namespace?, sourceId?})` — BM25 hits
///   * `put(key, value)` — write to own namespace
///   * `get(key)` — read from own namespace; null when absent
///   * `list(prefix?)` — entries [{key, value}] in own namespace
///   * `delete(key)` — remove from own namespace; returns `removed: bool`
///
/// `host.kb.*` operations are auto-scoped to the bundle's manifest.id —
/// JS callers don't pass a namespace.
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;

import 'atom_category.dart';

class KbAtom extends AtomCategory {
  KbAtom({
    required this.engine,
    required this.storage,
    required this.namespace,
  });

  /// BM25 search engine. Cross-bundle — `namespace` arg on `query`
  /// (if provided) scopes the search; absent = all installed bundles.
  final mk.KnowledgeQueryEngine engine;

  /// Per-bundle scoped storage. Operations are auto-scoped to
  /// [namespace]; JS callers never see other bundles' data.
  final mk.DomainStorage storage;

  /// The bundle's `manifest.id` — every put/get/list/delete pins to
  /// this. Set by the activation context.
  final String namespace;

  @override
  String get key => 'kb';

  @override
  List<AtomVerb> get verbs => const [
    AtomVerb(
      'query',
      description:
          'BM25 query over installed knowledge bundles. '
          '(text, [{topK, namespace, sourceId}]).',
    ),
    AtomVerb(
      'put',
      description: 'Write to the bundle\'s own domain storage. (key, value).',
    ),
    AtomVerb(
      'get',
      description:
          'Read from the bundle\'s own domain storage. (key) → value | null.',
    ),
    AtomVerb(
      'list',
      description:
          'List entries in the bundle\'s own domain storage. ([prefix]) '
          '→ [{key, value}].',
    ),
    AtomVerb(
      'delete',
      description:
          'Remove an entry from the bundle\'s own domain storage. '
          '(key) → {removed: bool}.',
    ),
  ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'query':
        if (args.isEmpty) {
          throw ArgumentError('query requires (text, [opts])');
        }
        final text = args[0];
        if (text is! String) {
          throw ArgumentError('text must be a String');
        }
        final opts =
            args.length > 1 && args[1] is Map ? args[1] as Map : const {};
        final topK = (opts['topK'] as num?)?.toInt() ?? 5;
        final ns = opts['namespace'] as String?;
        final sourceId = opts['sourceId'] as String?;
        final hits = await engine.query(
          text,
          topK: topK,
          namespace: ns,
          sourceId: sourceId,
        );
        return <Map<String, dynamic>>[for (final h in hits) h.toJson()];
      case 'put':
        if (args.length < 2) {
          throw ArgumentError('put requires (key, value)');
        }
        final key = _stringKey(args[0]);
        await storage.put(namespace, key, args[1]);
        return <String, dynamic>{'ok': true};
      case 'get':
        if (args.isEmpty) {
          throw ArgumentError('get requires (key)');
        }
        final key = _stringKey(args[0]);
        return storage.get(namespace, key);
      case 'list':
        final prefix =
            args.isNotEmpty && args[0] is String ? args[0] as String : '';
        final entries = await storage.list(namespace, prefix: prefix);
        return <Map<String, dynamic>>[
          for (final e in entries)
            <String, dynamic>{'key': e.key, 'value': e.value},
        ];
      case 'delete':
        if (args.isEmpty) {
          throw ArgumentError('delete requires (key)');
        }
        final key = _stringKey(args[0]);
        final removed = await storage.delete(namespace, key);
        return <String, dynamic>{'removed': removed};
      default:
        throw ArgumentError('unknown verb: kb.$verb');
    }
  }

  String _stringKey(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      throw ArgumentError('key must be a non-empty String');
    }
    return raw;
  }
}
