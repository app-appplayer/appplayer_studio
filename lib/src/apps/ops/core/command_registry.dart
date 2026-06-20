// Command registry — drives the Cmd+K palette. PRD §FM-POWER-01 / 02.
//
// Each command is a tiny record of (id, category, label, hint, runner).
// The registry is populated dynamically at palette-open time so it
// reflects the current workspace, agents, skills, and recent items —
// no rebuilding when those change.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

@immutable
class OpsCommand {
  const OpsCommand({
    required this.id,
    required this.category,
    required this.label,
    this.hint,
    this.icon,
    required this.run,
  });
  final String id;
  final String category;
  final String label;
  final String? hint;
  final IconData? icon;
  final void Function(WidgetRef ref) run;
}

/// Build the live command list. Called every time the palette opens so
/// it stays current with workspace state.
Future<List<OpsCommand>> buildCommandList(WidgetRef ref) async {
  final out = <OpsCommand>[];
  final init = ref.read(knowledgeInitProvider);
  final wsId = ref.read(activeWorkspaceIdProvider);

  // Routes — every sidebar destination.
  out.addAll(_routeCommands());

  // Workspaces — fast switcher.
  try {
    final ws = await init.registries.workspace.list();
    for (final w in ws) {
      out.add(
        OpsCommand(
          id: 'workspace.${w.id}',
          category: 'Workspace',
          label: 'Switch to — ${w.title.isEmpty ? w.id : w.title}',
          hint: w.id,
          icon: Icons.swap_horiz,
          run: (ref) async {
            await init.registries.workspace.setActive(w.id);
          },
        ),
      );
    }
  } catch (_) {
    /* registry might not be loaded yet */
  }

  // Agents — open detail.
  if (wsId != null) {
    try {
      final members = await init.registries.member.listForWorkspace(wsId);
      for (final m in members) {
        final isAgent = m.runtimeType.toString().contains('Agent');
        if (!isAgent) continue;
        out.add(
          OpsCommand(
            id: 'agent.${m.id}',
            category: 'Agent',
            label: 'Open agent — ${m.displayName}',
            hint: m.id,
            icon: Icons.smart_toy_outlined,
            run:
                (ref) =>
                    ref.read(shellRouteProvider.notifier).state = 'members',
          ),
        );
      }
    } catch (_) {
      /* skip */
    }
  }

  // Skills — list all loaded.
  try {
    final skills = init.skills.list();
    for (final s in skills) {
      out.add(
        OpsCommand(
          id: 'skill.${s.id}',
          category: 'Skill',
          label: 'Skill — ${s.id}',
          hint: s.description,
          icon: Icons.flash_on_outlined,
          run: (ref) => ref.read(shellRouteProvider.notifier).state = 'skills',
        ),
      );
    }
  } catch (_) {
    /* skip */
  }

  // Quick actions — fast button-equivalents the user may want
  // without route navigation overhead.
  out.add(
    OpsCommand(
      id: 'action.toggle-chat',
      category: 'Action',
      label: 'Toggle chat dock',
      icon: Icons.chat_bubble_outline,
      run: (ref) => ref.read(chatDockOpenProvider.notifier).update((v) => !v),
    ),
  );

  return out;
}

List<OpsCommand> _routeCommands() {
  // Mirrors the active `OpsRoute` set (essence-grouped sidebar). Routes with
  // no `_routeBodyFor` mapping (replay/visualize/compare/diagnostics/
  // connector/yaml/portability) are not registered — their pages are unmapped
  // pending UI-REDESIGN orphan absorption, so a command would dead-end on home.
  return [
    _routeCmd('home', 'Home', Icons.home_outlined),
    _routeCmd('observability', 'Activity', Icons.bolt_outlined),
    _routeCmd('members', 'Experts', Icons.group_outlined),
    _routeCmd('knowledge', 'Knowledge', Icons.fact_check_outlined),
    _routeCmd('skills', 'Skills', Icons.flash_on_outlined),
    _routeCmd('profiles', 'Profiles', Icons.face_outlined),
    _routeCmd('philosophies', 'Philosophies', Icons.balance_outlined),
    _routeCmd('tasks', 'Tasks', Icons.checklist_outlined),
    _routeCmd('processes', 'Processes', Icons.account_tree_outlined),
    _routeCmd('workspaces', 'Workspaces', Icons.folder_outlined),
    _routeCmd('bundles', 'Bundles', Icons.inventory_2_outlined),
    _routeCmd('audit', 'Audit', Icons.verified_outlined),
    _routeCmd('about', 'About', Icons.info_outline),
  ];
}

OpsCommand _routeCmd(String route, String label, IconData icon) {
  return OpsCommand(
    id: 'route.$route',
    category: 'Go to',
    label: label,
    hint: '/$route',
    icon: icon,
    run: (ref) => ref.read(shellRouteProvider.notifier).state = route,
  );
}

/// Tiny fuzzy match — substring, case-insensitive, with a score that
/// favors prefix and word-start matches. No external dep needed.
({double score, String label})? fuzzyScore(String query, String label) {
  if (query.isEmpty) return (score: 1.0, label: label);
  final q = query.toLowerCase();
  final l = label.toLowerCase();
  if (l == q) return (score: 100, label: label);
  if (l.startsWith(q)) return (score: 50 + q.length / l.length, label: label);
  // Word-boundary match.
  final words = l.split(RegExp(r'[\s\-_/]+'));
  for (final w in words) {
    if (w.startsWith(q)) {
      return (score: 30 + q.length / l.length, label: label);
    }
  }
  if (l.contains(q)) return (score: 10 + q.length / l.length, label: label);
  return null;
}
