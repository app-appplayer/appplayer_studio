/// Host approval — asking the person at the machine before a sensitive action
/// runs. Judgement (whether an action is allowed at all) stays in the
/// capability packages; this only asks, and records the answer.
///
/// Fail-closed: no screen to ask on, no answer, or an answer after the
/// deadline is a denial.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What is being asked. [kind] is one of `destructive`, `execute`, `install`,
/// `reverse`, `gate`, `plugin` (registering a plugin) or `launch` (starting a
/// local process).
class ApprovalRequest {
  const ApprovalRequest({
    required this.kind,
    required this.summary,
    required this.origin,
    this.risk = '',
    this.deadline = const Duration(seconds: 60),
    this.withdrawn,
  });

  final String kind;
  final String summary;

  /// Who asked: a tool, a bundle, a server or a remote caller.
  final String origin;

  /// The risk in words, shown to the person.
  final String risk;

  /// How long the person is given.
  final Duration deadline;

  /// Completes when the asker no longer wants an answer (the request was
  /// cancelled); the question leaves the screen and the record says
  /// `withdrawn`.
  final Future<void>? withdrawn;
}

/// The answer plus who gave it and when — the evidence of an approval.
class ApprovalRecord {
  const ApprovalRecord({
    required this.request,
    required this.approved,
    required this.reason,
    required this.approver,
    required this.at,
  });

  final ApprovalRequest request;
  final bool approved;

  /// `approved`, `denied`, `timeout`, `withdrawn`, `no_screen` or `error`.
  final String reason;

  /// Empty when nobody answered.
  final String approver;
  final DateTime at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'at': at.toUtc().toIso8601String(),
    'kind': request.kind,
    'origin': request.origin,
    'summary': request.summary,
    if (request.risk.isNotEmpty) 'risk': request.risk,
    'approved': approved,
    'reason': reason,
    if (approver.isNotEmpty) 'approver': approver,
  };
}

/// Shows [request] to the person. A null result or an exception is a denial;
/// a host with no screen passes no asker at all.
typedef ApprovalAsker = Future<bool?> Function(ApprovalRequest request);

/// Appends one JSON line per decision. Never rewritten or deleted here.
class ApprovalLog {
  ApprovalLog(this.path);

  final String path;

  void append(ApprovalRecord record) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${jsonEncode(record.toJson())}\n',
      mode: FileMode.append,
    );
  }
}

class HostApprover {
  HostApprover({
    required this.ask,
    required this.approver,
    this.log,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Null = there is nobody to ask: every request is denied.
  final ApprovalAsker? ask;

  /// Name written into the record of an approval.
  final String approver;

  final ApprovalLog? log;
  final DateTime Function() _now;

  Future<ApprovalRecord> request(ApprovalRequest request) async {
    final asker = ask;
    var approved = false;
    var reason = 'no_screen';
    if (asker != null) {
      try {
        final gone = request.withdrawn;
        final answer = await Future.any<Object?>(<Future<Object?>>[
          asker(request).timeout(request.deadline),
          if (gone != null) gone.then((_) => #withdrawn),
        ]);
        approved = answer == true;
        reason =
            answer == #withdrawn ? 'withdrawn' : (approved ? 'approved' : 'denied');
      } on TimeoutException {
        reason = 'timeout';
      } on Object {
        reason = 'error';
      }
    }
    final record = ApprovalRecord(
      request: request,
      approved: approved,
      reason: reason,
      approver: approved ? approver : '',
      at: _now(),
    );
    try {
      log?.append(record);
    } on Object {
      // A log that cannot be written must not turn a denial into an approval,
      // nor block the answer already given.
    }
    return record;
  }

  /// The `HostToolRegistry.confirmDestructive` shape: asked per destructive
  /// tool call.
  Future<bool> confirmDestructive(
    String tool,
    Map<String, dynamic> args,
  ) async {
    final record = await request(
      ApprovalRequest(
        kind: 'destructive',
        summary: '$tool ${jsonEncode(args)}',
        origin: tool,
        risk: 'This action cannot be undone.',
      ),
    );
    return record.approved;
  }
}
