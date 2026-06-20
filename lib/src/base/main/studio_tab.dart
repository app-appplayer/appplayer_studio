/// Tab data class for the Studio workspace — moved from host to base in
/// Phase 4a so multiple studios share the same tab model.
library;

import '../install/host_bundle_activation.dart';

/// One open tab in the universal-host strip. `path` null = the home
/// tab (always at index 0, not closable). Other tabs each represent a
/// package the user opened from Home; `currentProject` tracks the
/// package's currently-open project directory (null = no project, the
/// State B welcome surface).
class StudioTab {
  StudioTab.home()
    : path = null,
      name = 'Home',
      currentProject = null,
      activation = null;
  StudioTab.pkg(this.path, this.name, {this.currentProject})
    : activation = null;

  // path + name are mutable so the Studio Builder tab can "adopt" a
  // draft (swap its working path / displayed name) without spawning a
  // separate tab. Home tab keeps path=null forever via isHome.
  String? path;
  String name;
  String? currentProject;

  /// Activation context bound to this tab. Null on the home tab and
  /// on package tabs whose activation hasn't run yet (or has been
  /// torn down). Set when the host wires the bundle's manifest into
  /// the MCP server / agent stack on tab open.
  HostBundleActivationContext? activation;

  /// Bumped by the host to force a re-mount of this tab's
  /// DslWorkspaceView. Combined into the widget key so a bump
  /// triggers a full lifecycle (dispose + initState) and the workspace
  /// re-reads the bundle from disk.
  int reloadCounter = 0;

  /// Agent id this tab's chat thread routes to. Empty at construction —
  /// the host resolves the per-tab manager (Home seed / built-in seed /
  /// activated bundle) via `defaultChatAgentResolver` and writes here.
  String chatAgentId = '';

  /// Editor mode within the bundle workspace — bundle-driven. Possible
  /// values map to the seed UI's VbuRouter cases (`ui` / `tools` /
  /// `knowledge` / `manifest`). Bundles that aren't authoring tools
  /// ignore this; the host stores it so persistence survives reload.
  String editorMode = 'ui';

  /// True when this tab represents an UNSAVED draft — typically a
  /// freshly-`create_package`-d bundle that lives under the studio's
  /// `drafts/` folder and has NOT been registered with the bundle
  /// registry. Closing a draft tab prompts the user (Discard / Save
  /// for later / Export) so unsaved authoring isn't lost silently.
  /// Cleared when the user exports / installs the draft.
  bool isDraft = false;

  /// True after the user has touched the tab in a way that could be
  /// lost on close — chat sent, a builder mutator (studio.builder.*)
  /// executed, or any other modify-class action. Closing a tab whose
  /// `isModified` is true raises a Cancel / Close-anyway dialog so a
  /// careless close doesn't drop in-progress work. Drafts override
  /// this with their own Discard / Save-for-later dialog.
  bool isModified = false;

  bool get isHome => path == null;
}
