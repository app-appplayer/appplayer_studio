// Workspace → self-contained HTML report — the cloud-free alternative
// to Embed Share (FM-PORTABILITY-03 Phase F). Produces a single .html
// file the user can open in any browser, host on a static site, or
// email. No backend involvement.
//
// Content:
//   - Header (workspace id, type, generated timestamp)
//   - KPI strip (members, agents, tasks, processes, facts, telemetry)
//   - Agents (display name, model, skills/profile/philosophy refs)
//   - Tasks (kind, state, assignee, skills)
//   - Processes (steps, gate count)
//   - Recent activity events (latest N)
//   - Telemetry totals (provider summary)
//
// Stylesheet inlined; no external assets. Safe-encodes user-provided
// strings via [_h] (HTML escape).

import 'dart:convert';
import 'dart:io';

import '../config/ops_config.dart';
import '../init/knowledge_init.dart';
import '../observability/observability_module.dart';
import '../registries/member_registry.dart';

class HtmlReportResult {
  HtmlReportResult({required this.path, required this.bytes});
  final String path;
  final int bytes;
}

class HtmlReport {
  HtmlReport._();

  static Future<HtmlReportResult> build({
    required KnowledgeInit init,
    required OpsConfig config,
    required String workspaceId,
    required String outputPath,
    ObservabilityModule? observability,
    int recentEvents = 80,
  }) async {
    final ws = await init.registries.workspace.get(workspaceId);
    if (ws == null) {
      throw StateError('Workspace not found: $workspaceId');
    }
    final members = await init.registries.member.listForWorkspace(workspaceId);
    final tasks = await init.registries.task.list(wsId: workspaceId);
    final processes = await init.registries.process.list(wsId: workspaceId);
    var factCount = 0;
    try {
      final facts = await init.registries.knowledge.query(
        '',
        workspaceId: workspaceId,
        limit: 500,
      );
      factCount = facts.length;
    } catch (_) {
      /* ignore */
    }

    final agents = members.whereType<AgentMember>().toList();
    final humans = members.where((m) => m is! AgentMember).toList();

    final eventsRaw = observability?.bus.recent ?? const [];
    final events =
        eventsRaw.length <= recentEvents
            ? eventsRaw
            : eventsRaw.sublist(eventsRaw.length - recentEvents);

    final tel = observability?.telemetry;
    final telemetryHtml =
        tel == null
            ? ''
            : '''
<section>
  <h2>Telemetry</h2>
  <pre class="json">${_h(const JsonEncoder.withIndent('  ').convert(tel.toJson()))}</pre>
</section>''';

    final activityHtml =
        events.isEmpty
            ? ''
            : '''
<section>
  <h2>Recent activity (${events.length})</h2>
  <table>
    <thead>
      <tr><th>time</th><th>kind</th><th>actor</th><th>headline</th></tr>
    </thead>
    <tbody>
${[for (final e in events.reversed.take(50)) '      <tr class="sev-${_h(e.severity.name)}">'
                  '<td>${_h(e.ts.toIso8601String())}</td>'
                  '<td>${_h(e.kind.name)}</td>'
                  '<td>${_h(e.actor)}</td>'
                  '<td>${_h(e.headline)}</td>'
                  '</tr>'].join('\n')}
    </tbody>
  </table>
</section>''';

    final agentsHtml =
        agents.isEmpty
            ? '<p class="empty">No agents in this workspace.</p>'
            : '''
  <table>
    <thead>
      <tr><th>id</th><th>name</th><th>model</th><th>skills</th><th>profile</th><th>philosophy</th></tr>
    </thead>
    <tbody>
${[for (final a in agents) '      <tr>'
                  '<td><code>${_h(a.id)}</code></td>'
                  '<td>${_h(a.displayName)}</td>'
                  '<td><code>${_h(a.model == null ? "(default)" : "${a.model!.provider}/${a.model!.model}")}</code></td>'
                  '<td><code>${_h(a.skillIds.join(", "))}</code></td>'
                  '<td><code>${_h(a.profileRef)}</code></td>'
                  '<td><code>${_h(a.philosophyRef)}</code></td>'
                  '</tr>'].join('\n')}
    </tbody>
  </table>
''';

    final tasksHtml =
        tasks.isEmpty
            ? '<p class="empty">No tasks.</p>'
            : '''
  <table>
    <thead>
      <tr><th>id</th><th>title</th><th>kind</th><th>state</th><th>assignee</th><th>skills</th></tr>
    </thead>
    <tbody>
${[for (final t in tasks) '      <tr>'
                  '<td><code>${_h(t.id)}</code></td>'
                  '<td>${_h(t.title)}</td>'
                  '<td>${_h(t.kind.name)}</td>'
                  '<td>${_h(t.state.name)}</td>'
                  '<td>${_h(t.assigneeIds.join(", "))}</td>'
                  '<td><code>${_h(t.skillIds.join(", "))}</code></td>'
                  '</tr>'].join('\n')}
    </tbody>
  </table>
''';

    final processesHtml =
        processes.isEmpty
            ? '<p class="empty">No processes.</p>'
            : '''
  <table>
    <thead>
      <tr><th>id</th><th>title</th><th>steps</th><th>gates</th><th>trigger</th></tr>
    </thead>
    <tbody>
${[for (final p in processes) '      <tr>'
                  '<td><code>${_h(p.id)}</code></td>'
                  '<td>${_h(p.title)}</td>'
                  '<td>${p.steps.length}</td>'
                  '<td>${p.gates.length}</td>'
                  '<td>${_h(p.trigger.name)}</td>'
                  '</tr>'].join('\n')}
    </tbody>
  </table>
''';

    final html = '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${_h(ws.title.isEmpty ? ws.id : ws.title)} — makemind Ops report</title>
<style>
${_inlineCss()}
</style>
</head>
<body>
<header>
  <div class="hero">
    <h1>${_h(ws.title.isEmpty ? ws.id : ws.title)}</h1>
    <p class="meta">
      <span><b>${_h(ws.id)}</b></span>
      · type <code>${_h(ws.type.name)}</code>
      · generated ${_h(DateTime.now().toUtc().toIso8601String())}
      · app <code>${_h(config.appName)}</code>
    </p>
  </div>
  <div class="kpi-row">
    ${_kpi('Agents', agents.length)}
    ${_kpi('Humans', humans.length)}
    ${_kpi('Tasks', tasks.length)}
    ${_kpi('Processes', processes.length)}
    ${_kpi('Facts', factCount)}
    ${_kpi('LLM calls', tel?.totalLlmCalls ?? 0)}
    ${_kpi('Tokens', (tel?.totalTokensIn ?? 0) + (tel?.totalTokensOut ?? 0))}
  </div>
</header>
<main>
  <section>
    <h2>Agents (${agents.length})</h2>
    $agentsHtml
  </section>
  <section>
    <h2>Tasks (${tasks.length})</h2>
    $tasksHtml
  </section>
  <section>
    <h2>Processes (${processes.length})</h2>
    $processesHtml
  </section>
  $telemetryHtml
  $activityHtml
</main>
<footer>
  <p>Generated by makemind Ops · self-contained · no external assets · safe to email or host on a static site.</p>
</footer>
</body>
</html>
''';

    final bytes = utf8.encode(html);
    await File(outputPath).writeAsBytes(bytes);
    return HtmlReportResult(path: outputPath, bytes: bytes.length);
  }

  static String _kpi(String label, int value) =>
      '<div class="kpi"><div class="v">$value</div><div class="l">${_h(label)}</div></div>';

  static String _inlineCss() => '''
* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Inter, system-ui, sans-serif;
  background: #fafaf9;
  color: #15161a;
  line-height: 1.5;
}
header {
  background: linear-gradient(135deg, #5e8ffa 0%, #9b7be8 100%);
  color: white;
  padding: 28px 32px;
}
.hero h1 { margin: 0 0 6px; font-size: 26px; letter-spacing: -0.4px; }
.meta { margin: 0; opacity: 0.92; font-size: 13px; }
.meta code { background: rgba(0,0,0,0.18); padding: 1px 5px; border-radius: 3px; }
.kpi-row { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 18px; }
.kpi {
  background: rgba(255,255,255,0.16);
  border: 1px solid rgba(255,255,255,0.24);
  border-radius: 6px;
  padding: 8px 12px;
  min-width: 110px;
}
.kpi .v { font-size: 20px; font-weight: 600; }
.kpi .l { font-size: 11px; opacity: 0.86; text-transform: uppercase; letter-spacing: 0.5px; }
main { padding: 24px 32px 16px; max-width: 1100px; margin: 0 auto; }
section { margin-bottom: 28px; }
h2 { font-size: 14px; text-transform: uppercase; letter-spacing: 0.6px; color: #5a5c66; border-bottom: 1px solid #e4e4e0; padding-bottom: 6px; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th { text-align: left; font-weight: 600; color: #5a5c66; padding: 6px 8px; border-bottom: 1px solid #e4e4e0; }
td { padding: 6px 8px; border-bottom: 1px solid #f0f0ec; vertical-align: top; }
code { font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; background: #f0f0ec; padding: 1px 4px; border-radius: 3px; }
pre.json { background: #15161a; color: #e6e6e6; padding: 12px; border-radius: 6px; overflow: auto; font-size: 11px; }
.empty { color: #8e909a; font-style: italic; }
.sev-warn td { background: #fff7e0; }
.sev-error td { background: #ffeaea; }
footer { padding: 16px 32px 32px; color: #8e909a; font-size: 11px; max-width: 1100px; margin: 0 auto; }
@media (prefers-color-scheme: dark) {
  body { background: #0e0f13; color: #ecedf1; }
  h2 { color: #a2a6b4; border-color: #262a36; }
  th { color: #a2a6b4; border-color: #262a36; }
  td { border-color: #1d2029; }
  code { background: #1d2029; color: #ecedf1; }
  .empty { color: #6b6f80; }
}
''';

  static String _h(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
}
