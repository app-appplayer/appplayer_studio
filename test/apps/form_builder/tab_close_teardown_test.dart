/// Form Builder tab-close teardown gate
/// (`FormBuilderBuiltInApp.shouldTeardownOnClose`).
///
/// Design contract (knowledge-operations.md §11.3): a tab CLOSE tears the
/// backend down; a tab SWITCH keeps it running in the background. The Form
/// shell disposes only on tab close (the host renders bodies in a keyed
/// IndexedStack), so `dispose()` calling `closeProject()` is the close
/// path. The gate here guards WHICH close triggers teardown: only the tab
/// that owns the live boot — never a stale sibling, a project-less tab, or
/// a project already closed via the header button. Ops parity
/// (`test/apps/ops/tab_close_teardown_test.dart`).
library;

import 'package:appplayer_studio/src/apps/form_builder/form_builder_builtin.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    // Leave the process-wide marker clean between cases.
    FormBuilderBuiltInApp.debugSetBootedProject(null);
  });

  test('owning / project-less tabs tear down; divergent does not', () {
    FormBuilderBuiltInApp.debugSetBootedProject('/projects/alpha');

    // The tab bound to the booted project → teardown.
    expect(
      FormBuilderBuiltInApp.shouldTeardownOnClose('/projects/alpha'),
      isTrue,
    );
    // A project-less tab with a live boot → the sole tab owns the sole
    // boot → teardown (Ops parity; defensive against a future MCP-only
    // boot path).
    expect(FormBuilderBuiltInApp.shouldTeardownOnClose(null), isTrue);
    // The tab bound a DIFFERENT project than what's booted → leave it alone.
    expect(
      FormBuilderBuiltInApp.shouldTeardownOnClose('/projects/beta'),
      isFalse,
    );
  });

  test('no live boot → no teardown for any tab', () {
    FormBuilderBuiltInApp.debugSetBootedProject(null);
    expect(
      FormBuilderBuiltInApp.shouldTeardownOnClose('/projects/alpha'),
      isFalse,
    );
    expect(FormBuilderBuiltInApp.shouldTeardownOnClose(null), isFalse);
  });

  test('closeProject clears ownership → close no longer tears down', () async {
    FormBuilderBuiltInApp.debugSetBootedProject('/projects/alpha');
    expect(
      FormBuilderBuiltInApp.shouldTeardownOnClose('/projects/alpha'),
      isTrue,
    );
    // Header-button project close already ran teardown → marker cleared.
    await FormBuilderBuiltInApp.closeProject();
    // A subsequent tab close must not double-dispose.
    expect(
      FormBuilderBuiltInApp.shouldTeardownOnClose('/projects/alpha'),
      isFalse,
    );
  });
}
