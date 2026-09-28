/// The runtime's author-facing diagnostics must reach the studio's log.
///
/// `MCPLogger` only speaks to a host that installs `onRecord`; everything else
/// it says goes to `dart:developer`, which an author never reads. The studio
/// installed nothing, so a document fault the runtime reported out loud — a
/// widget placed under a key its type does not declare, and therefore dropped —
/// arrived nowhere. That silence cost a day of chasing the runtime, the recipe
/// and the capability wiring for a `lottieAnimation` written under
/// `box.content` when the slot is `child`.
@TestOn('vm')
library;

import 'package:appplayer_studio/runtime.dart' as studio_rt;
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart' as pkg_rt;
import 'package:appplayer_studio/src/base/main/runtime_log_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart' as logging;

void main() {
  late List<logging.LogRecord> seen;
  late logging.Level previousLevel;

  setUp(() {
    resetRuntimeLogBridgeForTest();
    seen = <logging.LogRecord>[];
    previousLevel = logging.Logger.root.level;
    logging.Logger.root.level = logging.Level.ALL;
    logging.Logger.root.onRecord.listen(seen.add);
  });

  tearDown(() {
    resetRuntimeLogBridgeForTest();
    logging.Logger.root.level = previousLevel;
  });

  test('nothing is installed until the bridge is', () {
    expect(studio_rt.MCPLogger.onRecord, isNull,
        reason: 'the studio used to ship in exactly this state');
    expect(pkg_rt.MCPLogger.onRecord, isNull);
  });

  test('the package runtime (App Builder preview) reaches the log too',
      () async {
    // The preview renders with `package:flutter_mcp_ui_runtime`, a separate
    // copy with its own static sink. A bridge on the fork alone left the main
    // authoring surface silent: an unknown widget drew its error card and
    // logged nothing.
    installRuntimeLogBridge();
    pkg_rt.MCPLogger('Renderer').error('Unknown widget type: qaNoSuchWidget');
    await Future<void>.delayed(Duration.zero);

    expect(seen, hasLength(1), reason: 'the preview runtime went nowhere');
    expect(seen.single.level, logging.Level.SEVERE);
    expect(seen.single.message, contains('[Renderer]'));
    expect(seen.single.message, contains('qaNoSuchWidget'));
  });

  test('a runtime message reaches the studio log', () async {
    installRuntimeLogBridge();
    studio_rt.MCPLogger('widget_registry').warning(
      '`box` declares no `content`, and the widget placed there was dropped.',
    );
    await Future<void>.delayed(Duration.zero);

    expect(seen, isNotEmpty, reason: 'the record went nowhere');
    expect(seen.single.message, contains('was dropped'));
    expect(seen.single.message, contains('widget_registry'),
        reason: 'the channel has to survive, or the reader cannot tell '
            'which part of the runtime spoke');
  });

  test('levels map so a warning is not filtered out', () async {
    // The debug surface drops low-level records. A dropped-widget warning
    // arriving as FINE would be filtered exactly where it matters.
    installRuntimeLogBridge();
    studio_rt.MCPLogger('x').warning('w');
    studio_rt.MCPLogger('x').error('e');
    studio_rt.MCPLogger('x').info('i');
    await Future<void>.delayed(Duration.zero);

    expect(seen.map((r) => r.level).toList(), <logging.Level>[
      logging.Level.WARNING,
      logging.Level.SEVERE,
      logging.Level.INFO,
    ]);
  });

  test('installing twice does not replace the first sink', () {
    installRuntimeLogBridge();
    final first = studio_rt.MCPLogger.onRecord;
    installRuntimeLogBridge();
    expect(identical(studio_rt.MCPLogger.onRecord, first), isTrue,
        reason: 'the sink is a single static slot — a second install would '
            'silently take over, and the last writer would win');
  });
}
