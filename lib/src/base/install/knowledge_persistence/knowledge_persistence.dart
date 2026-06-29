/// Disk-backed persistence wiring for the knowledge stack — reference recipe.
///
/// Resolves the "FactGraph is memory-only / accumulates globally" problem by
/// rooting each project's graph in its own folder:
///   - [PersistentStorageContainer] — the ten storages the `FactGraphRuntime`
///     consumes, each subclassing the exported `InMemory*Storage` base and
///     flushing write-through to `<rootDir>/<collection>.json`.
///   - [assemblePersistentFactGraph] / [assemblePersistentKnowledgeSystem] —
///     per-project assembly; isolation comes from distinct root dirs.
///   - [purgeProject] / [exportProject] / [importProject] — folder-as-unit
///     purge, backup and transfer.
///
/// Consumed identically by AppPlayer and Studio. `mcp_fact_graph` and
/// `mcp_knowledge` cores are not modified — persistence plugs in through the
/// public constructors and the exported storage stack.
library;

export 'src/collection_file.dart';
export 'src/persistent_storage.dart';
export 'src/persistent_runtime.dart';
