/// Public barrel for vibe_studio_base.
///
/// Two surfaces a domain tool (vibe_app_builder, knowledge_builder, ...)
/// consumes:
///
///   1. **boot-time** — `StudioBoot.start({...})` wires kernel + agent
///      stack + install registry + RAG + growth recorder. Returns a
///      [StudioBackbone] handle.
///   2. **build-time** — `StudioShell({backbone, rightPane, ...})` widget
///      assembles Titlebar + Chat column + rightPane / Welcome slot +
///      Statusbar. (Pending phase β3+ — not exported yet.)
library;

// Phase β2 exports — backbone + agent stack + install / RAG helpers.
// `agent_dispatch_tools.dart` retired 2026-05-26 — `bk.agent.*` tools
// now come from `KernelEndpoint.addStandardTools`.
export 'src/base/agent/agent_host.dart';
export 'src/base/agent/agent_profile.dart';
export 'src/base/agent/seed_agent_loader.dart';
export 'src/base/agent/seed_chat_manager.dart';

// Phase β5a/β5b exports — chat controller + turn + widget tree.
export 'src/base/chat/chat_controller.dart';
export 'src/base/chat/chat_panel.dart';
export 'src/base/chat/chat_persistence.dart';
export 'src/base/chat/chat_slash_hint.dart';
export 'src/base/chat/chat_turn.dart';
export 'src/base/chat/history_levels_reader.dart';
export 'src/base/chat/model_option.dart';
export 'src/base/chat/noop_llm.dart';

// Phase β6a/β6b exports — settings (data class + dialog UI).
export 'src/base/settings/manifest_field_inheritance.dart';
export 'src/base/settings/manifest_sections_reader.dart';
export 'src/base/settings/settings_dialog.dart';
export 'src/base/settings/vibe_settings.dart';
export 'src/base/boot/studio_backbone.dart';
export 'src/base/boot/studio_boot.dart';
export 'src/base/boot/tool_definitions_reader.dart';
// ── Builder UI catalogue (P1 of studio-builder-rebuild) ──
// spec yaml + vbu atom yaml → WidgetSpec → catalog tools
// (`studio.builder.ui.catalog.list` / `…catalog.schema`).
export 'src/base/builder/widget_spec.dart';
export 'src/base/builder/dsl_spec_loader.dart';
export 'src/base/builder/vbu_atom_spec_loader.dart';
export 'src/base/builder/builder_catalog_service.dart';
export 'src/base/builder/builder_catalog_tools.dart';
// ── Builder UI read mutators (P2 of studio-builder-rebuild) ──
// JSON Pointer helpers + readNode / readTree / findNodes / diff.
export 'src/base/builder/json_pointer.dart';
export 'src/base/builder/builder_ui_read_service.dart';
export 'src/base/builder/builder_ui_read_tools.dart';
// ── Builder UI write mutators (P3 — schema validation layered on) ──
// addNode / setProp / removeNode / moveNode / reorderChildren + applyPatch.
export 'src/base/builder/builder_ui_write_service.dart';
export 'src/base/builder/builder_ui_write_tools.dart';
export 'src/base/builder/schema_validator.dart';
// ── Builder library (P5) — per-project instance working set ──
export 'src/base/builder/builder_library_service.dart';
export 'src/base/builder/builder_library_tools.dart';
export 'src/base/bridge/extension_connect_tool.dart';
export 'src/base/install/bundle_activation.dart';
export 'src/base/session/session.dart';
export 'src/base/install/domain_servers/domain_server_manager.dart';
export 'src/base/install/builtin_tool_registry.dart';
export 'src/base/install/builtin_app.dart';
export 'src/base/install/browser_capability.dart';
export 'src/base/install/capability_tools.dart';
export 'src/base/install/channel_capability.dart';
export 'src/base/install/io_capability.dart';
export 'src/base/install/llm_capability.dart';
export 'src/base/install/bundle_install_tools.dart';
export 'src/base/install/bundle_resource_tools.dart';
export 'src/base/install/builder_mutator_tools.dart';
export 'src/base/install/bundle_template_loader.dart';
export 'src/base/install/bundle_loading.dart';
export 'src/base/install/bundle_manifest_validator.dart';
export 'src/base/install/fs_tools.dart';
export 'src/base/install/ui_control_tools.dart';
export 'src/base/install/atoms/agent_atom.dart';
export 'src/base/install/atoms/atom_category.dart';
export 'src/base/install/atoms/bundle_atom.dart';
export 'src/base/install/atoms/bus_atom.dart';
export 'src/base/install/atoms/fs_atom.dart';
export 'src/base/install/atoms/kb_atom.dart';
export 'src/base/install/atoms/mcp_atom.dart';
export 'src/base/install/atoms/ui_atom.dart';
export 'src/base/install/atoms/workspace_atom.dart';
export 'src/base/runtime/tool_widgets.dart' show registerToolWidgets;
export 'src/base/runtime/vbu_widgets.dart'
    show registerVbuWidgets, resolveIconName;
