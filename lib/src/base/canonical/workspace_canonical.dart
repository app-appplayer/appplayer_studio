import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:brain_kernel/brain_kernel.dart'
    show
        BundleManifest,
        Canonical,
        CanonicalChange,
        CanonicalChangeKind,
        CanonicalStoragePort,
        CliOriginator,
        ImportOriginator,
        LlmOriginator,
        McpBundle,
        McpClientOriginator,
        PatchOp,
        PatchOriginator,
        UserOriginator,
        ValidationSeverity;

import '../infra/workspace_fs_port.dart';
import '../spec/spec_validator.dart';
import '../types/builder_exceptions.dart';
import '../types/canonical_patch.dart';

/// Owns the lifecycle of the canonical `.mbd/` directory backing the workspace
/// project. The on-disk bytes + draft mirror are delegated to a kernel
/// [Canonical]; this class layers vibe-flavoured concerns (JSON-Patch
/// op application against the in-memory state, hash-based dirty tracking,
/// undo / redo stacks, layer-id routing, spec validation) on top.
///
/// The authoritative state is the raw JSON map ([currentJson]) — the
/// typed [McpBundle] view is a coarse projection that may drop
/// `ApplicationDefinition` fields mcp_bundle does not model (lifecycle,
/// services, routes-as-map, dashboard, i18n, ...). Properties / LLM tools
/// MUST address [currentJson]; consumers that only need typed sections may
/// still read [current].
///
/// Save semantics: [applyAtomic] mutates the in-memory state and emits a
/// [CanonicalChange]; nothing hits disk until [save] (writes to the current
/// workspace path) or [saveAs] (writes to a new path and adopts it). The
/// [isDirty] flag goes high on the first patch after open / save, and
/// drops back to false after a successful save.
abstract interface class WorkspaceCanonical {
  /// Open or create the canonical bundle at [workspacePath].
  Future<McpBundle> open(String workspacePath);

  /// Bring an external bundle (`.mbd/` directory or `.mcpb` archive) into
  /// the workspace and adopt it as the canonical.
  Future<McpBundle> import({required String source, required ImportKind kind});

  /// Apply a patch in memory. Subscribers are notified via [changes];
  /// [isDirty] flips to true. Disk is not touched — call [save] or
  /// [saveAs] to commit.
  Future<void> applyAtomic(CanonicalPatch patch);

  /// Persist the in-memory bundle to the currently-open workspace path.
  /// Throws [StateError] when the canonical has never been opened.
  Future<void> save();

  /// Persist the in-memory bundle to [newPath] and adopt that path as
  /// the workspace. Subscribers receive a [CanonicalChange] noting the
  /// move so previews / projections can re-anchor.
  Future<void> saveAs(String newPath);

  /// Discard in-memory edits, reload the committed bundle from disk, and
  /// drop the autosave draft. No-op when nothing is open. Marks
  /// [isDirty] false on completion.
  Future<void> revert();

  /// Reverse the most recent user-driven [applyAtomic] (originator
  /// kinds other than `user.undo` / `user.redo`). Returns true when an
  /// undo was performed, false when the undo stack is empty.
  /// The forward patch is moved onto the redo stack so [redo] can
  /// replay it. Bundle / project lifecycle transitions (open / save /
  /// import / saveAs / revert) clear both stacks — they imply a new
  /// editing context where prior inverses no longer make sense.
  Future<bool> undo();

  /// Re-apply the most recent undone patch. Returns true on success,
  /// false when the redo stack is empty (e.g. after an undo followed
  /// by a fresh edit, which clears redos by convention).
  Future<bool> redo();

  /// True when there is at least one inverse patch on the undo stack.
  bool get canUndo;

  /// True when there is at least one forward patch on the redo stack.
  bool get canRedo;

  /// Emits whenever [canUndo] / [canRedo] transitions. Hosts that need
  /// to drive button enablement can listen here.
  Stream<UndoState> get undoStateChanges;

  /// Serialised snapshot of the undo / redo stacks. Hosts persist this
  /// (e.g. to `<projectPath>/undo.json`) so the user can keep undoing
  /// across an app restart.
  ///
  /// Each entry is a [CanonicalPatch] in JSON form: `{layer, ops,
  /// originator}`. Bottom of the stack first; the most-recent entry
  /// (next to be undone) is the last element.
  List<Map<String, dynamic>> get undoStackJson;
  List<Map<String, dynamic>> get redoStackJson;

  /// Restore previously-persisted undo / redo stacks. Typically called
  /// from [VibeProject.openAt] right after [open] to pick up where the
  /// previous session left off. Pass empty lists to reset.
  void seedUndoStacks({
    required List<Map<String, dynamic>> undo,
    required List<Map<String, dynamic>> redo,
  });

