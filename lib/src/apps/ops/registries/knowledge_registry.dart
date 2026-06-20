import 'dart:io';

import 'package:appplayer_studio/builtin_api.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as bundle;
import 'package:yaml/yaml.dart';

import '../infra/ws_paths.dart';
import '../util/atomic_write.dart';

/// See `SRS §2.10 FR-OPS-013` for the design specification.
class SiteKnowledge {
  SiteKnowledge({
    required this.systemId,
    required this.urlMap,
    required this.templates,
    this.authSpec,
  });

  final String systemId;
  final Map<String, String> urlMap;
  final List<Map<String, dynamic>> templates;
  final Map<String, dynamic>? authSpec;
}

class KnowledgeRegistry {
  KnowledgeRegistry({
    required this.kv,
    required this.knowledgeSystem,
    this.rootDir = './workspaces',
  });

  final KvStoragePortAdapter kv;
  final KnowledgeSystem knowledgeSystem;
  final String rootDir;

  /// List files under `<ws>/knowledge/<subPath>` (recursive). Paths returned
  /// are workspace-relative (e.g. `knowledge/notes/foo.md`).
  Future<List<KnowledgeFileEntry>> listFiles(
    String wsId, {
    String subPath = '',
  }) async {
    final base =
        '${wsContentRoot(rootDir, wsId)}/knowledge${subPath.isEmpty ? "" : "/$subPath"}';
    final dir = Directory(base);
    if (!await dir.exists()) return const [];
    final out = <KnowledgeFileEntry>[];
    await for (final e in dir.list(recursive: true)) {
      if (e is! File) continue;
      final stat = await e.stat();
      out.add(
        KnowledgeFileEntry(
          relativePath: e.path.substring(
            '${wsContentRoot(rootDir, wsId)}/'.length,
          ),
          size: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    out.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return out;
  }

  Future<String> readFile(String wsId, String relativePath) async {
    _assertKnowledgePath(relativePath);
    final f = File('${wsContentRoot(rootDir, wsId)}/$relativePath');
    if (!await f.exists()) throw StateError('file not found: $relativePath');
    return f.readAsString();
  }

  Future<void> writeFile(
    String wsId,
    String relativePath,
    String content,
  ) async {
    _assertKnowledgePath(relativePath);
    final f = File('${wsContentRoot(rootDir, wsId)}/$relativePath');
    await writeStringAtomic(f, content);
  }

  Future<void> deleteFile(String wsId, String relativePath) async {
    _assertKnowledgePath(relativePath);
    final f = File('${wsContentRoot(rootDir, wsId)}/$relativePath');
    if (await f.exists()) await f.delete();
  }

  void _assertKnowledgePath(String relativePath) {
    if (!relativePath.startsWith('knowledge/')) {
      throw ArgumentError('path must start with knowledge/: $relativePath');
    }
    if (relativePath.contains('..')) {
      throw ArgumentError('path must not contain ..: $relativePath');
    }
  }

  Future<void> saveFact({
    required String category,
    required String key,
    required Object value,
    Map<String, Object?>? metadata,
  }) async {
    final content = value is String ? value : value.toString();
    final wsId = kv.workspaceId!;
    // Persist the fact into the FactGraph so it is graph-queryable
    // (`bk.fact.query types:['fact']`) and assignable to agents
    // (`bk.agent.assign_facts` scopes a FactQuery over the graph). An
    // explicit category/key/value save is a user-asserted fact, so write
    // it directly (no candidate review — that path is for extracted, lower-
    // confidence fragments). Previously this called `extractFragments` and
    // discarded the result, so the fact only ever landed in KV and the
    // graph half of every query / the agent fact-scope stayed empty
    // (despite the "writes to both FactFacade and KV" contract).
    await knowledgeSystem.facts.writeFacts(<bundle.FactRecord>[
      bundle.FactRecord(
        id: 'fact/$category/$key',
        workspaceId: wsId,
        type: 'fact',
        entityId: key,
        content: <String, dynamic>{
          'text': content,
          'category': category,
          'key': key,
        },
        confidence: 1.0,
        createdAt: DateTime.now(),
      ),
    ]);
    await kv.set('ws/${kv.workspaceId!}/registry/knowledge/$category/$key', {
      'category': category,
      'key': key,
      'value': value,
      if (metadata != null) 'metadata': metadata,
      'savedAt': DateTime.now().toIso8601String(),
    });
  }

  /// Workspace-scoped fact query. Combines two sources:
  ///   1. FactGraph (semantic; populated when LLM extracts fragments).
  ///   2. KV-stored facts written by [saveFact] (always written, even
  ///      without an internal LLM).
  /// The KV results are surfaced as ad-hoc [bundle.FactRecord]s so the
  /// caller sees a single unified list. [typeFilter] still maps to
  /// FactQuery.types for the FactGraph half.
  Future<List<bundle.FactRecord>> query(
    String question, {
    String? typeFilter,
    String? workspaceId,
    String? entityId,
    int limit = 10,
  }) async {
    // [workspaceId] override allows callers (MCP / UI) to query lifecycle
    // facts that live outside the active workspace — e.g. system agent's
    // `_system` workspace timeline. Defaults to active workspace.
    final wsScope = workspaceId ?? kv.workspaceId!;
    final fromGraph = await knowledgeSystem.facts.queryFacts(
      bundle.FactQuery(
        workspaceId: wsScope,
        types: typeFilter == null ? null : [typeFilter],
        entityId: entityId,
        limit: limit,
      ),
    );

    // KV fallback / merge — substring match against category / key / value.
    final kvHits = await listKvFacts(filter: question);
    final fromKv = <bundle.FactRecord>[];
    final wsId = kv.workspaceId!;
    for (final entry in kvHits.take(limit)) {
      fromKv.add(
        bundle.FactRecord(
          id: entry.storageKey,
          type: 'kv:${entry.category}',
          workspaceId: wsId,
          entityId: entry.key,
          content: {'value': entry.value, 'category': entry.category},
          confidence: 1.0,
          createdAt: DateTime.tryParse(entry.savedAt ?? '') ?? DateTime.now(),
        ),
      );
    }

    return [...fromGraph, ...fromKv].take(limit).toList();
  }

  /// List KV-stored facts (category/key/value from `saveFact`), optionally
  /// filtered by a case-insensitive substring in category / key / value.
  /// Used by the UI as a fallback when the fact-graph index is empty —
  /// e.g. when no internal LLM is configured so `extractFragments` can't
  /// populate the graph, but KV writes still succeed.
  Future<List<KvFactEntry>> listKvFacts({String? filter}) async {
    final prefix = 'ws/${kv.workspaceId!}/registry/knowledge/';
    final keys = await kv.keys(prefix: prefix);
    final q = filter?.trim().toLowerCase();
    final out = <KvFactEntry>[];
    for (final k in keys) {
      final v = await kv.get(k);
      if (v is! Map) continue;
      final entry = KvFactEntry(
        storageKey: k.substring(prefix.length),
        category: v['category']?.toString() ?? '',
        key: v['key']?.toString() ?? '',
        value: v['value']?.toString() ?? '',
        metadata:
            v['metadata'] is Map
                ? Map<String, Object?>.from(v['metadata'] as Map)
                : const <String, Object?>{},
        savedAt: v['savedAt']?.toString(),
      );
      if (q == null || q.isEmpty) {
        out.add(entry);
        continue;
      }
      if (entry.category.toLowerCase().contains(q) ||
          entry.key.toLowerCase().contains(q) ||
          entry.value.toLowerCase().contains(q)) {
        out.add(entry);
      }
    }
    out.sort((a, b) => (b.savedAt ?? '').compareTo(a.savedAt ?? ''));
    return out;
  }

  Future<bundle.SummaryRecord?> getSummary(
    String entityId,
    String summaryType,
  ) async {
    return knowledgeSystem.facts.getSummary(entityId, summaryType);
  }

  Future<List<bundle.PatternRecord>> queryPatterns({String? type}) async {
    return knowledgeSystem.facts.queryPatterns(
      bundle.PatternQuery(workspaceId: kv.workspaceId!, type: type),
    );
  }

  Future<SiteKnowledge> loadSystemSchema(String systemId) async {
    final base =
        '${wsContentRoot(rootDir, kv.workspaceId!)}/knowledge/systems/$systemId';
    final urlMap = <String, String>{};
    final urlMapFile = File('$base/url-map.yaml');
    if (await urlMapFile.exists()) {
      final y = loadYaml(await urlMapFile.readAsString());
      if (y is YamlMap) {
        final baseUrl = y['base'] as String? ?? '';
        final paths = y['paths'];
        if (paths is YamlMap) {
          paths.forEach((k, v) {
            urlMap[k.toString()] = '$baseUrl${v.toString()}';
          });
        }
      }
    }

    final templates = <Map<String, dynamic>>[];
    final extractionDir = Directory('$base/extraction');
    if (await extractionDir.exists()) {
      await for (final e in extractionDir.list()) {
        if (e is File && e.path.endsWith('.yaml')) {
          final y = loadYaml(await e.readAsString());
          if (y is YamlMap) {
            templates.add(Map<String, dynamic>.from(y));
          }
        }
      }
    }

    Map<String, dynamic>? authSpec;
    final authSpecFile = File('$base/auth-spec.yaml');
    if (await authSpecFile.exists()) {
      final y = loadYaml(await authSpecFile.readAsString());
      if (y is YamlMap) authSpec = Map<String, dynamic>.from(y);
    }

    return SiteKnowledge(
      systemId: systemId,
      urlMap: urlMap,
      templates: templates,
      authSpec: authSpec,
    );
  }
}

class KnowledgeFileEntry {
  KnowledgeFileEntry({
    required this.relativePath,
    required this.size,
    required this.modifiedAt,
  });
  final String relativePath;
  final int size;
  final DateTime modifiedAt;
}

class KvFactEntry {
  KvFactEntry({
    required this.storageKey,
    required this.category,
    required this.key,
    required this.value,
    this.metadata = const {},
    this.savedAt,
  });
  final String storageKey;
  final String category;
  final String key;
  final String value;
  final Map<String, Object?> metadata;
  final String? savedAt;
}
