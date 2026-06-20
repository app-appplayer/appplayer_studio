import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../infra/vibe_chat_log.dart';
import '../infra/vibe_history_log.dart';
import '../infra/vibe_project_prefs.dart';
import '../infra/vibe_undo_sidecar.dart';
import 'types.dart';
import 'workspace_canonical.dart';

/// Top-level container for an AppPlayer Builder project. Each project is
/// a regular folder with a single `project.apbproj` metadata file at its
/// root. The folder name is independent of the displayed project name —
/// the user can rename either without breaking the other.
///
///   MyProject/
///     project.apbproj      ← metadata (name · timestamps · schemaVersion)
///     app.mbd/             ← the mcp_ui bundle (loaded via
///                            [WorkspaceCanonical])
///     app.mbd.draft/       ← autosave mirror managed by canonical
///     prefs.json           ← UI prefs (focused layer, preview size, ...)
///     chat.jsonl           ← LLM dialogue log
///     history.jsonl        ← canonical-change audit log
///     undo.json            ← persisted undo / redo stacks
///
/// Project lifecycle (this class) is distinct from bundle UI lifecycle
/// (WorkspaceCanonical). Project ops: open / save / saveAs / revert /
/// rename / importBundle / exportBundle. Bundle UI ops (applyAtomic,
/// dirty, changes, ...) stay on canonical and are exposed verbatim.
class VibeProject {
  VibeProject({
    required this.projectPath,
    required this.canonical,
    required ProjectMeta meta,
    VibeProjectPrefs? prefs,
    VibeChatLog? chatLog,
    VibeHistoryLog? historyLog,
    VibeUndoSidecar? undoSidecar,
  }) : _meta = meta,
       prefs = prefs ?? VibeProjectPrefs(),
       chatLog = chatLog ?? VibeChatLog.open(projectPath),
       historyLog = historyLog ?? VibeHistoryLog.open(projectPath),
       undoSidecar = undoSidecar ?? VibeUndoSidecar.open(projectPath) {
    // Subscribe to canonical mutations so every change ends up in
    // history.jsonl. Subscription is per-project — `dispose` cancels it
    // when the host swaps to a different project.
    _historySub = canonical.changes.listen(this.historyLog.append);
    // Mirror the in-memory undo / redo stacks to disk on every state
    // transition so a restart or crash preserves "Cmd+Z" continuity.
    _undoSub = canonical.undoStateChanges.listen(_persistUndo);
  }

  /// Absolute path of the project folder. The folder may have any name
  /// (including the legacy `.apbproj` suffix) — what makes it a project
  /// is the presence of [projectFile] at its root.
  final String projectPath;

  /// The bundle UI layer. Re-opened by [openAt] / [importBundle] when
  /// the bundle the project points at changes.
  final WorkspaceCanonical canonical;

  /// Per-project UI prefs (focused layer, last-selected page, …) —
  /// loaded from `<projectPath>/prefs.json` on [openAt]. Mutate the
  /// fields and call [savePrefs] to persist.
  final VibeProjectPrefs prefs;

  /// Append-only chat log at `<projectPath>/chat.jsonl`. The shell
  /// loads turns on open and appends on each new turn.
  final VibeChatLog chatLog;

  /// Append-only audit log at `<projectPath>/history.jsonl`. Every
  /// canonical mutation (patch / open / saveAs / revert) is recorded.
  final VibeHistoryLog historyLog;

  /// Mirror of canonical's undo / redo stacks at
  /// `<projectPath>/undo.json`. Lets undo continue working after the
  /// app restarts.
  final VibeUndoSidecar undoSidecar;

  StreamSubscription<CanonicalChange>? _historySub;
  StreamSubscription<UndoState>? _undoSub;

  ProjectMeta _meta;

  void _persistUndo(UndoState _) {
    // Best-effort — write fresh stack snapshots after every transition.
    final undo = canonical.undoStackJson;
    final redo = canonical.redoStackJson;
    if (undo.isEmpty && redo.isEmpty) {
      undoSidecar.clear();
    } else {
      undoSidecar.write(UndoSnapshot(undo: undo, redo: redo));
    }
  }

  /// Filename for the project metadata JSON, sitting at the root of the
  /// project folder.
  static const String projectFile = 'project.apbproj';

  /// Pre-`project.apbproj` filename that earlier versions wrote. Detected
  /// during [openAt] and migrated forward.
  static const String legacyProjectFile = 'project.json';

  /// Default subdir of the legacy v1 single-bundle layout. Kept as a
  /// constant so migration code can find it without hard-coding the
  /// string at every call site.
  static const String legacyBundleSubdir = 'app.mbd';

  /// Absolute path of the active channel's bundle directory.
  String get bundlePath =>
      p.join(projectPath, _meta.channels[_meta.activeChannel]!.subdir);

  /// Absolute path of the given channel's bundle directory. Returns
  /// null when the channel is missing or disabled.
  String? bundlePathFor(String channelId) {
    final ch = _meta.channels[channelId];
    if (ch == null || !ch.enabled) return null;
    return p.join(projectPath, ch.subdir);
  }

  /// Id of the channel the canonical is currently bound to.
  String get activeChannel => _meta.activeChannel;