  /// True when there are in-memory edits not yet written to disk.
  bool get isDirty;

  /// True when [open] picked up an autosave draft newer than the
  /// committed bundle — the host should surface a "restored unsaved
  /// changes" affordance so the user can save / revert with intent.
  /// Resets to false after [save] / [saveAs] / [revert] / next [open].
  bool get hasRestoredDraft;

  /// Emits the current dirty state on every transition (true on first
  /// patch since open / save, false on save / saveAs / open / import).
  Stream<bool> get dirtyChanges;

  /// Stream of in-memory mutations.
  Stream<CanonicalChange> get changes;

  /// Content hash of the current bundle (mcp_bundle Integrity format).
  Future<String> hash();

  /// Hash of the canonical as it was last persisted to disk (open /
  /// save / saveAs / revert). Useful for "external edit" detection:
  /// compute the same hash off the disk bytes and compare — when
  /// they diverge, something outside vibe touched the bundle.
  /// Returns null when nothing has been opened yet.
  String? get committedHash;

  /// The currently loaded canonical bundle (typed projection).
  McpBundle get current;

  /// The currently loaded canonical bundle as a raw JSON map. Authoritative
  /// for fields outside mcp_bundle's typed schema.
  Map<String, dynamic> get currentJson;

  /// Absolute path of the open workspace, or null when no bundle has
  /// been opened yet.
  String? get workspacePath;
}

/// Snapshot of [WorkspaceCanonical.canUndo] / [canRedo] used by
/// [WorkspaceCanonical.undoStateChanges].
class UndoState {
  const UndoState({required this.canUndo, required this.canRedo});
  final bool canUndo;
  final bool canRedo;
}

/// Default implementation. See `core-workspace-canonical.md` (DDD) for the
/// full contract.
///
/// Wraps a kernel [Canonical] for the on-disk bytes + draft-mirror role,
/// adapting [WorkspaceFsPort] into a [CanonicalStoragePort] so vibe's
/// reserved-folder semantics (manifest + `ui/app.json` + `ui/pages/<id>.json`)
/// drive what kernel reads / writes. Every concern that lives above the
/// raw bytes — JSON-Patch op application, hash-based dirty tracking,
/// undo / redo stacks, layer routing, spec validation — stays in this
/// class.
class WorkspaceCanonicalImpl implements WorkspaceCanonical {
  WorkspaceCanonicalImpl({
    required WorkspaceFsPort fsPort,
    required SpecValidator validator,
  }) : _fsPort = fsPort,
       _validator = validator,
       _storage = _FullDirectoryCanonicalStorage(fsPort);

  final WorkspaceFsPort _fsPort;
  final SpecValidator _validator;
  final CanonicalStoragePort _storage;

  /// Kernel-side bundle storage + draft mirror. Created lazily on the
  /// first [open] / [import] call.
  Canonical? _kernel;

  /// Subscription bridging kernel-emitted patch changes through this
  /// class's [changes] stream so subscribers see one consistent feed.
  StreamSubscription<CanonicalChange>? _kernelChangesSub;

  // Sync broadcast — events fire inline so a subscriber attached after
  // `open()` reliably sees only post-open mutations. Async broadcast
  // schedules delivery via microtask, which (depending on event-loop
  // ordering) can leak prior open-emit events to late subscribers.
  final StreamController<CanonicalChange> _changes =
      StreamController<CanonicalChange>.broadcast(sync: true);
  final StreamController<bool> _dirty = StreamController<bool>.broadcast(
    sync: true,
  );
  final StreamController<UndoState> _undoState =
      StreamController<UndoState>.broadcast(sync: true);

  String? _workspacePath;
  bool _isDirty = false;

  /// Hash of the bundle as it sits on disk at the active workspace
  /// path. Updated on `open` (to the committed JSON, even when a
  /// draft is restored), `save`, `saveAs`, and `revert`. Used by
  /// `applyAtomic` to drive the dirty flag by hash compare so undo
  /// back to the saved state correctly clears the "unsaved" badge.
  String? _committedHash;

  /// Inverse-patch stack. Each entry undoes one [applyAtomic] call.
  /// Cleared on lifecycle transitions (open / saveAs / revert / import)
  /// because those invalidate the editing context.
  final List<CanonicalPatch> _undoStack = <CanonicalPatch>[];

  /// Forward-patch stack. Populated by [undo]; cleared by any new
  /// user-driven [applyAtomic] (the standard editor "fresh edit drops
  /// redos" rule).
  final List<CanonicalPatch> _redoStack = <CanonicalPatch>[];

