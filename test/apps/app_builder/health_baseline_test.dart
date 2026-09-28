/// The "Health regressed" chat note compares a snapshot only with an earlier
/// snapshot of the same project. The baseline used to survive a project
/// switch, so opening a project with one issue after a clean project posted
/// "Health regressed: +1 blocking" on open.
library;

import 'package:appplayer_studio/src/apps/app_builder/feat/shell_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('same project keeps its baseline', () {
    expect(
      healthBaseline(baselineProject: '/w/a', baseline: 0, project: '/w/a'),
      0,
    );
  });

  test('another project starts quiet', () {
    expect(
      healthBaseline(baselineProject: '/w/a', baseline: 0, project: '/w/b'),
      isNull,
    );
  });

  test('no baseline yet stays quiet', () {
    expect(
      healthBaseline(baselineProject: null, baseline: null, project: '/w/a'),
      isNull,
    );
  });
}