  /// Read-only snapshot of the channel registry. Mutate via
  /// [activateChannel] / [createChannel] / [removeChannel].
  Map<String, ChannelDef> get channels => Map.unmodifiable(_meta.channels);

  /// Display name shown in the header. Sourced from project.apbproj,
  /// falling back to the folder basename when the file is missing.
  String get name => _meta.name;

  ProjectMeta get meta => _meta;

  /// Open an existing project or create a fresh one at [projectDir].
  /// Initializes `project.apbproj` + an empty `app.mbd/` if either is
  /// missing, then hands control of `app.mbd/` to [canonical].
  ///
  /// If a legacy `project.json` is found alongside no `project.apbproj`,
  /// it is migrated forward (renamed) so callers always see the new
  /// filename.
  static Future<VibeProject> openAt({
    required String projectDir,
    required WorkspaceCanonical canonical,
    ProjectKind? newProjectKind,
    Future<void> Function(
      String bundleDir,
      ProjectKind kind,
      String projectName,
    )?
    seedNewBundle,
  }) async {
    await Directory(projectDir).create(recursive: true);
    final metaFile = File(p.join(projectDir, projectFile));
    final legacyMetaFile = File(p.join(projectDir, legacyProjectFile));
    if (!await metaFile.exists() && await legacyMetaFile.exists()) {
      await legacyMetaFile.rename(metaFile.path);
    }
    ProjectMeta meta;
    // [newProjectKind] only applies when a project is being created from
    // scratch (no existing meta file). Reopens always restore kind from
    // disk so the user's earlier choice survives across sessions.
    final defaultKind = newProjectKind ?? ProjectKind.appPlayerApp;
    final bool isNewProject = !await metaFile.exists();
    if (await metaFile.exists()) {
      try {
        final raw = jsonDecode(await metaFile.readAsString());
        if (raw is Map<String, dynamic>) {
          meta = ProjectMeta.fromJson(raw);
        } else {
          // Malformed (not a JSON object). Back up the corrupt file
          // before the defaults below get persisted over it — a silent
          // reset+overwrite would destroy the user's project metadata
          // permanently (data-loss class). missing≠malformed: a missing
          // file is the normal new-project path (else branch below).
          await _backupCorruptFile(metaFile);
          meta = ProjectMeta.defaults(
            name: _nameOf(projectDir),
            kind: defaultKind,
          );
        }
      } catch (_) {
        await _backupCorruptFile(metaFile);
        meta = ProjectMeta.defaults(
          name: _nameOf(projectDir),
          kind: defaultKind,
        );
      }
    } else {
      meta = ProjectMeta.defaults(name: _nameOf(projectDir), kind: defaultKind);
    }
    // Apply v1 (`app.mbd/` at root) → v2 (`bundles/serving.mbd/`) on-disk
    // migration before opening canonical, so the canonical lands at the
    // new path immediately.
    meta = await _migrateLegacyBundle(projectDir, meta);
    // Pin the active channel to an enabled one — defaulting to serving,
    // then native, otherwise leave as-is and the canonical-open below
    // will surface the missing-channel error to the caller.
    final activeId = _resolveActiveChannel(meta);
    if (activeId != null) {
      meta = meta.copyWith(activeChannel: activeId);
    }
    // Make sure the active channel's bundle directory exists so the
    // canonical can open it cleanly. mcp_bundle.WorkspaceFsPort writes
    // a fresh manifest when the dir is empty.
    final activeChannel = meta.channels[meta.activeChannel];
    if (activeChannel == null) {
      throw StateError(
        'project ${meta.name} has no active channel — channels: ${meta.channels.keys.toList()}',
      );
    }
    final bundleDir = p.join(projectDir, activeChannel.subdir);
    await Directory(bundleDir).create(recursive: true);
    // First-run seed hook — writes kind-specific template files into
    // the active bundle dir before the canonical reads it, so the
    // initial in-memory state already carries the seed instead of the
    // empty-manifest placeholder mcp_bundle would otherwise insert.
    if (isNewProject && seedNewBundle != null) {
      await seedNewBundle(bundleDir, meta.kind, meta.name);
    }
    // Persist (possibly migrated) meta back to disk before opening so
    // a crash mid-open doesn't leave the project ambiguous.
    await _writeMetaTo(metaFile, meta);
    await canonical.open(bundleDir);
    // Restore persisted undo / redo stacks whenever the sidecar holds
    // any. Cross-session undo is a productivity feature — opening a
    // project after a clean save still lets the user keep stepping
    // back through prior committed states.
    final undoSidecar = VibeUndoSidecar.open(projectDir);
    final undoSnapshot = await undoSidecar.read();
    if (!undoSnapshot.isEmpty) {
      canonical.seedUndoStacks(
        undo: undoSnapshot.undo,
        redo: undoSnapshot.redo,
      );
    }
    final prefs = await VibeProjectPrefs.load(projectDir);
    return VibeProject(
      projectPath: projectDir,
      canonical: canonical,
      meta: meta,
      prefs: prefs,
      chatLog: VibeChatLog.open(projectDir),
      historyLog: VibeHistoryLog.open(projectDir),
      undoSidecar: undoSidecar,
    );
  }

