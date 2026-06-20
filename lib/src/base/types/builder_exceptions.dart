/// Domain-agnostic exception types every builder reuses for storage /
/// load / import / validation failures. Lifted from
/// `vibe_app_builder/core/types.dart` so a future builder (knowledge,
/// industrial HMI, OEM) can throw the same exception types without
/// re-defining its own flavour.
///
/// Naming kept generic — these are *bundle-level* errors, not vibe-only
/// concepts.
library;

import 'package:meta/meta.dart';
import 'package:brain_kernel/brain_kernel.dart' show ValidationIssue;

/// Disk I/O failure surfaced from the storage layer (FsPort write/read,
/// atomic-rename, draft mirror, …). Hosts surface it to the user as a
/// "couldn't read/write the project files" toast.
class DiskException implements Exception {
  DiskException(this.message);
  final String message;
  @override
  String toString() => 'DiskException: $message';
}

/// Bundle could not be loaded (missing manifest, malformed JSON, schema
/// rejection at load time). Distinct from [DiskException] because the
/// disk read itself succeeded — it's the bundle content that failed
/// validation.
class LoadException implements Exception {
  LoadException(this.message);
  final String message;
  @override
  String toString() => 'LoadException: $message';
}

/// Bundle could not be imported (kind mismatch with the source path,
/// `.mcpb` unpack failure, missing `manifest.json` after unpack, …).
class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => 'ImportException: $message';
}

/// Spec validator rejected the patch. [issues] carries every blocking
/// row so hosts can surface them in a lint dialog rather than a single
/// toast.
class ValidationException implements Exception {
  ValidationException(this.issues);
  final List<ValidationIssue> issues;
  @override
  String toString() => 'ValidationException: ${issues.length} issue(s)';
}

/// How an external bundle source is interpreted on import. `mbd` =
/// directory layout (`manifest.json` + reserved folders); `mcpb` =
/// archived form. Domains that don't ship archives can ignore the
/// `mcpb` variant — most builders accept both.
enum ImportKind { mbd, mcpb }

/// Result of a converter run — the on-disk artefact path + a hash of
/// the canonical that produced it + the list of files written.
@immutable
class ConvertResult {
  const ConvertResult({
    required this.outDir,
    required this.canonicalHash,
    required this.writtenFiles,
  });

  final String outDir;
  final String canonicalHash;
  final List<String> writtenFiles;
}
