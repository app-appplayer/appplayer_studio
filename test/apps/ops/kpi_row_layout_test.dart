import 'package:appplayer_studio/src/apps/ops/ui/home/workspace_home_page.dart';
import 'package:flutter_test/flutter_test.dart';

// Verifies the Home KPI row degrades responsively (4-wide → 2 → 1) instead of
// squeezing tiles until their labels wrap character-by-character.
void main() {
  group('kpiColumnsFor (Home KPI Wrap breakpoints)', () {
    test('t1 wide → all 4 across', () {
      expect(kpiColumnsFor(1250), 4);
      expect(kpiColumnsFor(708), 4); // exact 4*168 + 3*12
    });

    test('t2 just under 4-wide → 3 columns', () {
      expect(kpiColumnsFor(707), 3);
      expect(kpiColumnsFor(540), 3); // 3*168 + 2*12 = 528
    });

    test('t3 narrow content (~470) → 2 columns', () {
      expect(kpiColumnsFor(470), 2);
      expect(kpiColumnsFor(348), 2); // 2*168 + 12
    });

    test('t4 very narrow → 1 column (never 0)', () {
      expect(kpiColumnsFor(340), 1);
      expect(kpiColumnsFor(168), 1);
      expect(kpiColumnsFor(50), 1);
      expect(kpiColumnsFor(0), 1);
      expect(kpiColumnsFor(-10), 1);
    });

    test('t5 clamps to tile count', () {
      expect(kpiColumnsFor(5000, tiles: 4), 4);
      expect(kpiColumnsFor(5000, tiles: 2), 2);
    });
  });
}