  /// Pick the first enabled channel for [meta.activeChannel]. Returns
  /// null when nothing is enabled, in which case the caller raises.
  static String? _resolveActiveChannel(ProjectMeta meta) {
    final declared = meta.activeChannel;
    final declaredCh = meta.channels[declared];
    if (declaredCh != null && declaredCh.enabled) return declared;
    for (final entry in meta.channels.entries) {
      if (entry.key == '__legacy__') continue;
      if (entry.value.enabled) return entry.key;
    }
    return null;
  }

  /// Detect a v1 layout (a `app.mbd/` directory at the project root,
  /// either because the project was authored before channels existed
  /// or because `ProjectMeta.fromJson` stashed a `__legacy__` channel)
  /// and physically move it under `bundles/serving.mbd/`. Idempotent —
  /// safe to call on already-migrated projects.
  static Future<ProjectMeta> _migrateLegacyBundle(
    String projectDir,
    ProjectMeta meta,
  ) async {
    final legacy = meta.channels['__legacy__'];
    final servingCh = meta.channels['serving'];
    if (legacy == null && servingCh == null) return meta;
    final legacySubdir = legacy?.subdir ?? legacyBundleSubdir;
    final legacyDir = Directory(p.join(projectDir, legacySubdir));
    final legacyDraft = Directory(p.join(projectDir, '$legacySubdir.draft'));
    final newSubdir = servingCh?.subdir ?? 'bundles/serving.mbd';
    final newDir = Directory(p.join(projectDir, newSubdir));
    final newDraft = Directory(p.join(projectDir, '$newSubdir.draft'));
    if (await legacyDir.exists() && !await newDir.exists()) {
      await newDir.parent.create(recursive: true);
      await legacyDir.rename(newDir.path);
    }
    if (await legacyDraft.exists() && !await newDraft.exists()) {
      await newDraft.parent.create(recursive: true);
      await legacyDraft.rename(newDraft.path);
    }
    final cleaned = <String, ChannelDef>{
      for (final e in meta.channels.entries)
        if (e.key != '__legacy__') e.key: e.value,
    };
    if (!cleaned.containsKey('serving')) {
      cleaned['serving'] = ChannelDef(subdir: newSubdir);
    } else {
      cleaned['serving'] = ChannelDef(
        subdir: newSubdir,
        enabled: cleaned['serving']!.enabled,
      );
    }
    if (!cleaned.containsKey('native')) {
      cleaned['native'] = ChannelDef(
        subdir: 'bundles/native.mbd',
        enabled: false,
      );
    }
    return meta.copyWith(channels: cleaned);
  }

  /// Switch the canonical bundle to a different channel. The previous
  /// channel's draft mirror remains on disk untouched — re-activating
  /// it later restores its in-progress state. Throws when [id] is not
  /// a known enabled channel.
  Future<void> activateChannel(String id) async {
    final ch = _meta.channels[id];
    if (ch == null) {
      throw StateError('unknown channel: $id');
    }
    if (!ch.enabled) {
      throw StateError('channel $id is not enabled');
    }
    if (id == _meta.activeChannel) return;
    _meta = _meta.copyWith(activeChannel: id);
    await _writeMeta();
    await Directory(p.join(projectPath, ch.subdir)).create(recursive: true);
    await canonical.open(p.join(projectPath, ch.subdir));
  }

  /// Materialise a previously-disabled channel slot. Creates the
  /// bundle directory if missing, marks the channel `enabled: true`,
  /// persists meta, and (when [activate] is true) opens it as the
  /// canonical's new target.
  Future<void> createChannel(String id, {bool activate = true}) async {
    final ch = _meta.channels[id];
    if (ch == null) {
      throw StateError('unknown channel: $id');
    }
    final dir = Directory(p.join(projectPath, ch.subdir));
    if (!await dir.exists()) await dir.create(recursive: true);
    final updated = ChannelDef(subdir: ch.subdir, enabled: true);
    _meta = _meta.copyWith(
      channels: <String, ChannelDef>{
        for (final e in _meta.channels.entries)
          e.key: e.key == id ? updated : e.value,
      },
    );
    await _writeMeta();
    if (activate) {
      await activateChannel(id);
    }
  }

  /// Replace [target] channel's on-disk bundle with a copy of
  /// [source]'s. Both ids must be known. Re-enables [target] when
  /// disabled (creating its dir on the way). Wipes target's draft
  /// mirror so unsaved edits from the previous tenant don't leak
  /// into the freshly-copied data. The active canonical is reopened
  /// from disk when [target] is currently active so a stale in-memory
  /// view isn't kept around.
  Future<void> copyChannel({
    required String source,
    required String target,
  }) async {
    if (source == target) {
      throw StateError('source and target channels must differ');
    }
    final src = _meta.channels[source];
    final tgt = _meta.channels[target];
    if (src == null) {
      throw StateError('unknown channel: $source');
    }
    if (tgt == null) {
      throw StateError('unknown channel: $target');
    }
    final srcDir = Directory(p.join(projectPath, src.subdir));
    if (!await srcDir.exists()) {
      throw StateError(
        'source channel "$source" has no on-disk bundle to copy',
      );
    }
    // Make sure target is enabled — copy implies the user wants to
    // use it. Persist meta before touching disk so a crash mid-copy
    // leaves a recoverable state.
    if (!tgt.enabled) {
      final updated = ChannelDef(subdir: tgt.subdir, enabled: true);
      _meta = _meta.copyWith(
        channels: <String, ChannelDef>{
          for (final e in _meta.channels.entries)
            e.key: e.key == target ? updated : e.value,
        },
      );
      await _writeMeta();
    }
    final tgtDir = Directory(p.join(projectPath, tgt.subdir));
    if (await tgtDir.exists()) {
      await tgtDir.delete(recursive: true);
    }
    await _copyDir(srcDir, tgtDir);
    final tgtDraft = Directory(p.join(projectPath, '${tgt.subdir}.draft'));
    if (await tgtDraft.exists()) {
      await tgtDraft.delete(recursive: true);
    }
    if (_meta.activeChannel == target) {
      await canonical.open(p.join(projectPath, tgt.subdir));
    }
  }