  /// Originator that should bypass undo bookkeeping when applied —
  /// these patches are themselves the undo / redo machinery emitting
  /// against canonical and should not feed back into the stacks.
  static bool _isMetaOriginator(PatchOriginator o) =>
      o is UserOriginator && (o.note == 'undo' || o.note == 'redo');

  void _emitUndoState() {
    _undoState.add(UndoState(canUndo: canUndo, canRedo: canRedo));
  }

  void _clearUndoStacks() {
    _undoStack.clear();
    _redoStack.clear();
    // Always emit — the previous "only when hadAny" guard skipped the
    // notification when the in-memory stacks were already empty even
    // though the listener-side cache (e.g. shell's `_canUndo`) might
    // disagree (stale from a previous transition). The empty-emit is
    // cheap and aligns subscribers to the canonical source of truth.
    _emitUndoState();
  }

  void _setDirty(bool value) {
    if (_isDirty == value) return;
    _isDirty = value;
    _dirty.add(value);
  }

  /// Sibling directory used to autosave in-progress edits. We deliberately
  /// keep it next to the `.mbd` rather than inside, so the committed
  /// bundle's contents stay untouched until an explicit save and the
  /// draft is easy to spot / clean up out-of-band.
  static String _draftPathFor(String workspacePath) => '$workspacePath.draft';

  Future<void> _disposeKernel() async {
    await _kernelChangesSub?.cancel();
    _kernelChangesSub = null;
    await _kernel?.dispose();
    _kernel = null;
  }

  /// Bridge kernel-emitted patch events through this class's stream.
  /// Kernel's `commit` / `saveAs` / `revert` callbacks emit synthetic
  /// patch events with empty changedPointers; we drop those and emit
  /// our own vibe-flavoured kind in the matching method.
  void _onKernelChange(CanonicalChange change) {
    if (change.kind != CanonicalChangeKind.patch) return;
    if (change.changedPointers.isEmpty) return;
    _changes.add(change);
  }

  @override
  Future<McpBundle> open(String workspacePath) async {
    final beforeJson = _kernel?.bundleJson;
    await _fsPort.ensureDir(workspacePath);

    // Pre-kernel normalisation: auto-create empty bundle on first open
    // and stamp the `ui.type == "application"` discriminator on legacy
    // projects so `UIDefinition.fromJson` parses the body as an
    // Application instead of a Page. Done at the disk layer (not via
    // a kernel.applyAtomic patch) to keep `open()` emitting a single
    // `open` change — folding normalisation into a synthetic patch
    // would leak an extra `patch` event to subscribers attached after
    // open returns.
    final committed = await _fsPort.readJson(workspacePath);
    final rawCommitted = committed ?? _emptyJson();
    final normalised = _ensureUiApplicationDiscriminator(rawCommitted);
    final committedJson = normalised ?? rawCommitted;
    if (committed == null || normalised != null) {
      await _fsPort.writeAtomicJson(committedJson, workspacePath);
    }

    // Hand the file to the kernel — it inspects `<workspace>.draft/`,
    // restores the draft when it differs from the committed bundle,
    // and exposes the chosen state via [bundleJson] / [hasRestoredDraft].
    await _disposeKernel();
    _kernel = await Canonical.openAt(
      workspacePath,
      draftPath: _draftPathFor(workspacePath),
      storage: _storage,
    );
    _kernelChangesSub = _kernel!.changes.listen(_onKernelChange);

    _workspacePath = workspacePath;
    // Anchor the disk hash on the committed JSON, even when a draft
    // was restored — that way undoing back through the draft edits
    // can correctly clear the dirty flag once we land at disk state.
    _committedHash = _hashOfJson(committedJson);
    _setDirty(_kernel!.hasRestoredDraft);
    // Different bundle context — prior inverses no longer apply.
    _clearUndoStacks();
    // Notify subscribers (shell, preview adapters) that the canonical now
    // points at a different bundle so projections rebuild from scratch.
    _changes.add(
      CanonicalChange(
        changedPointers: const <String>['/'],
        beforeHash: beforeJson == null ? '' : _hashOfJson(beforeJson),
        afterHash: _hashOfJson(_kernel!.bundleJson),
        kind: CanonicalChangeKind.open,
        timestamp: DateTime.now().toUtc(),
      ),
    );
    return _bundleFromJson(_kernel!.bundleJson);
  }

