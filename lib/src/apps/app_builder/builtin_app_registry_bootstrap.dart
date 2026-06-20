import 'package:appplayer_studio/base.dart' show BuiltInAppRegistry;

import '../ops/ops_builtin.dart';
import '../scene_builder/scene_builder_builtin.dart';
import 'app_builder_builtin.dart';

/// Registers every built-in app this package ships so the host can
/// call a single function on boot instead of importing each app
/// implementation directly. Idempotent (the registry de-dupes by id),
/// so the host can call it after every hot-reload reset.
void registerBuiltInApps() {
  BuiltInAppRegistry.instance.register(AppBuilderBuiltInApp());
  BuiltInAppRegistry.instance.register(SceneBuilderBuiltInApp());
  BuiltInAppRegistry.instance.register(const OpsBuiltInApp());
}
