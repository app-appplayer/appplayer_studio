/// Mutable list of active [OverlaySpec]s. The `OverlayLayer` widget
/// listens to this controller; MCP push handlers mutate it.
library;

import 'package:flutter/foundation.dart';

import 'overlay_models.dart';

class OverlayController extends ValueNotifier<List<OverlaySpec>> {
  OverlayController() : super(const <OverlaySpec>[]);

  int _seq = 0;

  /// Add a new overlay, generating a unique id. Returns the assigned id.
  String push(OverlaySpec Function(String id) build) {
    final id = 'ov_${++_seq}';
    final spec = build(id);
    value = <OverlaySpec>[...value, spec];
    return id;
  }

  /// Remove an overlay by id. Returns true when an entry was removed.
  bool remove(String id) {
    final next = value.where((s) => s.id != id).toList(growable: false);
    if (next.length == value.length) return false;
    value = next;
    return true;
  }

  void clear() {
    if (value.isNotEmpty) value = const <OverlaySpec>[];
  }

  List<Map<String, dynamic>> snapshotJson() =>
      value.map((s) => s.toJson()).toList(growable: false);
}