  @override
  Future<McpBundle> import({
    required String source,
    required ImportKind kind,
  }) async {
    final isMcpb = source.endsWith('.mcpb');
    if (kind == ImportKind.mbd && isMcpb) {
      throw ImportException('source $source has .mcpb extension but kind=mbd');
    }
    if (kind == ImportKind.mcpb && !isMcpb) {
      throw ImportException(
        'source $source has no .mcpb extension but kind=mcpb',
      );
    }
    final json = await _fsPort.readJson(source);
    if (json == null) {
      throw ImportException('source $source not found');
    }
    // Adopt the source path as the new workspace. Re-open the kernel
    // canonical against it so the draft mirror anchors at the right
    // place.
    await _disposeKernel();
    _kernel = await Canonical.openAt(
      source,
      draftPath: _draftPathFor(source),
      storage: _storage,
    );
    _kernelChangesSub = _kernel!.changes.listen(_onKernelChange);
    _workspacePath = source;
    _committedHash = _hashOfJson(json);
    _setDirty(false);
    _clearUndoStacks();
    return _bundleFromJson(_kernel!.bundleJson);
  }

  @override
  Future<void> applyAtomic(CanonicalPatch patch) async {
    if (patch.ops.isEmpty) return;
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('open() must be called before applyAtomic()');
    }
    final issues = _validator.dryRun(_bundleFromJson(kernel.bundleJson), patch);
    final blocked =
        issues.where((i) => i.severity == ValidationSeverity.error).toList();
    if (blocked.isNotEmpty) {
      throw ValidationException(blocked);
    }
    final beforeJson = kernel.bundleJson;
    final beforeHash = _hashOfJson(beforeJson);
    final updatedJson = _deepCopyMap(beforeJson);
    for (final op in patch.ops) {
      _applyOp(updatedJson, op);
    }
    final afterHash = _hashOfJson(updatedJson);
    // No-op patch (e.g. re-importing identical content): skip the
    // undo entry, the kernel handoff, and the change notification —
    // there's nothing for the user to roll back, save, or react to.
    if (afterHash == beforeHash) return;

    // Compute inverse against the BEFORE state (post-mutation `peek`s
    // would resolve against the wrong shape).
    final inverse =
        _isMetaOriginator(patch.originator)
            ? null
            : _computeInverse(patch, beforeJson);

    // Hand off to the kernel — kernel mirrors to draft + emits the
    // `patch` change which our subscription forwards.
    await kernel.applyAtomic(
      updatedJson,
      changedPointers: patch.ops.map((o) => o.path).toList(),
      originator: patch.originator,
    );

    // Dirty by hash — undoing back to the saved state should clear
    // the unsaved badge, not just keep accumulating.
    final committed = _committedHash;
    _setDirty(committed == null || afterHash != committed);