  /// Swap the on-disk bundle directories of [a] and [b]. Both
  /// channels must exist; neither needs to be enabled (the operation
  /// is data-only — it doesn't touch the enabled flag or the active
  /// channel id). Drafts swap alongside their bundles so unsaved
  /// edits stay tied to the correct content. The active canonical is
  /// reopened so it picks up its new contents in place.
  Future<void> swapChannels(String a, String b) async {
    if (a == b) {
      throw StateError('cannot swap a channel with itself');
    }
    final aDef = _meta.channels[a];
    final bDef = _meta.channels[b];
    if (aDef == null) throw StateError('unknown channel: $a');
    if (bDef == null) throw StateError('unknown channel: $b');
    final aDir = Directory(p.join(projectPath, aDef.subdir));
    final bDir = Directory(p.join(projectPath, bDef.subdir));
    final aDraft = Directory(p.join(projectPath, '${aDef.subdir}.draft'));
    final bDraft = Directory(p.join(projectPath, '${bDef.subdir}.draft'));
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final tmpA = Directory(p.join(projectPath, '.swap_a_$stamp'));
    final tmpADraft = Directory(p.join(projectPath, '.swap_adraft_$stamp'));
    try {
      // Move a → tmpA, b → a, tmpA → b. Both targets are empty
      // between the renames so nothing collides.
      if (await aDir.exists()) await aDir.rename(tmpA.path);
      if (await bDir.exists()) await bDir.rename(aDir.path);
      if (await tmpA.exists()) await tmpA.rename(bDir.path);
      // Drafts swap independently — best-effort. Missing drafts are
      // fine; this is a mirror, not a source of truth.
      if (await aDraft.exists()) await aDraft.rename(tmpADraft.path);
      if (await bDraft.exists()) await bDraft.rename(aDraft.path);
      if (await tmpADraft.exists()) await tmpADraft.rename(bDraft.path);
    } catch (_) {
      if (await tmpA.exists()) {
        try {
          await tmpA.delete(recursive: true);
        } catch (_) {
          /* ignore */
        }
      }
      if (await tmpADraft.exists()) {
        try {
          await tmpADraft.delete(recursive: true);
        } catch (_) {
          /* ignore */
        }
      }
      rethrow;
    }
    // Reopen active canonical so the runtime view reflects the new
    // bundle bytes (the active channel id itself didn't move).
    final activeChannel = _meta.channels[_meta.activeChannel];
    if (activeChannel != null) {
      await canonical.open(p.join(projectPath, activeChannel.subdir));
    }
  }

