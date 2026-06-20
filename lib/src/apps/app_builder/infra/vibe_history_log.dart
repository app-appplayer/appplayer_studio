// App Builder uses the platform's canonical edit-history log — the
// Studio lifecycle's `VibeHistoryLog` records every CanonicalChange to
// `<projectPath>/history.jsonl`. The fork is gone; this re-exports it.
export '../../../base/infra/history_log.dart';
