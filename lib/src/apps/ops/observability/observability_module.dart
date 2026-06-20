// Aggregate handle for the observability subsystem. One instance per
// process; bootstrapped in main.dart and exposed through Riverpod.
//
// PRD §FM-OBSERVE-01 / 02.

import 'activity_bus.dart';
import 'telemetry_store.dart';

class ObservabilityModule {
  ObservabilityModule({ActivityBus? bus, TelemetryStore? telemetry})
    : bus = bus ?? ActivityBus(),
      telemetry = telemetry ?? TelemetryStore() {
    this.telemetry.markBoot();
  }

  final ActivityBus bus;
  final TelemetryStore telemetry;

  Future<void> dispose() async {
    await bus.dispose();
    await telemetry.dispose();
  }
}
