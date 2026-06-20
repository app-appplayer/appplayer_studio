import 'dart:io';

/// Atomically writes [content] to [file].
///
/// Writes to a sibling `.tmp` file with flush, then renames it over the target
/// so a crash mid-write cannot leave a truncated file behind. The parent
/// directory is created if missing. Mirrors the durable write path already used
/// by OpsConfig and KvStoragePortAdapter, applied here to per-item registry writes.
Future<void> writeStringAtomic(File file, String content) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(content, flush: true);
  await tmp.rename(file.path);
}