    // Undo bookkeeping. user.undo / user.redo originators are the
    // engine driving the stacks themselves and must not feed back; the
    // calling code (`undo` / `redo`) updates the stacks directly.
    if (inverse != null) {
      if (inverse.ops.isNotEmpty) {
        _undoStack.add(inverse);
      }
      // Fresh edit drops the redo stack (standard editor convention).
      final hadRedo = _redoStack.isNotEmpty;
      _redoStack.clear();
      if (inverse.ops.isNotEmpty || hadRedo) _emitUndoState();
    }
  }

  @override
  Future<bool> undo() async {
    if (_undoStack.isEmpty) return false;
    final kernel = _kernel;
    if (kernel == null) return false;
    final inverse = _undoStack.removeLast();
    // Compute the redo (forward of the inverse against the
    // post-inverse state) BEFORE applying, but using the current state
    // — applying the inverse to current JSON yields the prior state,
    // so the inverse-of-inverse-against-current is the original
    // forward.
    final redoForward = _computeInverse(
      CanonicalPatch(
        layer: inverse.layer,
        ops: inverse.ops,
        originator: const UserOriginator(note: 'redo'),
      ),
      kernel.bundleJson,
    );
    await applyAtomic(
      CanonicalPatch(
        layer: inverse.layer,
        ops: inverse.ops,
        originator: const UserOriginator(note: 'undo'),
      ),
    );
    if (redoForward.ops.isNotEmpty) {
      _redoStack.add(redoForward);
    }
    _emitUndoState();
    return true;
  }

  @override
  Future<bool> redo() async {
    if (_redoStack.isEmpty) return false;
    final kernel = _kernel;
    if (kernel == null) return false;
    final forward = _redoStack.removeLast();
    final undoInverse = _computeInverse(
      CanonicalPatch(
        layer: forward.layer,
        ops: forward.ops,
        originator: const UserOriginator(note: 'undo'),
      ),
      kernel.bundleJson,
    );
    await applyAtomic(
      CanonicalPatch(
        layer: forward.layer,
        ops: forward.ops,
        originator: const UserOriginator(note: 'redo'),
      ),
    );
    if (undoInverse.ops.isNotEmpty) {
      _undoStack.add(undoInverse);
    }
    _emitUndoState();
    return true;
  }

  @override
  bool get canUndo => _undoStack.isNotEmpty;

  @override
  bool get canRedo => _redoStack.isNotEmpty;

  @override
  Stream<UndoState> get undoStateChanges => _undoState.stream;

  @override
  List<Map<String, dynamic>> get undoStackJson =>
      _undoStack.map(_patchToJson).toList();

  @override
  List<Map<String, dynamic>> get redoStackJson =>
      _redoStack.map(_patchToJson).toList();

  @override
  void seedUndoStacks({
    required List<Map<String, dynamic>> undo,
    required List<Map<String, dynamic>> redo,
  }) {
    _undoStack
      ..clear()
      ..addAll(undo.map(_patchFromJson).whereType<CanonicalPatch>());
    _redoStack
      ..clear()
      ..addAll(redo.map(_patchFromJson).whereType<CanonicalPatch>());
    _emitUndoState();
  }

  static Map<String, dynamic> _patchToJson(CanonicalPatch p) =>
      <String, dynamic>{
        'layer': p.layer.name,
        'ops': <Map<String, dynamic>>[
          for (final op in p.ops)
            <String, dynamic>{
              'op': op.op,
              'path': op.path,
              if (op.value != null) 'value': op.value,
            },
        ],
        'originator': p.originator.toJson(),
      };

  static CanonicalPatch? _patchFromJson(Map<String, dynamic> json) {
    final layerName = json['layer'] as String?;
    LayerId? layer;
    for (final id in LayerId.values) {
      if (id.name == layerName) {
        layer = id;
        break;
      }
    }
    if (layer == null) return null;
    final rawOps = json['ops'];
    if (rawOps is! List) return null;
    final ops = <PatchOp>[];
    for (final raw in rawOps) {
      if (raw is! Map) continue;
      final op = raw['op'] as String?;
      final path = raw['path'] as String?;
      if (op == null || path == null) continue;
      ops.add(PatchOp(op: op, path: path, value: raw['value']));
    }
    if (ops.isEmpty) return null;
    final origRaw = json['originator'];
    final origin = _originatorFromJson(origRaw);
    return CanonicalPatch(layer: layer, ops: ops, originator: origin);
  }

  /// Reconstructs a [PatchOriginator] subtype from its JSON form.
  /// Falls back to `UserOriginator()` for unknown / missing kinds so a
  /// corrupt sidecar entry never blocks project open.
  static PatchOriginator _originatorFromJson(Object? raw) {
    if (raw is! Map) return const UserOriginator();
    final kind = raw['kind'] as String?;
    switch (kind) {
      case 'user':
        return UserOriginator(note: raw['note'] as String?);
      case 'llm':
        return LlmOriginator(
          turnId: (raw['turnId'] as String?) ?? '',
          toolName: raw['toolName'] as String?,
        );
      case 'mcpClient':
        return McpClientOriginator(
          clientId: (raw['clientId'] as String?) ?? '',
          toolName: (raw['toolName'] as String?) ?? '',
        );
      case 'cli':
        return CliOriginator(subcommand: (raw['subcommand'] as String?) ?? '');
      case 'import':
        return ImportOriginator(
          sourcePath: (raw['sourcePath'] as String?) ?? '',
        );
      default:
        return const UserOriginator();
    }
  }

  /// Walk [patch] against [before] and emit a patch whose ops, when
  /// applied to the post-[patch] state, return the JSON to its prior
  /// shape. Per RFC 6902 inversion semantics:
  ///   * `add` / `replace` at path X → if X already existed, inverse is
  ///     `replace` with the prior value; if X did not exist, inverse is
  ///     `remove`.
  ///   * `remove` at path X → inverse is `add` with the prior value (or
  ///     no-op if X was already absent).
  /// Ops are emitted in reverse so applying them undoes the forward
  /// patch in LIFO order — relevant when one op depends on a parent
  /// container created by a sibling op in the same patch.
  static CanonicalPatch _computeInverse(
    CanonicalPatch patch,
    Map<String, dynamic> before,
  ) {
    final inverseOps = <PatchOp>[];
    for (final op in patch.ops.reversed) {
      final probe = _peek(before, op.path);
      final parentIsList = _parentIsList(before, op.path);
      switch (op.op) {
        case 'add':
          if (parentIsList) {
            // List `add` inserts (shifts right). Inverse is always
            // `remove` at the same index — regardless of whether
            // something was at that index before.
            inverseOps.add(PatchOp(op: 'remove', path: op.path));
          } else if (probe.present) {
            inverseOps.add(
              PatchOp(
                op: 'replace',
                path: op.path,
                value: _deepCopyValue(probe.value),
              ),
            );
          } else {
            inverseOps.add(PatchOp(op: 'remove', path: op.path));
          }
          break;
        case 'replace':
          if (probe.present) {
            inverseOps.add(
              PatchOp(
                op: 'replace',
                path: op.path,
                value: _deepCopyValue(probe.value),
              ),
            );
          } else {
            inverseOps.add(PatchOp(op: 'remove', path: op.path));
          }
          break;
        case 'remove':
          if (probe.present) {
            inverseOps.add(
              PatchOp(
                op: 'add',
                path: op.path,
                value: _deepCopyValue(probe.value),
              ),
            );
          }
          // Removing an absent path is a no-op; inverse is also no-op.
          break;
      }
    }
    // Inverse patches are themselves user-driven (undo / redo emit
    // them through this very stack). The originator is a UserOriginator
    // tagged with `inverse` so audit consumers can distinguish forward
    // edits from rollback edits without inspecting the patch payload.
    return CanonicalPatch(
      layer: patch.layer,
      ops: inverseOps,
      originator: const UserOriginator(note: 'inverse'),
    );
  }

  /// True when [path]'s parent container in [before] is a List.
  /// Distinguishes List-index ops (insert/remove shift) from Map-key
  /// ops (overwrite). Returns false when the parent doesn't exist.
  static bool _parentIsList(Map<String, dynamic> before, String path) {
    final segments =
        path
            .split('/')
            .where((s) => s.isNotEmpty)
            .map(_unescapePointer)
            .toList();
    if (segments.length < 2) return false;
    dynamic cursor = before;
    for (var i = 0; i < segments.length - 1; i++) {
      final seg = segments[i];
      if (cursor is List) {
        final idx = int.tryParse(seg);
        if (idx == null || idx < 0 || idx >= cursor.length) return false;
        cursor = cursor[idx];
      } else if (cursor is Map) {
        cursor = cursor[seg];
      } else {
        return false;
      }
    }
    return cursor is List;
  }

  /// Probe [root] at [path]. Returns presence + value so callers can
  /// distinguish "absent" from "present and null-valued". Path syntax
  /// is the same RFC-6902 flavour [_applyOp] consumes — walks both
  /// Map keys (string) and List indices (int).
  static _Probe _peek(Map<String, dynamic> root, String path) {
    final segments =
        path
            .split('/')
            .where((s) => s.isNotEmpty)
            .map(_unescapePointer)
            .toList();
    if (segments.isEmpty) return const _Probe.absent();
    dynamic cursor = root;
    for (var i = 0; i < segments.length - 1; i++) {
      final seg = segments[i];
      if (cursor is List) {
        final idx = int.tryParse(seg);
        if (idx == null || idx < 0 || idx >= cursor.length) {
          return const _Probe.absent();
        }
        cursor = cursor[idx];
        continue;
      }
      if (cursor is! Map) return const _Probe.absent();
      final next = cursor[seg];
      if (next == null && !cursor.containsKey(seg)) {
        return const _Probe.absent();
      }
      cursor = next;
    }
    final leaf = segments.last;
    if (cursor is List) {
      final idx = int.tryParse(leaf);
      if (idx == null || idx < 0 || idx >= cursor.length) {
        return const _Probe.absent();
      }
      return _Probe.present(cursor[idx]);
    }
    if (cursor is! Map) return const _Probe.absent();
    if (!cursor.containsKey(leaf)) return const _Probe.absent();
    return _Probe.present(cursor[leaf]);
  }

  @override
  Future<void> save() async {
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('open() must be called before save()');
    }
    await kernel.commit();
    _committedHash = _hashOfJson(kernel.bundleJson);
    _setDirty(false);
  }

  @override
  Future<void> saveAs(String newPath) async {
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('open() must be called before saveAs()');
    }
    await _fsPort.ensureDir(newPath);
    final beforeHash = _hashOfJson(kernel.bundleJson);
    await kernel.commitAs(newPath);
    _workspacePath = newPath;
    _committedHash = beforeHash;
    _setDirty(false);
    // Workspace path moved — bundle bytes are the same, so undo stacks
    // remain valid against the in-memory state. We intentionally do
    // NOT clear them on saveAs.
    _changes.add(
      CanonicalChange(
        changedPointers: const <String>['/'],
        beforeHash: beforeHash,
        afterHash: beforeHash,
        kind: CanonicalChangeKind.saveAs,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  Future<void> revert() async {
    final kernel = _kernel;
    if (kernel == null) return;
    final beforeJson = kernel.bundleJson;
    await kernel.revert();
    final afterJson = kernel.bundleJson;
    _committedHash = _hashOfJson(afterJson);
    _setDirty(false);
    _clearUndoStacks();
    _changes.add(
      CanonicalChange(
        changedPointers: const <String>['/'],
        beforeHash: _hashOfJson(beforeJson),
        afterHash: _hashOfJson(afterJson),
        kind: CanonicalChangeKind.revert,
        timestamp: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  bool get hasRestoredDraft => _kernel?.hasRestoredDraft ?? false;

  @override
  bool get isDirty => _isDirty;

  @override
  Stream<bool> get dirtyChanges => _dirty.stream;

  @override
  String? get workspacePath => _workspacePath;

  @override
  Stream<CanonicalChange> get changes => _changes.stream;

  @override
  Future<String> hash() async {
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('open() must be called before hash()');
    }
    return _hashOfJson(kernel.bundleJson);
  }

  @override
  String? get committedHash => _committedHash;

  @override
  McpBundle get current {
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('open() must be called before current');
    }
    return _bundleFromJson(kernel.bundleJson);
  }

  @override
  Map<String, dynamic> get currentJson {
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('open() must be called before currentJson');
    }
    return kernel.bundleJson;
  }

  /// Best-effort raw → typed view. The vibe canonical stores some sections
  /// (notably `ui.pages` as a map keyed by id) in shapes mcp_bundle's
  /// strict [UiSection] does not parse. When that fails we drop the offending
  /// section so the typed [McpBundle] view still hands consumers something
  /// usable; full data lives in [currentJson].
  static McpBundle _bundleFromJson(Map<String, dynamic> json) {
    try {
      return McpBundle.fromJson(Map<String, dynamic>.from(json));
    } catch (uiError, uiStack) {
      // Drop `ui` only when it is actually the offender (vibe stores
      // `ui.pages` as an id-keyed map that mcp_bundle's strict UiSection
      // cannot type — full data still lives in [currentJson]). If
      // removing `ui` does NOT fix the parse, the error is elsewhere:
      // resurface the original cause instead of returning a misleading
      // "0 UI" bundle that swallows the real malformation
      // (feedback_no_fallback_anywhere).
      if (json['ui'] == null) rethrow;
      final fallback = Map<String, dynamic>.from(json)..remove('ui');
      try {
        return McpBundle.fromJson(fallback);
      } catch (_) {
        Error.throwWithStackTrace(uiError, uiStack);
      }
    }
  }

  /// Forward-compat: ensure `ui.type == "application"` in [json]. Returns
  /// a normalised copy when a change is needed, or null when the input
  /// is already conformant. Pure-functional so we can hand the result
  /// to the kernel as a fresh applyAtomic.
  static Map<String, dynamic>? _ensureUiApplicationDiscriminator(
    Map<String, dynamic> json,
  ) {
    final ui = json['ui'];
    if (ui is Map<String, dynamic>) {
      if (ui['type'] == 'application') return null;
      final next = _deepCopyMap(json);
      (next['ui'] as Map<String, dynamic>)['type'] = 'application';
      return next;
    }
    if (ui is Map) {
      final next = _deepCopyMap(json);
      final retyped = Map<String, dynamic>.from(ui);
      retyped['type'] = 'application';
      next['ui'] = retyped;
      return next;
    }
    final next = _deepCopyMap(json);
    next['ui'] = <String, dynamic>{'type': 'application'};
    return next;
  }

  /// Spec-conformant empty canonical seed. Every required
  /// ApplicationDefinition slot is present — even if empty — so
  /// LLMs / tools / runtime never have to special-case "field
  /// missing". Title is a placeholder the author overwrites;
  /// routes / pages / templates start as empty maps so set_property
  /// can grow them with the `add` op without missing-parent errors.
  static Map<String, dynamic> _emptyJson() => <String, dynamic>{
    'manifest':
        const BundleManifest(
          id: 'untitled',
          name: 'Untitled',
          version: '0.1.0',
        ).toJson(),
    'ui': <String, dynamic>{
      'type': 'application',
      'title': 'Untitled App',
      'initialRoute': '/',
      'routes': <String, dynamic>{},
      'pages': <String, dynamic>{},
      'templates': <String, dynamic>{},
      'theme': <String, dynamic>{},
    },
  };

  static String _hashOfJson(Map<String, dynamic> json) {
    final encoded = jsonEncode(json);
    return 'sha256:${sha256.convert(utf8.encode(encoded))}';
  }

  static Map<String, dynamic> _deepCopyMap(Map<String, dynamic> source) {
    final result = <String, dynamic>{};
    source.forEach((k, v) {
      result[k] = _deepCopyValue(v);
    });
    return result;
  }

  static dynamic _deepCopyValue(dynamic v) {
    if (v is Map) {
      return _deepCopyMap(Map<String, dynamic>.from(v));
    }
    if (v is List) {
      return <dynamic>[for (final e in v) _deepCopyValue(e)];
    }
    return v;
  }

  /// Apply one RFC 6902-flavoured operation in place. `add` and `replace`
  /// upsert through nested maps; intermediate keys are created on demand.
  /// `remove` deletes the leaf if present.
  /// RFC 6901 reference-token unescape: `~1` → `/`, `~0` → `~`,
  /// applied in that order. Without this, a key containing `/`
  /// (e.g. URL routes like `/about`) cannot round-trip through a
  /// JSON Pointer because the escape sequence is left literal in
  /// the resolved key.
  static String _unescapePointer(String segment) =>
      segment.replaceAll('~1', '/').replaceAll('~0', '~');

  static void _applyOp(Map<String, dynamic> root, PatchOp op) {
    final segments =
        op.path
            .split('/')
            .where((s) => s.isNotEmpty)
            .map(_unescapePointer)
            .toList();
    if (segments.isEmpty) return;
    // Cursor walks both Maps (string-keyed) and Lists (int-keyed) so
    // patches like `/ui/.../children/2/text` resolve correctly.
    dynamic cursor = root;
    for (var i = 0; i < segments.length - 1; i++) {
      final seg = segments[i];
      if (cursor is List) {
        final idx = int.tryParse(seg);
        if (idx == null || idx < 0 || idx >= cursor.length) return;
        final next = cursor[idx];
        if (next is Map<String, dynamic>) {
          cursor = next;
        } else if (next is Map) {
          final retyped = Map<String, dynamic>.from(next);
          cursor[idx] = retyped;
          cursor = retyped;
        } else if (next is List) {
          cursor = next;
        } else {
          // Cannot create a sub-container inside a non-container array
          // element. Bail rather than corrupt the list.
          return;
        }
        continue;
      }
      if (cursor is! Map) return;
      final next = cursor[seg];
      if (next is Map<String, dynamic>) {
        cursor = next;
      } else if (next is Map) {
        // Re-cast a non-typed Map to the strict shape and re-anchor.
        final retyped = Map<String, dynamic>.from(next);
        cursor[seg] = retyped;
        cursor = retyped;
      } else if (next is List) {
        cursor = next;
      } else {
        // 'replace' on a missing path silently no-ops per RFC 6902, but
        // for vibe we want add-or-replace semantics: create the path.
        final fresh = <String, dynamic>{};
        cursor[seg] = fresh;
        cursor = fresh;
      }
    }
    final leaf = segments.last;
    switch (op.op) {
      case 'add':
      case 'replace':
        if (cursor is List) {
          if (leaf == '-') {
            // RFC 6902: '-' appends.
            cursor.add(op.value);
            return;
          }
          final idx = int.tryParse(leaf);
          if (idx == null || idx < 0) return;
          if (op.op == 'add') {
            // Insert (shift right). idx == length appends.
            if (idx > cursor.length) return;
            cursor.insert(idx, op.value);
          } else {
            // 'replace' must hit an existing index.
            if (idx >= cursor.length) return;
            cursor[idx] = op.value;
          }
          return;
        }
        if (cursor is Map) cursor[leaf] = op.value;
        return;
      case 'remove':
        if (cursor is List) {
          final idx = int.tryParse(leaf);
          if (idx == null || idx < 0 || idx >= cursor.length) return;
          cursor.removeAt(idx);
          return;
        }
        if (cursor is Map) cursor.remove(leaf);
        return;
    }
  }

  Future<void> dispose() async {
    await _disposeKernel();
    await _changes.close();
    await _dirty.close();
    await _undoState.close();
  }
}

/// Adapts a vibe [WorkspaceFsPort] to the kernel's [CanonicalStoragePort].
/// Lets [WorkspaceCanonicalImpl] hand its FS abstraction (real disk in
/// production, in-memory map in tests) over to the kernel canonical
/// without the kernel learning about vibe's port shape.
class _FullDirectoryCanonicalStorage implements CanonicalStoragePort {
  const _FullDirectoryCanonicalStorage(this._fsPort);

  final WorkspaceFsPort _fsPort;

  @override
  Future<Map<String, dynamic>?> readJson(String dirPath) =>
      _fsPort.readJson(dirPath);

  @override
  Future<void> writeJson(Map<String, dynamic> json, String dirPath) =>
      _fsPort.writeAtomicJson(json, dirPath);

  @override
  Future<bool> dirExists(String dirPath) => _fsPort.dirExists(dirPath);

  @override
  Future<void> deleteDir(String dirPath) => _fsPort.deleteDir(dirPath);
}

/// Result of [WorkspaceCanonicalImpl._peek] — distinguishes "key
/// missing" from "key present and value is null" without sentinel
/// magic.
class _Probe {
  const _Probe.present(this.value) : present = true;
  const _Probe.absent() : value = null, present = false;
  final bool present;
  final dynamic value;
}