export 'src/base/install/host_bundle_activation.dart';
// js_host_bridge.dart removed — superseded by `js_tool_isolate.dart`
// which runs the bridge inside its own isolate so flutter_js 0.8.7
// JSCore's static `_sendMessageDartFunc` field doesn't stomp other
// runtimes when a second bundle activates.
export 'src/base/install/js_tool_isolate.dart';
export 'src/base/install/js_tool_runtime.dart';
export 'src/base/install/knowledge_seed_loader.dart';
// `knowledge_tools.dart` · `profile_tools.dart` · `fact_tools.dart`
// · `philosophy_tools.dart` · `skill_tools.dart` · `ops_tools.dart`
// retired 2026-05-26 — those `bk.*` surfaces now come from the
// kernel's `addStandardTools` (cherry inbox `cli-llm-provider-recipe`
// §5 path separation).
export 'src/base/install/project_layout.dart';
export 'src/base/install/project_tools.dart';
export 'src/base/install/search_tools.dart';
export 'src/base/install/vibe_growth_recorder.dart';

// Phase β3 exports — chrome chunk 1 (titlebar · statusbar · welcome ·
// undo/redo shortcuts). Domain tools wire these into their shell tree
// while domain panels (Properties · Preview · Overview) stay outside.
export 'src/base/chat/history_dialog.dart';
export 'src/base/shell/activity_bar.dart';
export 'src/base/shell/app_theme.dart';
export 'src/base/shell/inspect_tag.dart';
export 'src/base/shell/key_shortcuts.dart';
export 'src/base/shell/package_welcome_panel.dart';
export 'src/base/shell/project_header.dart';
export 'src/base/shell/statusbar.dart';
export 'src/base/shell/titlebar.dart';
export 'src/base/shell/tokens.dart';
export 'src/base/shell/welcome_panel.dart';

// Round A — single entry contract every builder (vibe_app_builder ·
// vibe_knowledge_builder · future universal vibe_studio host) shares.
// Domain main.dart calls `StudioMain.run(rawArgs:..., factory:...)`
// after returning a `StudioApp` instance from the factory. The host
// frames the result inside `StudioFrame` (MaterialApp + chrome).
export 'src/base/main/bundle_install_surface.dart';
export 'src/base/main/chrome_bridge.dart';
export 'src/base/main/chrome_tools.dart';
export 'src/base/main/debug_tools.dart';
export 'src/base/main/domain_actions_reader.dart';
export 'src/base/main/lifecycle_dispatcher.dart';
export 'src/base/main/meta_tools.dart';
export 'src/base/main/renderer_tools.dart';
export 'src/base/main/shell_blueprint.dart';
export 'src/base/main/standard_studio_shell.dart';
export 'src/base/main/studio_app.dart';
export 'src/base/main/studio_main.dart';
export 'src/base/main/studio_tab.dart';
export 'src/base/main/studio_workspace.dart';

// capture/ — recorder + overlay + chat-input MCP surface. Host calls
// `registerCaptureTools(boot, bridge: ..., configRoot: ...)` once at
// boot and hands the returned `OverlayController` to the shell so the
// `OverlayLayer` widget can mount inside the RepaintBoundary.
export 'src/base/capture/capture_tools.dart';
export 'src/base/capture/overlay/overlay_controller.dart';
export 'src/base/capture/overlay/overlay_layer.dart';
export 'src/base/capture/overlay/overlay_models.dart';
export 'src/base/capture/recorder/recorder_models.dart';