  /// Recursive directory copy — used by [copyChannel]. Kept private
  /// to VibeProject so on-disk semantics live in one place.
  Future<void> _copyDir(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final entity in src.list(followLinks: false)) {
      final basename = p.basename(entity.path);
      final newPath = p.join(dest.path, basename);
      if (entity is Directory) {
        await _copyDir(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }

  /// Delete generated build artifacts. Pass [target] to clean a
  /// single variant directory (`<project>/build/<target>/`) or null
  /// to wipe the whole `build/` tree. Returns the list of paths
  /// that were deleted (empty when nothing existed). Idempotent —
  /// missing dirs are silently skipped. Source files
  /// (`bundles/`, `prefs.json`, etc.) are never touched.
  Future<List<String>> cleanBuild({String? target}) async {
    final deleted = <String>[];
    if (target == null) {
      final buildDir = Directory(p.join(projectPath, 'build'));
      if (await buildDir.exists()) {
        await buildDir.delete(recursive: true);
        deleted.add(buildDir.path);
      }
      return deleted;
    }
    // Constrain target to a single path segment so a malicious
    // arg like `../../etc` cannot escape the build folder.
    if (target.isEmpty || target.contains('/') || target.contains('\\')) {
      throw ArgumentError.value(
        target,
        'target',
        'target must be a single build sub-directory name',
      );
    }
    final dir = Directory(p.join(projectPath, 'build', target));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      deleted.add(dir.path);
    }
    return deleted;
  }

  /// Hard-remove: disable the channel **and** delete its on-disk
  /// bundle directory (`<projectPath>/<subdir>`) plus the autosave
  /// draft mirror. Idempotent on disk side — already-missing dirs are
  /// skipped. The same "cannot purge the only enabled channel" guard
  /// applies as for [removeChannel] (the disable step throws first).
  Future<void> purgeChannel(String id) async {
    final ch = _meta.channels[id];
    if (ch == null) {
      throw StateError('unknown channel: $id');
    }
    // Capture the subdir before disable mutates meta — disable does
    // not change `subdir`, but reading once keeps the delete path
    // stable even if a future change reshapes the registry.
    final subdir = ch.subdir;
    if (ch.enabled) {
      await removeChannel(id);
    }
    final dir = Directory(p.join(projectPath, subdir));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    final draft = Directory(p.join(projectPath, '$subdir.draft'));
    if (await draft.exists()) {
      await draft.delete(recursive: true);
    }
  }

  /// Disable a channel slot without deleting its on-disk data. Active
  /// channel cannot be removed unless another enabled channel exists
  /// to take its place.
  Future<void> removeChannel(String id) async {
    final ch = _meta.channels[id];
    if (ch == null || !ch.enabled) return;
    // Capture *before* mutating meta — once we copyWith below, we lose
    // the ability to tell whether the disabled channel was the one
    // backing the live canonical. Without this, the canonical keeps
    // pointing at the disabled (or, after purge, deleted) directory
    // and the preview goes blank.
    final wasActive = _meta.activeChannel == id;
    final updated = ChannelDef(subdir: ch.subdir, enabled: false);
    final newChannels = <String, ChannelDef>{
      for (final e in _meta.channels.entries)
        e.key: e.key == id ? updated : e.value,
    };
    String newActive = _meta.activeChannel;
    if (wasActive) {
      String? replacementId;
      for (final e in newChannels.entries) {
        if (e.key == '__legacy__') continue;
        if (e.value.enabled) {
          replacementId = e.key;
          break;
        }
      }
      if (replacementId == null) {
        throw StateError('cannot remove the only enabled channel');
      }
      newActive = replacementId;
    }
    _meta = _meta.copyWith(channels: newChannels, activeChannel: newActive);
    await _writeMeta();
    if (wasActive) {
      // Re-bind the live canonical to the surviving channel — same
      // semantics as `activateChannel` (preserves subscriptions, just
      // points at a new bundle dir). Without this the runtime keeps
      // serving the disabled channel until the next manual activate.
      final replacement = newChannels[newActive]!;
      await canonical.open(p.join(projectPath, replacement.subdir));
    }
  }

  /// Release the canonical-changes subscription. Call before discarding
  /// the project (e.g. when the shell swaps to a freshly-opened one) so
  /// the old project does not keep appending to its own history file.
  Future<void> dispose() async {
    await _historySub?.cancel();
    await _undoSub?.cancel();
    _historySub = null;
    _undoSub = null;
  }

  /// Persist the in-memory [prefs] to `<projectPath>/prefs.json`.
  /// Failures are surfaced — the host decides how loud to be.
  Future<void> savePrefs() => prefs.save(projectPath);

  /// Persist project.json + commit canonical to disk.
  Future<void> save() async {
    _meta = _meta.copyWith(lastOpenedAt: DateTime.now().toUtc());
    await _writeMeta();
    await canonical.save();
  }

  /// Update the displayed project name. Writes the change to
  /// `project.apbproj` immediately. The folder on disk is **not**
  /// renamed — the folder name is independent of the project name.
  Future<void> rename(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == _meta.name) return;
    _meta = _meta.copyWith(name: trimmed, lastOpenedAt: DateTime.now().toUtc());
    await _writeMeta();
  }

  /// Adopt [newProjectPath] as the project root. Writes a fresh
  /// project.apbproj there, copies the bundle via canonical.saveAs,
  /// copies sidecar prefs / chat log over, and returns a new
  /// [VibeProject] rebound to the new path. Callers must use the
  /// returned instance. The displayed [name] is preserved (and only
  /// falls back to the new folder basename when the previous name was
  /// empty).
  Future<VibeProject> saveAs(String newProjectPath) async {
    await Directory(newProjectPath).create(recursive: true);
    final activeCh = _meta.channels[_meta.activeChannel]!;
    // The canonical's saveAs commits the *active* channel's bundle.
    // Other enabled channels are byte-copied below so the cloned
    // project keeps every channel intact.
    await canonical.saveAs(p.join(newProjectPath, activeCh.subdir));
    for (final entry in _meta.channels.entries) {
      if (entry.key == _meta.activeChannel) continue;
      if (!entry.value.enabled) continue;
      final src = Directory(p.join(projectPath, entry.value.subdir));
      if (!await src.exists()) continue;
      await _copyDirectory(
        src,
        Directory(p.join(newProjectPath, entry.value.subdir)),
      );
    }
    final preservedName =
        _meta.name.trim().isNotEmpty ? _meta.name : _nameOf(newProjectPath);
    final updated = _meta.copyWith(
      name: preservedName,
      lastOpenedAt: DateTime.now().toUtc(),
    );
    await _writeMetaTo(File(p.join(newProjectPath, projectFile)), updated);
    // Carry sidecar state across — prefs reflect the user's current
    // session, chat + history are project-scope continuity.
    await prefs.save(newProjectPath);
    final oldChat = File(p.join(projectPath, VibeChatLog.fileName));
    if (await oldChat.exists()) {
      await oldChat.copy(p.join(newProjectPath, VibeChatLog.fileName));
    }
    final oldHistory = File(p.join(projectPath, VibeHistoryLog.fileName));
    if (await oldHistory.exists()) {
      await oldHistory.copy(p.join(newProjectPath, VibeHistoryLog.fileName));
    }
    final oldUndo = File(p.join(projectPath, VibeUndoSidecar.fileName));
    if (await oldUndo.exists()) {
      await oldUndo.copy(p.join(newProjectPath, VibeUndoSidecar.fileName));
    }
    // Hand the canonical-change subscription off to the new project so
    // future patches log against the new path.
    await dispose();
    return VibeProject(
      projectPath: newProjectPath,
      canonical: canonical,
      meta: updated,
      prefs: prefs,
      chatLog: VibeChatLog.open(newProjectPath),
      historyLog: VibeHistoryLog.open(newProjectPath),
      undoSidecar: VibeUndoSidecar.open(newProjectPath),
    );
  }

