# Change propagation checklist (studio / ops capability changes)

When you add or change a **platform capability** (a new field, tool, process
primitive, model concept, or UI surface), the change is not "done" at the code.
It must propagate to every layer that depends on it — **as one atomic unit, by
default, without being asked**. Treat this list as the definition of done.

## The chain

1. **Code** — the implementation (lib/).
2. **Tests** — unit + the relevant suite; analyze 0 err.
3. **Seed knowledge** — the built-in app agents read `seed/<id>.mbd`
   `manifest.json` → `knowledge.sources` at boot (`studio://knowledge/*`).
   This is what the ops / bundle-authoring agents use to DESIGN. A new
   primitive the agent should author with (e.g. `dependsOn`, `leadMemberId`,
   `triggerSource`, a new tool) MUST be documented here, or agents keep
   building the old way.
   - `studio.mbd` = host-shared (every app). `<app>.mbd` = per-app
     (`makemind_ops.mbd`, `app_builder.mbd`, `scene_builder.mbd`).
   - Format per file is fixed (makemind_ops = `ensure_ascii=True`, indent 2,
     **no trailing newline**) — edit via a script that re-dumps in the same
     convention; verify the diff is insertion-only.
4. **Spec** — `specs/platform/*` (and `specs/mcp_bundle/*` for bundle shape).
   Sync the doctrine the change realizes (e.g. team-lead → 07 / 12).
5. **CHANGELOG** — `standard/CHANGELOG.md` next version section.
6. **Release sync** — `debug/tool/sync_debug_to_release.sh` (copies lib/seed/
   test; identity files excluded), then the release gate (pub upgrade · analyze
   · ops test · macOS build). Seed changes ride this too.
7. **Domain knowledge / runbooks** — knowledge owned by another persona
   (konpi's newsroom / editorial doctrine, the live ops org design) is updated
   via an **inbox note**, not a direct edit. The platform primitive is ours;
   how a domain adopts it is theirs.

## Why this exists

Agents build from seed knowledge; humans operate from runbooks; clones resolve
from spec. A capability that only lives in code is invisible to all three — the
org keeps running the old shape. Skipping the propagation is the most common
"it works but nobody uses it" failure.

> Do not wait to be told to update seed knowledge / runbooks. It is part of the
> change, every time.
