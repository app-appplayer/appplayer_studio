import 'package:brain_kernel/brain_kernel.dart' show McpBundle;
import 'package:meta/meta.dart';

/// Verifies that a canonical bundle obeys the wiring and MCP-exposure
/// conventions before any converter (Dart / embedded / self-UI) emits code.
abstract interface class PatternEnforcer {
  List<PatternViolation> check(McpBundle canonical, ConvertTarget target);
}

/// Default implementation. vibe is a UI design tool — it only enforces UI
/// wiring conventions (action / binding shape) so the canonical bundle stays
/// portable. Skill / flow / device contracts belong to the runtime author,
/// not the designer, and are intentionally not checked here.
class PatternEnforcerImpl implements PatternEnforcer {
  const PatternEnforcerImpl();

  @override
  List<PatternViolation> check(McpBundle canonical, ConvertTarget target) {
    final violations = <PatternViolation>[];
    _checkWiring(canonical, violations);
    return violations;
  }

  void _checkWiring(McpBundle bundle, List<PatternViolation> out) {
    final ui = bundle.ui;
    if (ui == null) return;
    final json = ui.toJson();
    _walk(json, '', (path, value) {
      if (value is! Map) return;
      final action = value['action'];
      if (action is String &&
          action.isNotEmpty &&
          !action.startsWith('tools.')) {
        out.add(
          PatternViolation(
            code: 'WIRING_INVALID_ACTION',
            path: path,
            message: 'props.action must start with "tools." (got "$action")',
          ),
        );
      }
      final binding = value['binding'];
      if (binding is String &&
          binding.isNotEmpty &&
          !binding.startsWith('@state.')) {
        out.add(
          PatternViolation(
            code: 'WIRING_INVALID_BINDING',
            path: path,
            message: 'bindings must start with "@state." (got "$binding")',
          ),
        );
      }
    });
  }

  static void _walk(
    dynamic node,
    String path,
    void Function(String path, dynamic value) visit,
  ) {
    visit(path, node);
    if (node is Map) {
      node.forEach((k, v) => _walk(v, '$path/$k', visit));
    } else if (node is List) {
      for (var i = 0; i < node.length; i++) {
        _walk(node[i], '$path/$i', visit);
      }
    }
  }
}

@immutable
class ConvertTarget {
  const ConvertTarget({required this.family, this.subKind});
  final String family;
  final String? subKind;
}

@immutable
class PatternViolation {
  const PatternViolation({
    required this.code,
    required this.path,
    required this.message,
  });
  final String code;
  final String path;
  final String message;
}

class PatternException implements Exception {
  PatternException(this.violations);
  final List<PatternViolation> violations;
  @override
  String toString() => 'PatternException: ${violations.length} violation(s)';
}
