/// A project folder written by the PUBLISHED fact graph (fixture) is read by
/// the current packages through the vendored persistence recipe, and new
/// writes mix with the old records without clashing.
library;

import 'dart:io';

import 'package:appplayer_studio/src/base/install/knowledge_persistence/knowledge_persistence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_fact_graph/mcp_fact_graph.dart';
import 'package:mcp_fact_graph/src/services/ingestion_source.dart';
import 'package:path/path.dart' as p;

const _fixture = 'test/fixtures/factgraph_published_0_2_3';
const _oldFact = 'fact_1793365482927_5325';
const _oldCandidate = 'cand_1793365482924_8286';
const _oldEvidence = 'ev_1793365482917_7127';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('factgraph_compat_');
    for (final f in Directory(_fixture).listSync().whereType<File>()) {
      f.copySync(p.join(root.path, p.basename(f.path)));
    }
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('old records load, status included', () async {
    final c = PersistentStorageContainer(root.path);
    await c.load();
    final fact = await c.facts.getFact(_oldFact);
    expect(fact, isNotNull);
    expect(fact!.status, FactStatus.confirmed);
    expect(fact.candidateId, _oldCandidate);
    expect(
      (await c.candidates.getCandidate(_oldCandidate))!.status,
      CandidateStatus.confirmed,
    );
    expect(
      (await c.evidence.getEvidence(_oldEvidence))!.content,
      'old evidence',
    );
  });

  test(
    'new writes beside old ones keep distinct ids and both persist',
    () async {
      final c = PersistentStorageContainer(root.path);
      await c.load();
      final evidence = EvidenceService(storage: c.evidence);
      final graph = FactGraphService(
        candidateStorage: c.candidates,
        entityStorage: c.entities,
        factStorage: c.facts,
        viewStorage: c.views,
      );
      final ev = await evidence.ingestEvidence(
        const IngestionInput(
          workspaceId: 'proj',
          content: 'new evidence',
          sourceId: 'src',
          sourceType: EvidenceSourceType.text,
        ),
      );
      final cand = await graph.createCandidate(
        workspaceId: 'proj',
        objectType: 'note',
        fragments: const [],
      );
      final res = await graph.confirmCandidate(cand.candidateId);
      expect(ev.evidenceId, startsWith('ev_'));
      expect(cand.candidateId, startsWith('cand_'));
      final factId = res.factId!;
    expect(factId, startsWith('fact_'));
      expect({ev.evidenceId, _oldEvidence}, hasLength(2));
      expect({cand.candidateId, _oldCandidate}, hasLength(2));
      expect({factId, _oldFact}, hasLength(2));

      final again = PersistentStorageContainer(root.path);
      await again.load();
      expect(await again.facts.getFact(_oldFact), isNotNull);
      expect(await again.facts.getFact(factId), isNotNull);
    },
  );
}
