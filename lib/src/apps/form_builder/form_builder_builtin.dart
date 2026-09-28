import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:appplayer_studio/base.dart'
    show
        BuiltInApp,
        BuiltInLauncher,
        BuiltinToolRegistry,
        ChromeBridge,
        FormCapabilityBinding,
        StudioBackbone;
// Builtin = OS-level app · host wrapper API only. Zero direct
// `package:brain_kernel` / `mcp_host` / `mcp_server` imports; the engine
// (`mcp_form`) is reached exclusively through the host `form.*` capability.

import 'init/form_init.dart';
import 'tools/form_builder_tools.dart';
import 'ui/form_shell.dart';

/// Form Builder — template create/manage + LLM object insertion + document
/// issuing (immutable snapshots with provenance + supersedes corrections).
///
/// Storage = the bound project's FactGraph via the kernel (templates through
/// the rebound host `form.*` capability; drafts/issues through
/// `form_builder.*`). The app owns NO content data (rosters, ledgers…) —
/// that lives in the knowledge/execution system (Ops); this app is the
/// document-issuing instrument.
class FormBuilderBuiltInApp extends BuiltInApp {
  const FormBuilderBuiltInApp();

  @override
  String get id => 'form_builder';

  @override
  String get label => 'Form Builder';

  static const String _builtInMarker = '.builtin_form_builder';

  /// Live bound-project core, resolved at CALL TIME by tool handlers (the
  /// stale-init trap: handlers registered at host boot must reach the
  /// currently bound project, not the one captured at registration).
  static FormInit? _liveInit;
  static FormInit? get liveInit => _liveInit;

  static String? _bootedProject;
  static Future<FormInit>? _bootFuture;

  /// Boot (or rebind) the Form Builder core to [projectRoot]. Project-keyed:
  /// a different root disposes the previous init and re-points the host
  /// `form.*` template persistence at the new project's FactGraph.
  ///
  /// The capability rebind happens HERE, after the staleness check — never
  /// inside `FormInit.boot` — so a slower earlier boot that lost the race
  /// can neither become `liveInit` nor clobber the newer project's `form.*`
  /// binding (last bind wins deterministically).
  static Future<FormInit> ensureBoot(String projectRoot) async {
    if (_bootedProject == projectRoot && _bootFuture != null) {
      return _bootFuture!;
    }
    final previous = _liveInit;
    _liveInit = null;
    _bootedProject = projectRoot;
    // One future covers boot AND the `form.*` rebind, so every caller of the
    // same root (a second `ensureBoot`, the open/new slots) completes only
    // once templates persist to the project — a `form.save_template` issued
    // right after an open otherwise landed in the unbound in-memory port and
    // was lost.
    final future = () async {
      if (previous != null) await previous.dispose();
      final init = await FormInit.boot(projectRoot, p.basename(projectRoot));
      if (_bootedProject == projectRoot) {
        _liveInit = init;
        await FormCapabilityBinding.bindProject(
          facts: init.system.facts,
          workspaceId: init.projectId,
        );
      }
      return init;
    }();
    _bootFuture = future;
    return future;
  }

  /// Unbind the current project (tab close / project close): the host
  /// `form.*` falls back to its in-memory default.
  static Future<void> closeProject() async {
    final previous = _liveInit;
    _liveInit = null;
    _bootedProject = null;
    _bootFuture = null;
    FormCapabilityBinding.unbindProject();
    if (previous != null) await previous.dispose();
  }

  /// The project whose Form Builder core is currently booted, or null.
  static String? get bootedProject => _bootedProject;

  /// True when closing a tab bound to [tabProject] must tear the backend
  /// down. Form Builder is single-instance (`_openOrFocusSeed` focuses the
  /// one launchPath tab), so the closing tab owns whatever is booted:
  /// teardown iff a boot exists (`_bootedProject != null`) AND this tab
  /// didn't bind a DIFFERENT project — a project-less tab (`tabProject ==
  /// null`) still tears the sole boot down. `_bootedProject == null` (no
  /// boot, or the header button already closed it) → no teardown. Ops
  /// parity ([OpsBuiltInApp.shouldTeardownOnClose]) — kept identical so a
  /// future MCP-only boot path can't leak (form currently boots only
  /// through the shell's `_bindProject`, so the null-tab case is defensive).
  /// Guards `form_shell.dispose`; the keyed IndexedStack disposes only on
  /// tab removal, never on switch.
  static bool shouldTeardownOnClose(String? tabProject) =>
      _bootedProject != null &&
      (tabProject == null || tabProject == _bootedProject);

  /// Test seam — set/clear the booted-project marker without a full boot.
  @visibleForTesting
  static void debugSetBootedProject(String? project) {
    _bootedProject = project;
  }

  @override
  bool canHandle(String bundlePath) {
    final dir = Directory(bundlePath);
    if (!dir.existsSync()) return false;
    // Two recognised forms (Ops parity — the host may resolve either the
    // launcher marker dir or the seed mbd path):
    if (File(p.join(bundlePath, _builtInMarker)).existsSync()) return true;
    final manifest = File(p.join(bundlePath, 'manifest.json'));
    if (!manifest.existsSync()) return false;
    try {
      // Cheap substring check — avoids a JSON decode on every chrome
      // `matchFor` walk (same rationale as Ops).
      final body = manifest.readAsStringSync();
      return body.contains('"id": "com.makemind.form_builder"') ||
          body.contains('"id":"com.makemind.form_builder"');
    } catch (_) {
      return false;
    }
  }

  @override
  BuiltInLauncher launcher(ChromeBridge chromeBridge, String workspaceDir) {
    final defaultDir = p.join(workspaceDir, 'form_builder');
    final dir = Directory(defaultDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final marker = File(p.join(defaultDir, _builtInMarker));
    if (!marker.existsSync()) {
      marker.writeAsStringSync('');
    }
    return BuiltInLauncher(
      id: id,
      label: label,
      iconName: 'description',
      launchPath: defaultDir,
      onLaunch: () async {
        /* marker already exists from `launcher()` */
      },
    );
  }

  @override
  Future<void> registerHostTools(
    BuiltinToolRegistry server,
    ChromeBridge chromeBridge, {
    StudioBackbone? backbone,
  }) async {
    FormBuilderTools(
      liveInit: () => _liveInit,
      server: server,
    ).registerOn(server);
  }

  @override
  Widget mount({
    required BuildContext context,
    required String bundlePath,
    required ChromeBridge chromeBridge,
    required dynamic Function(String tabKey) chatLookup,
    required String tabKey,
    required BuiltinToolRegistry server,
    required StudioBackbone backbone,
    Map<String, Object?> inheritedSettings = const <String, Object?>{},
    String overridesFile = '',
  }) {
    return FormShell(
      key: ValueKey('form_builder::$bundlePath'),
      app: this,
      bundlePath: bundlePath,
      chromeBridge: chromeBridge,
      server: server,
      backbone: backbone,
      inheritedSettings: inheritedSettings,
      overridesFile: overridesFile,
    );
  }
}
