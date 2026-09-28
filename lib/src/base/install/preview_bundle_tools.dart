/// Runs a project's bundle tools behind an authoring preview.
///
/// A document's `tool` action in the App Builder preview has to reach the
/// bundle's own tools, the way AppPlayer runs them — a preview that drops the
/// call shows a bundle with tools as if nothing happened (an `onInit` that
/// loads the page's data leaves every binding empty).
///
/// The bundle is activated through [HostBundleActivationContext] — the same
/// `kb` wiring, outbound client host and `requires.builtinAtoms` gate a tab
/// gets — on a **preview-only in-process server**, so its tools never join
/// the host's public tool list while a project is merely open.
///
/// [call] answers the way the runtime expects a tool response (UI DSL 1.4
/// §4.4, §3.10): the MCP wire shape `{content, isError}`, which the runtime
/// unwraps, auto-merges or binds, and routes to `onError` on `isError`. A
/// tool the bundle does not declare throws, as AppPlayer's dispatcher does —
/// a null answer would read as a successful call.
library;

import 'package:brain_kernel/brain_kernel.dart' as mk;

import '../main/chrome_bridge.dart';
import 'bundle_loading.dart';
import 'host_bundle_activation.dart';
import 'studio_kb.dart';

class PreviewBundleTools {
  PreviewBundleTools._({
    required this.bundlePath,
    required mk.InProcessKernelServerHost boot,
    required HostBundleActivationContext? context,
    required this.registered,
    required this.failed,
  }) : _boot = boot,
       _context = context;

  /// The bundle directory these tools come from.
  final String bundlePath;

  final mk.InProcessKernelServerHost _boot;
  final HostBundleActivationContext? _context;

  /// Bundle tool names (as documents call them) that registered.
  final Set<String> registered;

  /// Bundle tool names that did not register, with the reason.
  final Map<String, String> failed;

  bool _disposed = false;

  /// Activates the bundle at [bundlePath] for a preview. A directory that
  /// holds no readable bundle yields an instance whose every call throws with
  /// that reason.
  static Future<PreviewBundleTools> open({
    required String bundlePath,
    StudioKbWiring? kb,
    mk.KernelClientHost? Function()? clientHost,
    ChromeBridge? chromeBridge,
  }) async {
    final boot = mk.InProcessKernelServerHost();
    final bundle = readBundleAt(bundlePath);
    if (bundle == null) {
      return PreviewBundleTools._(
        bundlePath: bundlePath,
        boot: boot,
        context: null,
        registered: const <String>{},
        failed: const <String, String>{},
      );
    }
    final context = HostBundleActivationContext(
      boot: boot,
      tabKey: 'preview:$bundlePath',
      bundle: bundle,
      exposedShortId: bundle.shortId,
      kb: kb,
      clientHost: clientHost,
      chromeBridge: chromeBridge,
    );
    final registered = <String>{};
    final failed = <String, String>{};
    for (final tool in bundle.tools?.tools ?? const []) {
      final result = await context.registerTool(tool);
      if (!result.ok) {
        failed[tool.name] = result.error ?? 'registration failed';
      } else if (result.exposedName.isNotEmpty) {
        registered.add(tool.name);
      }
    }
    return PreviewBundleTools._(
      bundlePath: bundlePath,
      boot: boot,
      context: context,
      registered: registered,
      failed: failed,
    );
  }

  /// Runs the bundle tool [tool] with [params] and answers the MCP wire shape.
  Future<dynamic> call(String tool, Map<String, dynamic> params) async {
    if (_disposed) {
      throw StateError('the preview tools of $bundlePath are closed');
    }
    final context = _context;
    if (context == null) {
      throw StateError('no bundle could be read at $bundlePath');
    }
    if (!registered.contains(tool)) {
      final why = failed[tool];
      throw StateError(
        why == null
            ? 'no tool named "$tool" in ${context.bundle.manifest.id}'
            : 'tool "$tool" did not register: $why',
      );
    }
    final result = await _boot.callTool(
      '${context.exposedShortId}.$tool',
      params,
    );
    return <String, dynamic>{
      'content': <Map<String, dynamic>>[
        for (final c in result.content) _contentJson(c),
      ],
      'isError': result.isError ?? false,
    };
  }

  /// Tears the activation down: tools, js runtime and client-host
  /// connections of this bundle.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _context?.unregisterAll();
  }

  static Map<String, dynamic> _contentJson(
    mk.KernelContent content,
  ) => switch (content) {
    mk.KernelTextContent(:final text) => <String, dynamic>{
      'type': 'text',
      'text': text,
    },
    mk.KernelImageContent(:final data, :final mimeType) => <String, dynamic>{
      'type': 'image',
      'data': data,
      'mimeType': mimeType,
    },
  };
}