  /// Discard the bundle's in-memory edits. Project.json is unaffected.
  Future<void> revert() => canonical.revert();

  /// Replace a channel's bundle with the contents of an external `.mbd`
  /// directory. Defaults to the active channel; pass [targetChannel] to
  /// import into a different slot (auto-creates the slot when it was
  /// disabled). The active canonical re-opens only if the import lands
  /// on the active channel.
  Future<void> importBundle(
    String sourceMbdPath, {
    String? targetChannel,
  }) async {
    final src = Directory(sourceMbdPath);
    if (!await src.exists()) {
      throw FileSystemException('Bundle not found', sourceMbdPath);
    }
    final id = targetChannel ?? _meta.activeChannel;
    final ch = _meta.channels[id];
    if (ch == null) throw StateError('unknown channel: $id');
    final destPath = p.join(projectPath, ch.subdir);
    final destDir = Directory(destPath);
    if (await destDir.exists()) {
      await destDir.delete(recursive: true);
    }
    await _copyDirectory(src, destDir);
    // Materialise the slot if it was disabled — import implies
    // intent to use this channel.
    if (!ch.enabled) {
      _meta = _meta.copyWith(
        channels: <String, ChannelDef>{
          for (final e in _meta.channels.entries)
            e.key:
                e.key == id
                    ? ChannelDef(subdir: ch.subdir, enabled: true)
                    : e.value,
        },
      );
      await _writeMeta();
    }
    if (id == _meta.activeChannel) {
      await canonical.open(destPath);
    }
  }

  /// Copy a channel's bundle to an external directory. Defaults to the
  /// active channel. The active bundle is committed to disk first so
  /// the export reflects the user's latest edits.
  Future<void> exportBundle(String destPath, {String? sourceChannel}) async {
    final id = sourceChannel ?? _meta.activeChannel;
    final ch = _meta.channels[id];
    if (ch == null) throw StateError('unknown channel: $id');
    if (id == _meta.activeChannel && canonical.isDirty) {
      await canonical.save();
    }
    final srcPath = p.join(projectPath, ch.subdir);
    final src = Directory(srcPath);
    if (!await src.exists()) {
      throw FileSystemException('Bundle missing in project', srcPath);
    }
    final dest = Directory(destPath);
    if (await dest.exists()) {
      await dest.delete(recursive: true);
    }
    await _copyDirectory(src, dest);
  }

  Future<void> _writeMeta() async {
    await _writeMetaTo(File(p.join(projectPath, projectFile)), _meta);
  }

  /// Preserve a corrupt-on-disk metadata file before a defaults reset
  /// overwrites it. Copies to `<path>.corrupt-<epochMs>` so the user can
  /// recover instead of silently losing the project (data-loss class —
  /// the chat.jsonl incident's lesson applied to project metadata).
  /// Best-effort: a failed backup must never block opening the project.
  static Future<void> _backupCorruptFile(File source) async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final backup = '${source.path}.corrupt-$stamp';
      await source.copy(backup);
    } catch (_) {
      /* backup best-effort — never block open */
    }
  }

  static Future<void> _writeMetaTo(File target, ProjectMeta meta) async {
    await target.parent.create(recursive: true);
    final newContent = _encodeMeta(meta);
    // Short-circuit when on-disk content already matches what we
    // would write. openAt runs this every reopen even when nothing
    // migrated, and on macOS builds where the workspace folder
    // hasn't been granted file access (Recent Projects path
    // bypasses the NSOpenPanel powerbox consent that "Open
    // Project" picks up), the rename below fails with EPERM and
    // aborts the open. Identical content means there's nothing
    // worth persisting — return early.
    if (await target.exists()) {
      try {
        final existing = await target.readAsString();
        if (existing == newContent) return;
      } catch (_) {
        /* fall through to rewrite */
      }
    }
    final tmp = File('${target.path}.tmp');
    try {
      await tmp.writeAsString(newContent);
      try {
        await tmp.rename(target.path);
      } on FileSystemException {
        // Rename can fail under macOS App Management
        // (com.apple.macl xattr mismatch) or when the folder hasn't
        // received TCC consent for the current build. Try delete +
        // rename, then drop the stray tmp if even that is denied.
        if (await target.exists()) {
          try {
            await target.delete();
            await tmp.rename(target.path);
          } on FileSystemException {
            try {
              await tmp.delete();
            } catch (_) {}
            // Best effort — leave the existing meta on disk
            // untouched. In-memory meta still drives the session;
            // openAt does not bump lastOpenedAt so a missed write
            // here only matters when an actual migration happened.
          }
        }
      }
    } on FileSystemException {
      // tmp write itself denied — workspace folder is read-only to
      // this build. Skip silently; the session proceeds on the
      // unchanged on-disk meta.
    }
  }

  static String _encodeMeta(ProjectMeta m) =>
      const JsonEncoder.withIndent('  ').convert(m.toJson());

  /// Default display name when `project.apbproj` lacks a `name` field.
  /// Strips a legacy `.apbproj` suffix so previously-bundled folders
  /// surface a clean name.
  static String _nameOf(String projectDir) {
    final base = p.basename(projectDir);
    const ext = '.apbproj';
    if (base.toLowerCase().endsWith(ext)) {
      return base.substring(0, base.length - ext.length);
    }
    return base;
  }

  static Future<void> _copyDirectory(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final entity in src.list(followLinks: false)) {
      final basename = p.basename(entity.path);
      final newPath = p.join(dest.path, basename);
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(newPath));
      } else if (entity is File) {
        await entity.copy(newPath);
      }
    }
  }
}

