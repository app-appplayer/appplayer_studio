import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appplayer_studio/base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

ApprovalRequest _req({Duration deadline = const Duration(seconds: 5)}) =>
    ApprovalRequest(
      kind: 'execute',
      summary: 'io.connect_device serial',
      origin: 'hub:caller',
      risk: 'opens a local port',
      deadline: deadline,
    );

void main() {
  late Directory tmp;
  late String logPath;
  final at = DateTime.utc(2026, 10, 25, 6);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('approval_');
    logPath = p.join(tmp.path, 'approvals.jsonl');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  HostApprover approver(ApprovalAsker? ask) => HostApprover(
    ask: ask,
    approver: 'local-user',
    log: ApprovalLog(logPath),
    now: () => at,
  );

  List<Map<String, dynamic>> logged() =>
      File(logPath)
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, dynamic>)
          .toList();

  test('a yes from the person is an approval with approver and time', () async {
    final r = await approver((_) async => true).request(_req());
    expect(r.approved, isTrue);
    expect(r.approver, 'local-user');
    expect(logged().single, containsPair('approved', true));
    expect(logged().single['at'], '2026-10-25T06:00:00.000Z');
  });

  test('a no is a denial and names nobody', () async {
    final r = await approver((_) async => false).request(_req());
    expect(r.approved, isFalse);
    expect(r.approver, '');
    expect(logged().single, containsPair('reason', 'denied'));
  });

  test('no screen to ask on is a denial', () async {
    final r = await approver(null).request(_req());
    expect(r.approved, isFalse);
    expect(r.reason, 'no_screen');
  });

  test('no answer by the deadline is a denial', () async {
    final r = await approver(
      (_) => Future<bool?>.delayed(const Duration(seconds: 3), () => true),
    ).request(_req(deadline: const Duration(milliseconds: 50)));
    expect(r.approved, isFalse);
    expect(r.reason, 'timeout');
  });

  test('an asker that throws or answers null is a denial', () async {
    expect(
      (await approver((_) => throw StateError('x')).request(_req())).approved,
      isFalse,
    );
    expect((await approver((_) async => null).request(_req())).approved, isFalse);
  });

  test('an unwritable log does not turn a denial into an approval', () async {
    final r = await HostApprover(
      ask: (_) async => false,
      approver: 'local-user',
      log: ApprovalLog(p.join(tmp.path, 'approvals.jsonl', 'nested', 'x')),
    ).request(_req());
    expect(r.approved, isFalse);
  });

  test('confirmDestructive asks once per call and follows the answer', () async {
    final asked = <ApprovalRequest>[];
    final a = approver((r) async {
      asked.add(r);
      return true;
    });
    expect(await a.confirmDestructive('io.execute', {'x': 1}), isTrue);
    expect(asked.single.kind, 'destructive');
    expect(asked.single.origin, 'io.execute');
  });

  test('a request its asker withdraws is recorded as withdrawn, not denied',
      () async {
    final gone = Completer<void>();
    final a = HostApprover(
      ask: (r) => Completer<bool?>().future,
      approver: 'me',
    );
    final pending = a.request(
      ApprovalRequest(
        kind: 'execute',
        summary: 's',
        origin: 'o',
        withdrawn: gone.future,
      ),
    );
    gone.complete();
    final r = await pending;
    expect(r.approved, isFalse);
    expect(r.reason, 'withdrawn');
  });
}
