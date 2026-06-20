// Plain Dart models used by the design-system widgets. Each screen-level
// widget composes these from real data adapters; widget tests can build
// them directly.

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum ActorKind { agent, human, process }

enum AgentArchetype { generic, researcher, writer }

class ActivityActor {
  const ActivityActor({
    required this.kind,
    required this.label,
    this.archetype = AgentArchetype.generic,
  });
  final ActorKind kind;
  final String label;
  final AgentArchetype archetype;

  String get initials {
    final parts = label.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  LinearGradient get gradient => switch ((kind, archetype)) {
    (ActorKind.agent, AgentArchetype.researcher) => OpsAvatarGradients.research,
    (ActorKind.agent, AgentArchetype.writer) => OpsAvatarGradients.writer,
    (ActorKind.agent, _) => OpsAvatarGradients.knowledge,
    (ActorKind.human, _) => OpsAvatarGradients.human,
    (ActorKind.process, _) => OpsAvatarGradients.writer,
  };
}

enum MemberKind { ai, human }

class MemberSummary {
  const MemberSummary({
    required this.actor,
    required this.name,
    required this.subtitle,
    required this.kind,
    this.online = false,
    this.layerProgress = const [0, 0, 0],
  });
  final ActivityActor actor;
  final String name;
  final String subtitle;
  final MemberKind kind;
  final bool online;
  final List<double> layerProgress;
}

enum KnowledgeKind { fact, pattern, summary }

extension KnowledgeKindLabel on KnowledgeKind {
  String get label => switch (this) {
    KnowledgeKind.fact => 'Fact',
    KnowledgeKind.pattern => 'Pattern',
    KnowledgeKind.summary => 'Summary',
  };
}

class KnowledgeEntry {
  const KnowledgeEntry({
    required this.kind,
    required this.title,
    required this.body,
    required this.meta,
  });
  final KnowledgeKind kind;
  final String title;
  final String body;
  final String meta;
}

enum PipelineState { done, running, gate, pending }

class PipelineStep {
  const PipelineStep({
    required this.indexLabel,
    required this.name,
    required this.actorCaption,
    required this.description,
    required this.state,
    required this.timeLabel,
  });
  final String indexLabel;
  final String name;
  final String actorCaption;
  final String description;
  final PipelineState state;
  final String timeLabel;
}

enum ProcessRunState { running, gate, ok, paused, scheduled }

class ProcessSummary {
  const ProcessSummary({
    required this.id,
    required this.name,
    required this.meta,
    required this.state,
    required this.progress,
    this.steps = const [],
    this.subtitle = '',
  });
  final String id;
  final String name;
  final String meta;
  final ProcessRunState state;
  final double progress;
  final List<PipelineStep> steps;
  final String subtitle;
}

class AgentSummary {
  const AgentSummary({
    required this.actor,
    required this.name,
    required this.role,
    required this.tags,
    required this.metaRows,
    required this.layers,
    required this.lastSkill,
    required this.openTension,
    required this.nextMilestone,
    this.online = true,
  });
  final ActivityActor actor;
  final String name;
  final String role;
  final List<String> tags;
  final List<({String key, String value})> metaRows;
  final List<AgentLayerProgress> layers;
  final ({String title, String subtitle}) lastSkill;
  final ({String title, String subtitle}) openTension;
  final ({String title, String subtitle}) nextMilestone;
  final bool online;
}

class AgentLayerProgress {
  const AgentLayerProgress({
    required this.label,
    required this.title,
    required this.description,
    required this.stats,
    required this.percent,
    required this.color,
  });
  final String label;
  final String title;
  final String description;
  final String stats;
  final double percent;
  final Color color;
}

class WorkspaceSummary {
  const WorkspaceSummary({required this.id, required this.name});
  final String id;
  final String name;
}

class UserSummary {
  const UserSummary({
    required this.initials,
    required this.name,
    required this.role,
  });
  final String initials;
  final String name;
  final String role;
}

class OpsStatusBarState {
  const OpsStatusBarState({
    required this.connDot,
    required this.mcpServers,
    required this.facts,
    required this.patterns,
    required this.summaries,
    required this.llm,
    required this.build,
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.llmCalls = 0,
    this.errors = 0,
  });
  final Color connDot;
  final int mcpServers;
  final int facts;
  final int patterns;
  final int summaries;
  final String llm;
  final String build;
  final int tokensIn;
  final int tokensOut;
  final int llmCalls;
  final int errors;
}