/// One UI bundle channel — `serving` (UI fetched by external clients
/// over MCP) or `native` (UI rendered locally by the same app). A
/// project can have either, both, or neither — each channel is
/// independently enabled and points at its own `.mbd` directory.
class ChannelDef {
  ChannelDef({required this.subdir, this.enabled = true});

  /// Path of the bundle directory relative to the project root.
  /// Example: `'bundles/serving.mbd'`.
  String subdir;

  /// When false, the channel slot is reserved (subdir noted) but no
  /// bundle is materialised on disk. The selector still shows the slot
  /// as a `+ create` placeholder.
  bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'subdir': subdir,
    'enabled': enabled,
  };

  factory ChannelDef.fromJson(Map<String, dynamic> json) => ChannelDef(
    subdir: (json['subdir'] as String?) ?? 'bundles/unknown.mbd',
    enabled: (json['enabled'] as bool?) ?? true,
  );
}

/// Serialised content of `project.apbproj`. Only project-scoped values
/// — per-bundle metadata stays in `<bundle>/manifest.json`.
/// Authoring intent of a project — drives which workspace panel the
/// shell mounts (pure DSL preview vs vbu+dsl studio runtime).
enum ProjectKind {
  /// Regular end-user app built on the AppPlayer DSL only. The editor
  /// preview mounts `PreviewMcpUi` (pure `flutter_mcp_ui_runtime`).
  appPlayerApp,

  /// Studio domain package (`vibe_studio` extension bundle). The editor
  /// preview mounts `DslWorkspaceView` so vbu_* atoms and domain widgets
  /// render through the namespaced `vibe_studio_runtime` fork.
  studioPackage,
}

/// App Builder's project kinds, declared for the platform's standard
/// new-project dialog (via `BuiltInAppContext.projectKindsProvider` and
/// passed to the host's `promptForNewProject`). The host owns the dialog;
/// App Builder only owns this list — mirrors a future
/// `manifest.projectKinds[]` so a bundle, not code, declares the kinds.
const List<ProjectKindOption> appBuilderProjectKinds = <ProjectKindOption>[
  ProjectKindOption(
    id: 'appPlayerApp',
    label: 'AppPlayer App',
    description: 'Regular end-user app (pure mcp_ui_dsl).',
  ),
  ProjectKindOption(
    id: 'studioPackage',
    label: 'Studio Package',
    description: 'Studio domain bundle (vbu_* atoms + dsl).',
  ),
];

/// Maps a [ProjectKindOption.id] from the new-project dialog back to the
/// typed [ProjectKind]. Null / unknown ids → [ProjectKind.appPlayerApp].
ProjectKind projectKindFromId(String? id) =>
    id == null ? ProjectKind.appPlayerApp : ProjectKind.values.byName(id);

class ProjectMeta {
  ProjectMeta({
    required this.name,
    required this.createdAt,
    required this.lastOpenedAt,
    Map<String, ChannelDef>? channels,
    this.activeChannel = 'serving',
    this.schemaVersion = 2,
    this.kind = ProjectKind.appPlayerApp,
  }) : channels =
           channels ??
           <String, ChannelDef>{
             'serving': ChannelDef(subdir: 'bundles/serving.mbd'),
             'native': ChannelDef(subdir: 'bundles/native.mbd', enabled: false),
           };

  final String name;
  final DateTime createdAt;
  final DateTime lastOpenedAt;

  /// Two-slot map keyed by channel id (`serving` / `native`). One slot
  /// is always present in the map — `enabled: false` means the slot is
  /// declared but not materialised.
  final Map<String, ChannelDef> channels;

  /// Id of the channel the editor reopens to. Must point at an
  /// `enabled: true` entry of [channels]; the project ctor falls back
  /// to the first enabled one when this id is stale.
  String activeChannel;

