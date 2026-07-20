/// Shared display helpers for agent-lifecycle facts and member identity so
/// every user-facing surface (domain Facts view, Home activity feed, and any
/// future screen) classifies and labels the same way.
///
/// UX audit P1 (2026-07-12): the FactGraph accumulates per-agent 4-axis
/// fork/growth bookkeeping (`agent.*` fact types). These are internal ledger
/// records, not domain knowledge — they flooded the Facts view and Home feed
/// and were shown with raw factIds / qualified agentIds. The helpers here let
/// callers hide the pure-provisioning bookkeeping by default and always
/// resolve a raw agentId to its member displayName.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as bundle;

// `memberDisplayNameFor` moved to member_registry.dart (non-UI, shared with the
// tool layer's activity emit). Re-exported so existing UI import sites that pull
// it from this shared display helper keep working.
export '../../registries/member_registry.dart' show memberDisplayNameFor;

/// `agent.*` fact types (`agent.fork.assigned` / `agent.fork.evolved` /
/// `agent.invoked` / `agent.deleted`) are per-agent lifecycle bookkeeping —
/// the 4-axis fork/growth ledger — NOT domain knowledge. They live on the
/// agent-detail / Graph surfaces; the domain Facts view hides them by default
/// and the Home feed de-noises them.
bool isAgentLifecycleFact(String type) => type.startsWith('agent.');

/// The pure-provisioning subset: the initial 4-axis fork from a philosophy
/// pool (`source: pool:...`). One record per axis per agent — setup noise that
/// carries no operational signal. Transfers (`source: agent:...`) and
/// evolutions DO carry signal, so they survive even when provisioning is
/// filtered out.
bool isProvisioningFact(bundle.FactRecord f) {
  if (f.type != 'agent.fork.assigned') return false;
  final source = (f.content['source'] ?? '').toString();
  return source.startsWith('pool:');
}

/// Human-readable one-line label for an agent-lifecycle fact — the same
/// wording the Home feed and agent-detail surfaces already use, so a filtered
/// system fact reads as "forked philosophy" rather than a raw factId.
String agentFactHeadline(bundle.FactRecord f) {
  final c = f.content;
  final axis = (c['axis'] ?? '').toString();
  final source = (c['source'] ?? '').toString();
  final isTransfer = source.startsWith('agent:');
  return switch (f.type) {
    'agent.fork.assigned' => isTransfer ? 'received $axis' : 'forked $axis',
    'agent.fork.evolved' => '$axis evolved',
    'agent.invoked' => 'invoked',
    'agent.deleted' => 'deleted',
    _ => f.type,
  };
}

// memberDisplayNameFor now lives in member_registry.dart (re-exported above).