// Round A2-1 — composite dialogs lifted from vibe_app_builder/feat
// because every builder needs the same shape (Build/Clean/Assets).
// Pure callbacks + vbu_* atoms — no domain types. Future builders can
// reuse without re-implementing the dialog frame, button row, or
// progress strip.
export 'src/base/dialogs/assets_dialog.dart';
export 'src/base/dialogs/build_dialog.dart';
export 'src/base/dialogs/clean_dialog.dart';

// Round A2-2 — composite views (widget tree · live inspector session +
// view adapter). These are AppPlayer-style live UI surfaces every
// builder reuses for "drive the running tool over MCP and watch the
// screen" flows. inspector_panel / inspector_render / preview_mcp_ui
// follow once their domain dependencies (LayerProjection,
// WorkspaceCanonical, types) are generalised in Round A2-4.
export 'src/base/views/inspector_session.dart';
export 'src/base/views/inspector_view_adapter.dart';
export 'src/base/views/widget_tree.dart';

// Round A2-3 — domain primitives lifted from vibe_app_builder/core/types.dart.
// Bundle-level exceptions + ImportKind + ConvertResult are pure
// builder-vocabulary; LayerId + CanonicalPatch carry vibe's mcp_ui
// flavour but are open enough that other builders pick the layer
// subset that fits their domain. vibe_app_builder/core/types.dart
// `show`-re-exports the lifted symbols so existing call sites compile
// unchanged.
export 'src/base/types/builder_exceptions.dart';
export 'src/base/types/canonical_patch.dart';
export 'src/base/types/layer_projection.dart';
export 'src/base/infra/history_log.dart';
export 'src/base/infra/workspace_fs_port.dart';

// Round A2-3 finale — vibe-side canonical / patch-pipeline / spec /
// converter machinery. Every concrete class is the verbatim lift from
// vibe_app_builder; future builders that want the same layered editing
// model (canonical bundle + dry-run validation + atomic patch
// application) can implement the validators alone and reuse the rest.
export 'src/base/spec/spec_catalog.dart';
export 'src/base/spec/spec_validator.dart';
export 'src/base/spec/widget_schema_catalog.dart';
export 'src/base/canonical/patch_pipeline.dart';
export 'src/base/canonical/workspace_canonical.dart';
export 'src/base/conv/pattern_enforcer.dart';
export 'src/base/conv/self_ui_converter.dart';

// Round A2-3 cont. — five domain-light widgets that any builder
// needs once it grows beyond chrome (export/import flows, asset
// gallery, channel-diff, generic property editors). The remaining
// shapes (preview / inspector / properties_panel) follow once their
// vibe-specific deps — WorkspaceCanonical, PatchPipeline,
// SelfUiConverter — also lift into base.
export 'src/base/widgets/agent_models_section.dart';
export 'src/base/widgets/asset_gallery.dart';
export 'src/base/widgets/channel_diff_dialog.dart';
export 'src/base/widgets/export_dialog.dart';
export 'src/base/widgets/history_dialog.dart';
export 'src/base/widgets/import_dialog.dart';
export 'src/base/widgets/inspector_panel.dart';
export 'src/base/widgets/inspector_render.dart';
export 'src/base/widgets/manifest_field_list.dart';
export 'src/base/widgets/manifest_field_row.dart';
export 'src/base/widgets/preview_mcp_ui.dart';
export 'src/base/widgets/preview_panel.dart';
export 'src/base/widgets/preview_self_ui.dart';
export 'src/base/widgets/properties_panel.dart';
export 'src/base/widgets/property_editors.dart';
export 'src/base/widgets/vbu_settings_sections_form.dart';
export 'src/base/widgets/workspace_page_nav_overlay.dart';

// Round A2-4 — universal-host per-bundle editor bodies. Lifted from
// the studio_builder host so future builders (and tests) reuse the
// same Tools / Knowledge / Manifest views without copying.
export 'src/base/widgets/editors/bundle_agents_view.dart';
export 'src/base/widgets/editors/bundle_editor_placeholder.dart';
export 'src/base/widgets/editors/bundle_knowledge_view.dart';
export 'src/base/widgets/editors/bundle_manifest_view.dart';
export 'src/base/widgets/editors/bundle_tools_view.dart';
export 'src/base/widgets/editors/wiring_settings_list.dart';
