/// vibe_studio_ui — unified UI base for the makemind ecosystem.
///
/// Design tokens and theme extracted from the validated `vibe` surface.
/// Every makemind builder / tool / follow-on product shares the same
/// tone. Domain-specific tokens (e.g. vibe's `LayerColors` /
/// `TrackColors`) stay in the host of origin.
library;

export 'src/ui/tokens.dart';
export 'src/ui/theme.dart';

// Atoms — small reusable widgets shared across builder UIs.
export 'src/ui/atoms/vbu_activity_bar.dart';
export 'src/ui/atoms/vbu_bundle_embed.dart';
export 'src/ui/atoms/vbu_channel_strip.dart';
export 'src/ui/atoms/vbu_inspector_panel.dart';
export 'src/ui/atoms/vbu_instance_strip.dart';
export 'src/ui/atoms/vbu_preview_mcp_ui.dart';
export 'src/ui/atoms/vbu_properties_form.dart';
export 'src/ui/atoms/vbu_busy_indicator.dart';
export 'src/ui/atoms/vbu_composer.dart';
export 'src/ui/atoms/vbu_copy_on_hover.dart';
export 'src/ui/atoms/vbu_dialog_scaffold.dart';
export 'src/ui/atoms/vbu_domain_actions_row.dart';
export 'src/ui/atoms/vbu_form_section.dart';
export 'src/ui/atoms/vbu_hero_panel.dart';
export 'src/ui/atoms/vbu_history_viewer.dart';
export 'src/ui/atoms/vbu_icon_button.dart';
export 'src/ui/atoms/vbu_labelled_field.dart';
export 'src/ui/atoms/vbu_labelled_folder.dart';
export 'src/ui/atoms/vbu_labelled_menu.dart';
export 'src/ui/atoms/vbu_labelled_toggle.dart';
export 'src/ui/atoms/vbu_color_editor.dart';
export 'src/ui/atoms/vbu_icon_editor.dart';
export 'src/ui/atoms/vbu_layer_card.dart';
export 'src/ui/atoms/vbu_master_detail.dart';
export 'src/ui/atoms/vbu_mini_preview.dart';
export 'src/ui/atoms/vbu_overview_strip.dart';
export 'src/ui/atoms/vbu_pane_header.dart';
export 'src/ui/atoms/vbu_widget_tree_outline.dart';
export 'src/ui/atoms/vbu_panel_splitter.dart';
export 'src/ui/atoms/vbu_panel_dialog_scaffold.dart';
export 'src/ui/atoms/vbu_json_editor.dart';
export 'src/ui/atoms/vbu_path_tile.dart';
export 'src/ui/atoms/vbu_pill.dart';
export 'src/ui/atoms/vbu_project_name_row.dart';
export 'src/ui/atoms/vbu_prompt_bubble.dart';
export 'src/ui/atoms/vbu_timeline.dart';
export 'src/ui/atoms/vbu_video_player.dart';
export 'src/ui/atoms/vbu_recent_menu_button.dart';
export 'src/ui/atoms/vbu_router.dart';
export 'src/ui/atoms/vbu_slash_chips.dart';
export 'src/ui/atoms/vbu_snapshot_diff.dart';
export 'src/ui/atoms/vbu_statusbar.dart';
export 'src/ui/atoms/vbu_system_note.dart';
export 'src/ui/atoms/vbu_tab_strip.dart';
export 'src/ui/atoms/vbu_title_bar.dart';
export 'src/ui/atoms/vbu_tools_list.dart';