  final int schemaVersion;

  /// Authoring intent. Missing in pre-kind project files → defaults to
  /// [ProjectKind.appPlayerApp] for backwards compatibility.
  ProjectKind kind;

  factory ProjectMeta.defaults({
    required String name,
    ProjectKind kind = ProjectKind.appPlayerApp,
  }) {
    final now = DateTime.now().toUtc();
    // Channel layout differs by kind. AppPlayer App keeps the two-slot
    // serving/native model. Studio Package is a single-slot bundle
    // whose directory name is the package id (= project name) so the
    // on-disk artefact is portable as `<id>.mbd` rather than the host's
    // serving-channel placeholder.
    final Map<String, ChannelDef> channels =
        kind == ProjectKind.studioPackage
            ? <String, ChannelDef>{
              'serving': ChannelDef(subdir: 'bundles/$name.mbd'),
            }
            : <String, ChannelDef>{
              'serving': ChannelDef(subdir: 'bundles/serving.mbd'),
              'native': ChannelDef(
                subdir: 'bundles/native.mbd',
                enabled: false,
              ),
            };
    return ProjectMeta(
      name: name,
      createdAt: now,
      lastOpenedAt: now,
      channels: channels,
      kind: kind,
    );
  }

  ProjectMeta copyWith({
    String? name,
    DateTime? lastOpenedAt,
    Map<String, ChannelDef>? channels,
    String? activeChannel,
    ProjectKind? kind,
  }) => ProjectMeta(
    name: name ?? this.name,
    createdAt: createdAt,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    channels: channels ?? this.channels,
    activeChannel: activeChannel ?? this.activeChannel,
    schemaVersion: schemaVersion,
    kind: kind ?? this.kind,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schemaVersion': schemaVersion,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'lastOpenedAt': lastOpenedAt.toIso8601String(),
    'channels': <String, dynamic>{
      for (final e in channels.entries) e.key: e.value.toJson(),
    },
    'activeChannel': activeChannel,
    'kind': kind.name,
  };

  /// Parse a `project.apbproj` payload, transparently migrating the
  /// pre-channel v1 layout (`bundleSubdir: 'app.mbd'`) to the current
  /// channel-based shape. The on-disk directory move is handled
  /// separately by [VibeProject._migrateLegacyBundle].
  factory ProjectMeta.fromJson(Map<String, dynamic> json) {
    DateTime parse(String? s) {
      if (s == null) return DateTime.now().toUtc();
      try {
        return DateTime.parse(s).toUtc();
      } catch (_) {
        return DateTime.now().toUtc();
      }
    }

    ProjectKind kind = ProjectKind.appPlayerApp;
    final kindName = json['kind'];
    if (kindName is String) {
      for (final k in ProjectKind.values) {
        if (k.name == kindName) {
          kind = k;
          break;
        }
      }
    }
    final rawName = (json['name'] as String?) ?? 'Untitled';
    final raw = json['channels'];
    Map<String, ChannelDef>? channels;
    if (raw is Map) {
      channels = <String, ChannelDef>{};
      for (final entry in raw.entries) {
        if (entry.value is Map) {
          channels[entry.key.toString()] = ChannelDef.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        }
      }
      // AppPlayer App keeps the two-slot serving/native invariant.
      // Studio Package is single-slot (one bundle named after the
      // project id) so we do not force a `native` peer back in.
      if (kind != ProjectKind.studioPackage) {
        if (!channels.containsKey('native')) {
          channels['native'] = ChannelDef(
            subdir: 'bundles/native.mbd',
            enabled: false,
          );
        }
        if (!channels.containsKey('serving')) {
          channels['serving'] = ChannelDef(subdir: 'bundles/serving.mbd');
        }
      } else if (channels.isEmpty) {
        // Defensive — should never happen for a kind=studioPackage
        // project but fall back to a name-derived single slot rather
        // than crashing the canonical open.
        channels['serving'] = ChannelDef(subdir: 'bundles/$rawName.mbd');
      }
    } else {
      // v1 → v2 migration. Old projects had a single `bundleSubdir`
      // (default `app.mbd`). Treat that as the serving channel and
      // leave native disabled. The on-disk bundle is moved to
      // `bundles/serving.mbd` separately.
      final legacySubdir = (json['bundleSubdir'] as String?) ?? 'app.mbd';
      channels = <String, ChannelDef>{
        'serving': ChannelDef(subdir: 'bundles/serving.mbd'),
        'native': ChannelDef(subdir: 'bundles/native.mbd', enabled: false),
      };
      // Stash the legacy subdir so the migration helper can find it.
      // The map is consumed once and rewritten to the new layout.
      channels['__legacy__'] = ChannelDef(subdir: legacySubdir, enabled: true);
    }
    final active = (json['activeChannel'] as String?) ?? 'serving';
    return ProjectMeta(
      name: rawName,
      createdAt: parse(json['createdAt'] as String?),
      lastOpenedAt: parse(json['lastOpenedAt'] as String?),
      channels: channels,
      activeChannel: active,
      schemaVersion: (json['schemaVersion'] as int?) ?? 2,
      kind: kind,
    );
  }
}
